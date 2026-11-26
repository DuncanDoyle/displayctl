import Foundation
import Synchronization
import XCTest

@testable import DisplayControlCore

final class ZeroActiveRecoveryTests: XCTestCase {
  func testDisplayActiveWhenConnectorReturnsNil() async {
    let connector = FakeConnector([.success(nil)])
    let sleeper = ManualSleeper()

    let outcome = await drive(recovery(connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .displayActive)
    XCTAssertEqual(connector.calls, 1)
    let durations = await sleeper.durations
    XCTAssertEqual(durations, [])
  }

  func testRecoveredWhenSnapshotShowsActiveAfterAttempt() async {
    let connector = FakeConnector([.success([enabled(1)])])
    let sampler = ScriptedSampler([.success([display(1, active: true)])])
    let sleeper = ManualSleeper()

    let outcome = await drive(
      recovery(sampler: sampler, connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .recovered(attempts: 1))
  }

  func testReturnedFailuresAreLoggedIncludingLedgerOutcome() async {
    let connector = FakeConnector([
      .success([
        DisplayConnectionOutcome(
          display: display(2, active: false), result: .failure(.recoverySkipped("earlier boot"))),
        DisplayConnectionOutcome(
          display: nil, result: .failure(.configurationFailed("ledger unreadable"))),
      ])
    ])
    let log = Recorder<String>()
    let sleeper = ManualSleeper()

    _ = await drive(recovery(connector: connector, sleeper: sleeper, log: log), sleeper)

    XCTAssertTrue(log.values.contains { $0.contains("earlier boot") }, "\(log.values)")
    XCTAssertTrue(log.values.contains { $0.contains("ledger unreadable") }, "\(log.values)")
  }

  func testPartialRecoveryCountsAsRecovered() async {
    let connector = FakeConnector([
      .success([
        enabled(1),
        DisplayConnectionOutcome(
          display: display(2, active: false), result: .failure(.postconditionFailed("stuck"))),
      ])
    ])
    let sampler = ScriptedSampler([.success([display(1, active: true), display(2, active: false)])])
    let log = Recorder<String>()
    let sleeper = ManualSleeper()

    let outcome = await drive(
      recovery(sampler: sampler, connector: connector, sleeper: sleeper, log: log), sleeper)

    XCTAssertEqual(outcome, .recovered(attempts: 1))
    XCTAssertTrue(log.values.contains { $0.contains("stuck") }, "\(log.values)")
  }

  func testLockTimeoutCountsAsFailedAttemptAndRetries() async {
    let connector = FakeConnector([
      .failure(.lockTimeout), .failure(.lockTimeout), .success([enabled(1)]),
    ])
    let sampler = ScriptedSampler([.success([display(1, active: true)])])
    let sleeper = ManualSleeper()

    let outcome = await drive(
      recovery(sampler: sampler, connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .recovered(attempts: 3))
    let durations = await sleeper.durations
    XCTAssertEqual(durations, [.seconds(2), .seconds(2)])
  }

  func testOnlyThrownAttemptsEndInconclusive() async {
    // No locked check succeeded, so zero usable displays was never observed.
    let connector = FakeConnector([.failure(.lockTimeout)])
    let sleeper = ManualSleeper()

    let outcome = await drive(recovery(connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .inconclusive)
    XCTAssertEqual(connector.calls, 3)
  }

  func testGivesUpAfterMaxAttempts() async {
    let failure = DisplayConnectionOutcome(
      display: display(1, active: false), result: .failure(.postconditionFailed("stuck")))
    let connector = FakeConnector([.success([failure])])
    let sleeper = ManualSleeper()

    let outcome = await drive(recovery(connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .failed(attempts: 3))
    XCTAssertEqual(connector.calls, 3)
  }

  func testInconsistentSampleFromVerificationIsNotAnAttempt() async {
    let connector = FakeConnector([.success([enabled(1)])])
    let sampler = ScriptedSampler([
      .failure(.inventoryChanged), .failure(.inventoryChanged),
      .success([display(1, active: true)]),
    ])
    let sleeper = ManualSleeper()

    let outcome = await drive(
      recovery(sampler: sampler, connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .recovered(attempts: 1))
    XCTAssertEqual(connector.calls, 1)
    let durations = await sleeper.durations
    XCTAssertEqual(durations, [.seconds(2), .seconds(2)])
  }

  func testInconsistentSampleFromLockedCheckIsNotAnAttempt() async {
    let connector = FakeConnector([
      .failure(.inventoryChanged), .failure(.inventoryChanged), .success([enabled(1)]),
    ])
    let sampler = ScriptedSampler([.success([display(1, active: true)])])
    let sleeper = ManualSleeper()

    let outcome = await drive(
      recovery(sampler: sampler, connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .recovered(attempts: 1))
    XCTAssertEqual(connector.calls, 3)
  }

  func testPlaceholderAloneInVerificationIsNotRecovered() async {
    let connector = FakeConnector([.success([stuck(1)])])
    let sampler = ScriptedSampler([.success([display(1, active: false), placeholder()])])
    let sleeper = ManualSleeper()

    let outcome = await drive(
      recovery(sampler: sampler, connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .failed(attempts: 3))
    XCTAssertEqual(connector.calls, 3)
  }

  func testInconclusiveAfterFiveInconsistentSamples() async {
    let connector = FakeConnector([.failure(.inventoryChanged)])
    let sleeper = ManualSleeper()

    let outcome = await drive(recovery(connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .inconclusive)
    XCTAssertEqual(connector.calls, 5)
  }
}

final class RecoverySchedulerTests: XCTestCase {
  func testEventsMergeIntoOneCheckWithoutMovingItsDeadline() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success(nil)]))

    for trigger in [RecoveryTrigger.launch, .reconfiguration, .reconfiguration] {
      await harness.scheduler.trigger(trigger)
    }
    await harness.settleAndDrain()

    let durations = await harness.settle.durations
    XCTAssertEqual(durations, [.seconds(2)])
    XCTAssertEqual(harness.connector.calls, 1)
    XCTAssertEqual(harness.outcomes.values, [.displayActive])
  }

  func testEventBurstDuringEpisodeStartsNothing() async {
    let reference = SchedulerReference()
    // Each enable makes macOS report reconfigurations before the call returns its failure.
    let connector = FakeConnector([.success([stuck(1)])]) { _ in
      for _ in 0..<3 { await reference.scheduler?.trigger(.reconfiguration) }
    }
    let harness = SchedulerHarness(connector: connector)
    reference.scheduler = harness.scheduler

    await harness.fire(.launch)

    XCTAssertEqual(connector.calls, 3)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3)])
    let pending = await harness.settle.pendingCount
    XCTAssertEqual(pending, 0)
  }

  func testLastCallbackSawADisplayAndTheNextTickRecovers() async {
    // The unplug callback sampled the Dell still active; no callback follows once it is gone.
    let connector = FakeConnector([.success(nil), .success([enabled(1)])])
    let harness = SchedulerHarness(
      connector: connector, sampler: ScriptedSampler([.success([display(1, active: true)])]))
    harness.count.value = 1
    await harness.fire(.reconfiguration)
    await harness.scheduler.tick()
    XCTAssertEqual(connector.calls, 1)

    harness.count.value = 0
    await harness.scheduler.tick()

    XCTAssertEqual(connector.calls, 2)
    XCTAssertEqual(harness.outcomes.values, [.displayActive, .recovered(attempts: 1)])
    XCTAssertTrue(harness.log.values.contains("episode started by tick"), "\(harness.log.values)")
  }

  func testPlaceholderOnlyListCountsAsZero() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success([stuck(1)])])) {
      DisplayInventory.usableActiveCount(activeIDs: [12], isPlaceholder: { $0 == 12 })
    }

    await harness.scheduler.tick()

    XCTAssertEqual(harness.connector.calls, 3)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3)])
  }

  func testQueryErrorOnTickTakesNoAction() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success([stuck(1)])])) {
      throw DisplayControlError.configurationFailed("CGGetActiveDisplayList failed")
    }

    await harness.scheduler.tick()

    XCTAssertEqual(harness.connector.calls, 0)
    XCTAssertEqual(harness.outcomes.values, [])
  }

  func testCooldownAfterFailedEpisodeBlocksEventsAndTicks() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success([stuck(1)])]))
    await harness.fire(.launch)

    for _ in 0..<3 { await harness.scheduler.trigger(.reconfiguration) }
    await harness.scheduler.tick()
    harness.clock.advance(.seconds(59))
    await harness.scheduler.tick()
    let pending = await harness.settle.pendingCount
    XCTAssertEqual(pending, 0)
    XCTAssertEqual(harness.connector.calls, 3)

    harness.clock.advance(.seconds(1))
    await harness.scheduler.tick()

    XCTAssertEqual(harness.connector.calls, 6)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3), .failed(attempts: 3)])
  }

  func testInconclusiveEpisodeAlsoStartsCooldown() async {
    let harness = SchedulerHarness(connector: FakeConnector([.failure(.inventoryChanged)]))
    await harness.fire(.launch)

    await harness.scheduler.tick()

    XCTAssertEqual(harness.connector.calls, 5)
    XCTAssertEqual(harness.outcomes.values, [.inconclusive])
  }

  func testWakeEndsCooldownAndStartsAFreshEpisode() async {
    // Lid closed: the episode's enables cannot light the built-in, so it fails.
    let harness = SchedulerHarness(connector: FakeConnector([.success([stuck(1)])]))
    await harness.fire(.reconfiguration)

    await harness.fire(.wake)

    XCTAssertEqual(harness.connector.calls, 6)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3), .failed(attempts: 3)])
    XCTAssertTrue(harness.log.values.contains("episode started by wake"), "\(harness.log.values)")
  }

  func testWakeDuringEpisodeChecksAgainAfterIt() async {
    let reference = SchedulerReference()
    let connector = FakeConnector([.success([stuck(1)])]) { call in
      if call == 1 { await reference.scheduler?.trigger(.wake) }
    }
    let harness = SchedulerHarness(connector: connector)
    reference.scheduler = harness.scheduler

    await harness.scheduler.trigger(.reconfiguration)
    _ = await harness.settle.waitForSleeps(1)
    await harness.settle.advanceAll()
    await harness.outcomes.waitForCount(1)
    await harness.settleAndDrain()

    XCTAssertEqual(connector.calls, 6)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3), .failed(attempts: 3)])
    XCTAssertTrue(harness.log.values.contains("episode started by wake"), "\(harness.log.values)")
  }
}

