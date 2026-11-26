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

public enum RecoveryTrigger: String, Sendable {
  case launch, reconfiguration, wake
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

/// Debounces triggers (settle), runs one episode at a time, drops triggers that arrived during one;
/// after .displayActive such triggers start one more episode instead.
/// After .failed only .wake, or a .reconfiguration seeing activeCount() > 0, re-arms it.
/// `activeCount` counts usable displays: the macOS placeholder must not count (D-012).
public actor RecoveryScheduler {
  private let recovery: ZeroActiveRecovery
  private let activeCount: @Sendable () async -> Int
  private let settle: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let onOutcome: @Sendable (RecoveryOutcome) -> Void

  private(set) var generation = 0
  private var latestTrigger = RecoveryTrigger.launch
  private var wakeInWindow = false
  private var running = false
  private var disarmed = false
  /// A .reconfiguration that arrived while disarmed saw an active display.
  private var activeSeenWhileDisarmed = false
  private var lastEpisodeEnd: ContinuousClock.Instant?
  private var lastOutcome: RecoveryOutcome?
  /// A trigger arrived while the current episode ran.
  private var changedDuringEpisode = false
  private var tasks: [Int: Task<Void, Never>] = [:]

  public init(
    recovery: ZeroActiveRecovery,
    activeCount: @escaping @Sendable () async -> Int,
    settle: Duration = .seconds(2),
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    onOutcome: @escaping @Sendable (RecoveryOutcome) -> Void = { _ in }
  ) {
    self.recovery = recovery
    self.activeCount = activeCount
    self.settle = settle
    self.sleep = sleep
    self.onOutcome = onOutcome
  }

  /// `arrival` is when macOS reported the event; one from before the last episode ended is dropped,
  /// unless that episode ended .displayActive. `arrivalCount` is the usable count sampled then.
  public func trigger(
    _ trigger: RecoveryTrigger, at arrival: ContinuousClock.Instant = .now,
    activeCount arrivalCount: Int? = nil
  ) async {
    guard !belongsToEpisode(arrival) else { return }
    if disarmed, trigger == .reconfiguration {
      let count: Int
      if let arrivalCount { count = arrivalCount } else { count = await activeCount() }
      if count > 0 { activeSeenWhileDisarmed = true }
    }
    // An episode may have run while the count was taken.
    guard !belongsToEpisode(arrival) else { return }
    startWindow(trigger)
  }

  private func startWindow(_ trigger: RecoveryTrigger) {
    generation += 1
    latestTrigger = trigger
    wakeInWindow = wakeInWindow || trigger == .wake
    for task in tasks.values { task.cancel() }
    let id = generation
    tasks[id] = Task { [settle, sleep] in
      if (try? await sleep(settle)) != nil {
        await self.settled(id)
      }
      self.removeTask(id)
    }
  }

  /// Waits until every settle window and episode started so far has finished. For tests.
  func drain() async {
    while let task = tasks.values.first {
      await task.value
    }
  }

  /// True when no settle window or episode is pending. For tests.
  var isIdle: Bool { tasks.isEmpty }

  private func settled(_ id: Int) async {
    // A later trigger restarted the settle window.
    guard id == generation, !running else { return }
    let trigger = wakeInWindow ? RecoveryTrigger.wake : latestTrigger
    wakeInWindow = false
    if disarmed && trigger != .wake {
      // A display seen active in this window re-arms the net; recover only if none is active now.
      let sawActive = activeSeenWhileDisarmed
      activeSeenWhileDisarmed = false
      let activeNow = await activeCount() > 0
      if sawActive || activeNow { disarmed = false }
      guard sawActive, !activeNow, id == generation, !running else { return }
    }
    disarmed = false
    activeSeenWhileDisarmed = false
    running = true
    changedDuringEpisode = false
    let outcome = await recovery.run(trigger: trigger)
    running = false
    lastEpisodeEnd = .now
    lastOutcome = outcome
    if case .failed = outcome { disarmed = true }
    // .displayActive enabled nothing, so an event during it is a real change: check once more.
    if outcome == .displayActive, changedDuringEpisode { startWindow(.reconfiguration) }
    onOutcome(outcome)
  }

  /// True when the trigger arrived during an episode or was stamped before the last one ended.
  private func belongsToEpisode(_ arrival: ContinuousClock.Instant) -> Bool {
    if running {
      changedDuringEpisode = true
      return true
    }
    guard let lastEpisodeEnd, arrival < lastEpisodeEnd else { return false }
    return lastOutcome != .displayActive
  }

  private func removeTask(_ id: Int) {
    tasks[id] = nil
  }
}
