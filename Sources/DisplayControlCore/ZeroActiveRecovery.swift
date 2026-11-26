// Async boundaries: the app backs them with the serial executor; tests use fakes.
public protocol RecoveryConnecting: Sendable {
  func recoverIfNoneActive() async throws -> [DisplayConnectionOutcome]?
}

public protocol DisplaySampling: Sendable {
  func snapshot() async throws -> [Display]
}

public enum RecoveryOutcome: Equatable, Sendable {
  /// A display was active at the first locked check; nothing was done.
  case displayActive
  /// A display became active after `attempts` attempts.
  case recovered(attempts: Int)
  /// No display was active after the last attempt.
  case failed(attempts: Int)
  /// The display list kept changing for every sample this episode allows, or every attempt threw
  /// before a locked check saw zero usable displays.
  case inconclusive
}

/// What started an episode: an event, or the periodic check (`tick`).
public enum RecoveryTrigger: String, Sendable {
  case launch, reconfiguration, wake, tick
}

/// One safety-net episode: enables displays under the lock until one is active, with a bounded
/// number of attempts and inconsistent samples.
public struct ZeroActiveRecovery: Sendable {
  private let sampler: any DisplaySampling
  private let connector: any RecoveryConnecting
  private let sleep: @Sendable (Duration) async -> Void
  private let retryDelay: Duration
  private let maxAttempts: Int
  private let maxInconsistentSamples: Int
  private let log: @Sendable (String) -> Void

  public init(
    sampler: any DisplaySampling,
    connector: any RecoveryConnecting,
    sleep: @escaping @Sendable (Duration) async -> Void,
    retryDelay: Duration = .seconds(2),
    maxAttempts: Int = 3,
    maxInconsistentSamples: Int = 5,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.sampler = sampler
    self.connector = connector
    self.sleep = sleep
    self.retryDelay = retryDelay
    self.maxAttempts = maxAttempts
    self.maxInconsistentSamples = maxInconsistentSamples
    self.log = log
  }

  public func run(trigger: RecoveryTrigger) async -> RecoveryOutcome {
    log("episode started by \(trigger.rawValue)")
    var attempts = 0
    var inconsistentSamples = 0
    // Only a locked check that returned outcomes has seen zero usable displays; .failed needs one.
    var sawZeroActive = false

    // Counts an inconsistent sample; true when the episode has none left.
    func sampleBudgetSpent() -> Bool {
      inconsistentSamples += 1
      log("inconsistent display list (\(inconsistentSamples) of \(maxInconsistentSamples))")
      return inconsistentSamples >= maxInconsistentSamples
    }

    while true {
      let outcomes: [DisplayConnectionOutcome]?
      do {
        outcomes = try await connector.recoverIfNoneActive()
      } catch DisplayControlError.inventoryChanged {
        if sampleBudgetSpent() { return finish(.inconclusive) }
        await sleep(retryDelay)
        continue
      } catch {
        attempts += 1
        log("attempt \(attempts) failed: \(error)")
        if attempts >= maxAttempts {
          return finish(sawZeroActive ? .failed(attempts: attempts) : .inconclusive)
        }
        await sleep(retryDelay)
        continue
      }

      guard let outcomes else {
        // Someone else turned a display on after an earlier failed attempt.
        return finish(attempts == 0 ? .displayActive : .recovered(attempts: attempts))
      }
      attempts += 1
      sawZeroActive = true
      logFailures(outcomes, attempt: attempts)

      var verified = false
      while true {
        do {
          verified = try await sampler.snapshot().contains(where: \.isUsableActive)
          break
        } catch DisplayControlError.inventoryChanged {
          if sampleBudgetSpent() { return finish(.inconclusive) }
          await sleep(retryDelay)
        } catch {
          log("verification after attempt \(attempts) failed: \(error)")
          break
        }
      }
      if verified { return finish(.recovered(attempts: attempts)) }
      if attempts >= maxAttempts { return finish(.failed(attempts: attempts)) }
      await sleep(retryDelay)
    }
  }