// MARK: - Fakes

/// Answers each call from the script in order, repeating the last entry.
private final class ScriptedSampler: DisplaySampling {
  private let script: Mutex<[Result<[Display], DisplayControlError>]>

  init(_ script: [Result<[Display], DisplayControlError>]) {
    self.script = Mutex(script)
  }

  func snapshot() async throws -> [Display] {
    try script.withLock { script in
      script.count > 1 ? script.removeFirst() : script[0]
    }.get()
  }
}

/// Answers each call from the script in order, repeating the last entry; `onCall` runs first.
private final class FakeConnector: RecoveryConnecting {
  typealias Answer = Result<[DisplayConnectionOutcome]?, DisplayControlError>
  private let state: Mutex<(script: [Answer], calls: Int)>
  private let onCall: @Sendable (Int) async -> Void

  init(
    _ script: [Answer],
    onCall: @escaping @Sendable (Int) async -> Void = { _ in }
  ) {
    state = Mutex((script, 0))
    self.onCall = onCall
  }

  var calls: Int { state.withLock { $0.calls } }

  func recoverIfNoneActive() async throws -> [DisplayConnectionOutcome]? {
    let (call, result) = state.withLock { state in
      state.calls += 1
      let result = state.script.count > 1 ? state.script.removeFirst() : state.script[0]
      return (state.calls, result)
    }
    await onCall(call)
    return try result.get()
  }
}

