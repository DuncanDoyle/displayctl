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

  func testInconclusiveAfterFiveInconsistentSamples() async {
    let connector = FakeConnector([.failure(.inventoryChanged)])
    let sleeper = ManualSleeper()

    let outcome = await drive(recovery(connector: connector, sleeper: sleeper), sleeper)

    XCTAssertEqual(outcome, .inconclusive)
    XCTAssertEqual(connector.calls, 5)
  }
}

final class RecoverySchedulerTests: XCTestCase {
  func testTriggersInSettleWindowCoalesce() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success(nil)]))

    for trigger in [RecoveryTrigger.launch, .reconfiguration, .reconfiguration] {
      await harness.scheduler.trigger(trigger)
    }
    await harness.settleAndDrain(sleeps: 3)

    XCTAssertEqual(harness.connector.calls, 1)
    XCTAssertEqual(harness.outcomes.values, [.displayActive])
  }

  func testTriggerDuringRunIsDropped() async {
    let gate = Gate()
    let connector = FakeConnector([.success(nil)]) { _ in await gate.pass() }
    let harness = SchedulerHarness(connector: connector)

    await harness.scheduler.trigger(.launch)
    _ = await harness.settle.waitForSleeps(1)
    await harness.settle.advanceAll()
    await gate.waitUntilEntered()
    await harness.scheduler.trigger(.reconfiguration)
    let pending = await harness.settle.pendingCount
    await gate.open()
    await harness.scheduler.drain()

    XCTAssertEqual(pending, 0)
    XCTAssertEqual(connector.calls, 1)
    XCTAssertEqual(harness.outcomes.values, [.displayActive])
  }

  func testFailedEnableEmittingCallbackDuringRunStillEnds() async {
    let reference = SchedulerReference()
    // Each enable makes macOS report a reconfiguration before the call returns its failure.
    let connector = FakeConnector([.success([stuck(1)])]) { _ in
      await reference.scheduler?.trigger(.reconfiguration)
    }
    let harness = SchedulerHarness(connector: connector)
    reference.scheduler = harness.scheduler

    await harness.fire(.launch)

    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3)])
    XCTAssertEqual(connector.calls, 3)
    let pending = await harness.settle.pendingCount
    XCTAssertEqual(pending, 0)
  }

  func testFailedEpisodeIgnoresReconfigurationWhileZeroActive() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success([stuck(1)])]))
    await harness.fire(.launch)

    await harness.fire(.reconfiguration)

    XCTAssertEqual(harness.connector.calls, 3)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3)])
    // Once when the trigger arrives, once when its window settles.
    XCTAssertEqual(harness.activeCount.calls, 2)
  }

  func testFailedEpisodeRearmsOnWake() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success([stuck(1)])]))
    await harness.fire(.launch)

    await harness.fire(.wake)

    XCTAssertEqual(harness.connector.calls, 6)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3), .failed(attempts: 3)])
  }

  func testFailedEpisodeRearmsWhenActiveCountAboveZero() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success([stuck(1)])]))
    await harness.fire(.launch)

    harness.activeCount.value = 1
    await harness.fire(.reconfiguration)
    XCTAssertEqual(harness.connector.calls, 3)

    harness.activeCount.value = 0
    await harness.fire(.reconfiguration)
    XCTAssertEqual(harness.connector.calls, 6)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3), .failed(attempts: 3)])
  }

  func testDisplayActiveInsideOneSettleWindowRearmsAfterFailure() async {
    let harness = SchedulerHarness(connector: FakeConnector([.success([stuck(1)])]))
    await harness.fire(.launch)

    // The Dell is plugged in, then unplugged again before the window ends.
    harness.activeCount.value = 1
    await harness.scheduler.trigger(.reconfiguration)
    harness.activeCount.value = 0
    await harness.scheduler.trigger(.reconfiguration)
    await harness.settleAndDrain(sleeps: 2)

    XCTAssertEqual(harness.connector.calls, 6)
    XCTAssertEqual(harness.outcomes.values, [.failed(attempts: 3), .failed(attempts: 3)])
  }

  func testReconfigurationStampedDuringEpisodeIsDroppedWhenDeliveredLate() async throws {
    let stamp = Mutex<ContinuousClock.Instant?>(nil)
    let connector = FakeConnector([.failure(.inventoryChanged)]) { _ in
      stamp.withLock { $0 = $0 ?? .now }
    }
    let harness = SchedulerHarness(connector: connector)
    await harness.fire(.launch)
    XCTAssertEqual(harness.outcomes.values, [.inconclusive])

    // macOS reported it during the episode; it reaches the scheduler only now.
    let arrival = try XCTUnwrap(stamp.withLock { $0 })
    await harness.scheduler.trigger(.reconfiguration, at: arrival)
    let idle = await harness.scheduler.isIdle
    if !idle { await harness.settleAndDrain(sleeps: 1) }

    XCTAssertTrue(idle)
    XCTAssertEqual(connector.calls, 5)
    XCTAssertEqual(harness.outcomes.values, [.inconclusive])
  }

  func testInconclusiveDoesNotDisarm() async {
    let harness = SchedulerHarness(connector: FakeConnector([.failure(.inventoryChanged)]))
    await harness.fire(.launch)

    await harness.fire(.reconfiguration)

    XCTAssertEqual(harness.outcomes.values, [.inconclusive, .inconclusive])
    XCTAssertEqual(harness.activeCount.calls, 0)
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

/// Holds callers of `pass()` until `open()`; the test can wait for the first caller.
private actor Gate {
  private var entered = false
  private var isOpen = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var held: [CheckedContinuation<Void, Never>] = []

  func pass() async {
    entered = true
    for waiter in enteredWaiters { waiter.resume() }
    enteredWaiters = []
    if isOpen { return }
    await withCheckedContinuation { held.append($0) }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enteredWaiters.append($0) }
  }

  func open() {
    isOpen = true
    for caller in held { caller.resume() }
    held = []
  }
}