  private func logFailures(_ outcomes: [DisplayConnectionOutcome], attempt: Int) {
    for outcome in outcomes {
      guard case .failure(let error) = outcome.result else { continue }
      let subject =
        outcome.display.map { "display \($0.name) (\($0.uuid.uuidString))" }
        ?? "saved display list"
      log("attempt \(attempt): \(subject) failed: \(error)")
    }
  }

  private func finish(_ outcome: RecoveryOutcome) -> RecoveryOutcome {
    log("episode ended: \(outcome)")
    return outcome
  }
}

/// Runs safety-net episodes one at a time (design §6.3, D-014). Events are hints that schedule one
/// settled check; a tick starts an episode only at a confirmed zero `usableCount`.
/// An episode that ends without a usable display starts a cooldown; a wake ends it.
public actor RecoveryScheduler {
  private let recovery: ZeroActiveRecovery
  private let usableCount: @Sendable () async throws -> Int
  private let settle: Duration
  private let cooldown: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> ContinuousClock.Instant
  private let log: @Sendable (String) -> Void
  private let onOutcome: @Sendable (RecoveryOutcome) -> Void

  /// The trigger of the check waiting out its settle period.
  private var pendingTrigger: RecoveryTrigger?
  private var running = false
  private var wokeDuringEpisode = false
  private var cooldownEnd: ContinuousClock.Instant?
  private var nextTaskID = 0
  private var tasks: [Int: Task<Void, Never>] = [:]

  public init(
    recovery: ZeroActiveRecovery,
    usableCount: @escaping @Sendable () async throws -> Int,
    settle: Duration = .seconds(2),
    cooldown: Duration = .seconds(60),
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    log: @escaping @Sendable (String) -> Void = { _ in },
    onOutcome: @escaping @Sendable (RecoveryOutcome) -> Void = { _ in }
  ) {
    self.recovery = recovery
    self.usableCount = usableCount
    self.settle = settle
    self.cooldown = cooldown
    self.sleep = sleep
    self.now = now
    self.log = log
    self.onOutcome = onOutcome
  }

  /// Merges into a pending check without moving its deadline; dropped during an episode or a
  /// cooldown. A wake ends the cooldown, and one during an episode is checked after it.
  public func trigger(_ trigger: RecoveryTrigger) {
    if trigger == .wake {
      cooldownEnd = nil
      if running { wokeDuringEpisode = true }
    }
    guard !running, !coolingDown else { return }
    schedule(trigger)
  }

  /// The periodic check. A query error means unknown, so it does nothing.
  public func tick() async {
    guard canStart else { return }
    let count: Int
    do {
      count = try await usableCount()
    } catch {
      log("periodic check: usable display count unavailable: \(error)")
      return
    }
    guard count == 0, canStart else { return }
    await runEpisode(.tick)
  }

  /// Waits until every scheduled check and its episode have finished. For tests.
  func drain() async {
    while let task = tasks.values.first {
      await task.value
    }
  }

  private var coolingDown: Bool {
    guard let cooldownEnd else { return false }
    return now() < cooldownEnd
  }

  /// A pending check covers a tick, so a tick starts nothing while one waits.
  private var canStart: Bool { !running && pendingTrigger == nil && !coolingDown }

  private func schedule(_ trigger: RecoveryTrigger) {
    guard pendingTrigger == nil else {
      if trigger == .wake { pendingTrigger = .wake }
      return
    }
    pendingTrigger = trigger
    nextTaskID += 1
    let id = nextTaskID
    tasks[id] = Task { [settle, sleep] in
      try? await sleep(settle)
      await self.settled()
      self.removeTask(id)
    }
  }

  private func settled() async {
    guard let trigger = pendingTrigger else { return }
    pendingTrigger = nil
    await runEpisode(trigger)
  }

  private func runEpisode(_ trigger: RecoveryTrigger) async {
    running = true
    let outcome = await recovery.run(trigger: trigger)
    running = false
    let woke = wokeDuringEpisode
    wokeDuringEpisode = false
    onOutcome(outcome)
    if woke {
      schedule(.wake)
    } else if outcome == .inconclusive || outcome.isFailed {
      cooldownEnd = now() + cooldown
      log("no usable display after the episode; cooldown \(cooldown)")
    }
  }

  private func removeTask(_ id: Int) {
    tasks[id] = nil
  }
}

extension RecoveryOutcome {
  fileprivate var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}