/// Records each requested duration and suspends the caller until the test advances it.
private actor ManualSleeper {
  private(set) var durations: [Duration] = []
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var finished = false
  private var observer: (minimum: Int, continuation: CheckedContinuation<Bool, Never>)?

  var pendingCount: Int { pending.count }

  func sleep(_ duration: Duration) async {
    durations.append(duration)
    await withCheckedContinuation { continuation in
      pending.append(continuation)
      notify()
    }
  }

  /// Marks the driven work as done, so a waiter stops expecting sleeps.
  func finish() {
    finished = true
    notify()
  }

  /// True once `count` sleeps are pending; false if the work finished first.
  func waitForSleeps(_ count: Int) async -> Bool {
    if pending.count >= count { return true }
    if finished { return false }
    return await withCheckedContinuation { observer = (count, $0) }
  }

  func advanceAll() {
    let resumed = pending
    pending = []
    for continuation in resumed { continuation.resume() }
  }

  private func notify() {
    guard let observer else { return }
    if pending.count >= observer.minimum {
      self.observer = nil
      observer.continuation.resume(returning: true)
    } else if finished {
      self.observer = nil
      observer.continuation.resume(returning: false)
    }
  }
}

private final class Recorder<Value: Sendable>: Sendable {
  private struct State {
    var values: [Value] = []
    var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  }
  private let storage = Mutex(State())

  var values: [Value] { storage.withLock { $0.values } }

  func append(_ value: Value) {
    let ready = storage.withLock { state in
      state.values.append(value)
      let count = state.values.count
      defer { state.waiters.removeAll { $0.count <= count } }
      return state.waiters.filter { $0.count <= count }.map(\.continuation)
    }
    for continuation in ready { continuation.resume() }
  }