private final class Recorder<Value: Sendable>: Sendable {
  private let storage = Mutex<[Value]>([])

  var values: [Value] { storage.withLock { $0 } }

  func append(_ value: Value) {
    storage.withLock { $0.append(value) }
  }
}

private final class FakeActiveCount: Sendable {
  private let state = Mutex((value: 0, calls: 0))

  var value: Int {
    get { state.withLock { $0.value } }
    set { state.withLock { $0.value = newValue } }
  }
  var calls: Int { state.withLock { $0.calls } }

  func count() -> Int {
    state.withLock { state in
      state.calls += 1
      return state.value
    }
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
  let activeCount = FakeActiveCount()
  let scheduler: RecoveryScheduler

  init(connector: FakeConnector) {
    self.connector = connector
    let recovery = ZeroActiveRecovery(
      sampler: ScriptedSampler([.success([display(1, active: false)])]), connector: connector,
      sleep: { _ in })
    let settle = settle
    let outcomes = outcomes
    let activeCount = activeCount
    scheduler = RecoveryScheduler(
      recovery: recovery, activeCount: { activeCount.count() },
      sleep: { await settle.sleep($0) }, onOutcome: { outcomes.append($0) })
  }

  func settleAndDrain(sleeps: Int) async {
    _ = await settle.waitForSleeps(sleeps)
    await settle.advanceAll()
    await scheduler.drain()
  }

  func fire(_ trigger: RecoveryTrigger) async {
    await scheduler.trigger(trigger)
    await settleAndDrain(sleeps: 1)
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

private func enabled(_ id: UInt32) -> DisplayConnectionOutcome {
  DisplayConnectionOutcome(
    display: display(id, active: false), result: .success(display(id, active: true)))
}

private func stuck(_ id: UInt32) -> DisplayConnectionOutcome {
  DisplayConnectionOutcome(
    display: display(id, active: false), result: .failure(.postconditionFailed("stuck")))
}