  /// Waits until at least `count` values were recorded.
  func waitForCount(_ count: Int) async {
    await withCheckedContinuation { continuation in
      let ready = storage.withLock { state in
        if state.values.count < count { state.waiters.append((count, continuation)) }
        return state.values.count >= count
      }
      if ready { continuation.resume() }
    }
  }
}

/// The usable active count a tick reads; 0 unless the test sets it.
private final class FakeCount: Sendable {
  private let state = Mutex(0)

  var value: Int {
    get { state.withLock { $0 } }
    set { state.withLock { $0 = newValue } }
  }
}

/// A clock the test moves forward by hand.
private final class FakeClock: Sendable {
  private let start = ContinuousClock.now
  private let offset = Mutex(Duration.zero)

  var now: ContinuousClock.Instant { start + offset.withLock { $0 } }

  func advance(_ duration: Duration) {
    offset.withLock { $0 += duration }
  }
}

private final class SchedulerReference: Sendable {
  private let storage = Mutex<RecoveryScheduler?>(nil)

  var scheduler: RecoveryScheduler? {
    get { storage.withLock { $0 } }
    set { storage.withLock { $0 = newValue } }
  }
}

/// A scheduler whose settle sleeps the test advances; recovery retries do not wait.
private struct SchedulerHarness {
  let connector: FakeConnector
  let settle = ManualSleeper()
  let outcomes = Recorder<RecoveryOutcome>()
  let log = Recorder<String>()
  let count = FakeCount()
  let clock = FakeClock()
  let scheduler: RecoveryScheduler

  /// `usableCount` replaces the fake count when given.
  init(
    connector: FakeConnector,
    sampler: ScriptedSampler = ScriptedSampler([.success([display(1, active: false)])]),
    usableCount: (@Sendable () throws -> Int)? = nil
  ) {
    self.connector = connector
    let log = log
    let recovery = ZeroActiveRecovery(
      sampler: sampler, connector: connector, sleep: { _ in }, log: { log.append($0) })
    let settle = settle
    let outcomes = outcomes
    let count = count
    let clock = clock
    scheduler = RecoveryScheduler(
      recovery: recovery, usableCount: { try usableCount?() ?? count.value },
      sleep: { await settle.sleep($0) }, now: { clock.now }, log: { log.append($0) },
      onOutcome: { outcomes.append($0) })
  }

  func settleAndDrain() async {
    _ = await settle.waitForSleeps(1)
    await settle.advanceAll()
    await scheduler.drain()
  }

  func fire(_ trigger: RecoveryTrigger) async {
    await scheduler.trigger(trigger)
    await settleAndDrain()
  }
}

// MARK: - Helpers

private func recovery(
  sampler: ScriptedSampler = ScriptedSampler([.success([display(1, active: false)])]),
  connector: FakeConnector,
  sleeper: ManualSleeper,
  log: Recorder<String> = Recorder()
) -> ZeroActiveRecovery {
  ZeroActiveRecovery(
    sampler: sampler, connector: connector, sleep: { await sleeper.sleep($0) },
    log: { log.append($0) })
}

/// Runs one episode, advancing each sleep as it is requested.
private func drive(_ recovery: ZeroActiveRecovery, _ sleeper: ManualSleeper) async
  -> RecoveryOutcome
{
  let task = Task {
    let outcome = await recovery.run(trigger: .reconfiguration)
    await sleeper.finish()
    return outcome
  }
  while await sleeper.waitForSleeps(1) {
    await sleeper.advanceAll()
  }
  return await task.value
}

private func display(_ id: UInt32, active: Bool) -> Display {
  Display(
    uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
    runtimeID: id, name: "Display \(id)", kind: .external, isOnline: true, isActive: active,
    isMain: false, ddcCapability: .unknown)
}

private func placeholder() -> Display {
  Display(
    uuid: UUID(uuidString: "DEE21DC4-D655-4C72-BB90-001415FBABA5")!, runtimeID: 12,
    name: "External Display", kind: .external, isOnline: true, isActive: true, isMain: true,
    ddcCapability: .unknown, isPlaceholder: true)
}

private func enabled(_ id: UInt32) -> DisplayConnectionOutcome {
  DisplayConnectionOutcome(
    display: display(id, active: false), result: .success(display(id, active: true)))
}

private func stuck(_ id: UInt32) -> DisplayConnectionOutcome {
  DisplayConnectionOutcome(
    display: display(id, active: false), result: .failure(.postconditionFailed("stuck")))
}
