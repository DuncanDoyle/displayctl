import CoreGraphics
import Foundation
import XCTest

@testable import DisplayControlCore

final class ConnectionControllerTests: XCTestCase {
  func testConnectInactiveDisplayReturnsRefreshedActiveDisplay() throws {
    let store = FakeDisplayStore([fixture(1, active: false), fixture(2, active: true)])
    let controller = makeController(store)

    let display = try controller.connect("1")

    XCTAssertTrue(display.isActive)
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true)])
  }

  func testDisconnectActiveDisplayReturnsRefreshedInactiveDisplay() throws {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: true)])
    let controller = makeController(store)

    let display = try controller.disconnect("1")

    XCTAssertFalse(display.isActive)
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: false)])
  }

  func testRejectsTransitionsFromInvalidStateBeforeHardwareCall() {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: false)])
    let controller = makeController(store)

    XCTAssertThrowsError(try controller.connect("1")) {
      XCTAssertEqual($0 as? DisplayControlError, .invalidState("Display 1 is already active"))
    }
    XCTAssertThrowsError(try controller.disconnect("2")) {
      XCTAssertEqual($0 as? DisplayControlError, .invalidState("Display 2 is already inactive"))
    }
    XCTAssertEqual(store.requests.count, 0)
  }

  func testDisconnectRefusesLastActiveBeforeHardwareCall() {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: false)])
    let controller = makeController(store)

    XCTAssertThrowsError(try controller.disconnect("1")) {
      XCTAssertEqual($0 as? DisplayControlError, .lastActiveDisplay)
    }
    XCTAssertEqual(store.requests.count, 0)
  }

  func testConcurrentControllersSerializeLastActiveValidation() {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: true)])
    let operationLock = FakeOperationLock()
    let first = makeController(store, lock: operationLock)
    let second = makeController(store, lock: operationLock)
    let start = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let results = ResultCollector()

    for (controller, selector) in [(first, "1"), (second, "2")] {
      group.enter()
      DispatchQueue.global().async {
        start.wait()
        results.append(Result { try controller.disconnect(selector) })
        group.leave()
      }
    }
    start.signal()
    start.signal()

    XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(results.successCount, 1)
    XCTAssertEqual(results.failures, [.lastActiveDisplay])
    XCTAssertEqual(store.displays.filter(\.isActive).count, 1)
  }

  func testLockFailurePreventsSnapshotAndHardwareAccess() {
    let store = FakeDisplayStore([fixture(1, active: false)])
    let lock = FailingOperationLock(error: .configurationFailed("lock unavailable"))
    let controller = makeController(store, lock: lock)

    XCTAssertThrowsError(try controller.connect("1")) {
      XCTAssertEqual($0 as? DisplayControlError, .configurationFailed("lock unavailable"))
    }
    XCTAssertEqual(store.snapshotCount, 0)
    XCTAssertEqual(store.requests, [])
  }

  func testSelectionFailuresPropagate() {
    let store = FakeDisplayStore([
      fixture(1, active: true, kind: .external),
      fixture(2, active: true, kind: .external),
    ])
    let controller = makeController(store)

    XCTAssertThrowsError(try controller.connect("missing")) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound("missing"))
    }
    XCTAssertThrowsError(try controller.disconnect("external")) {
      XCTAssertEqual($0 as? DisplayControlError, .ambiguousSelector("external"))
    }
  }

  func testPostconditionFailureAfterRefresh() {
    let store = FakeDisplayStore([fixture(1, active: false), fixture(2, active: true)])
    store.appliesChanges = false

    XCTAssertThrowsError(try makeController(store).connect("1")) {
      assertPostcondition($0, contains: [store.displays[0].uuid.uuidString, "active"])
    }
    XCTAssertEqual(store.snapshotCount, 2)
  }

  func testConnectAllAttemptsEligibleDisplaysInInventoryOrder() throws {
    let displays = [fixture(3, active: false), fixture(1, active: true), fixture(2, active: false)]
    let store = FakeDisplayStore(displays)
    store.failureIDs = [3]

    let outcomes = try makeController(store).connectAll()

    XCTAssertEqual(store.requests, [.init(id: 3, enabled: true), .init(id: 2, enabled: true)])
    XCTAssertEqual(outcomes.map(\.display), [displays[0], displays[2]])
    assertFailure(outcomes[0].result, .configurationFailed("fake failure 3"))
    XCTAssertEqual(try outcomes[1].result.get().runtimeID, 2)
  }

  func testConnectAllTreatsCandidateActivatedBeforeTurnAsSuccessAndContinues() throws {
    let store = FakeDisplayStore([
      fixture(1, active: false), fixture(2, active: false), fixture(3, active: false),
    ])
    store.activateWhenEnabled = [1: 2]
    let operationLock = FakeOperationLock()
    let controller = makeController(store, lock: operationLock)

    let outcomes = try controller.connectAll()

    XCTAssertEqual(outcomes.map(\.display), store.initialDisplays)
    XCTAssertEqual(try outcomes.map { try $0.result.get().runtimeID }, [1, 2, 3])
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true), .init(id: 3, enabled: true)])
    XCTAssertEqual(operationLock.acquisitionCount, 1)
  }

  func testRecoverIfNoneActiveReturnsNilWhenADisplayIsActive() throws {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: false)])

    XCTAssertNil(try makeController(store).recoverIfNoneActive())
    XCTAssertEqual(store.requests, [])
  }

  func testRecoverIfNoneActiveEnablesLedgerAndOnlineInactiveAtZero() throws {
    let online = fixture(1, active: false)
    let external = fixture(3, active: true, kind: .external)
    let store = FakeDisplayStore([online])
    let ledger = FakeLedger([entry(for: external)])
    store.reactions = [.init(id: 3, enabled: true): [replacing(online, active: true), external]]

    let outcomes = try XCTUnwrap(makeController(store, ledger: ledger).recoverIfNoneActive())

    XCTAssertEqual(outcomes.map(\.display?.uuid), [online.uuid, external.uuid])
    XCTAssertEqual(try outcomes.map { try $0.result.get().isActive }, [true, true])
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true), .init(id: 3, enabled: true)])
    XCTAssertEqual(ledger.entries, [])
  }

  func testRecoverAfterCLIConnectWinsLockEnablesNothing() throws {
    let store = FakeDisplayStore([fixture(1, active: false), fixture(2, active: false)])
    let lock = PreemptedOperationLock()
    let controller = makeController(store, lock: lock)
    // The CLI's connect takes the lock just before the recovery body runs.
    lock.beforeNextOperation = { _ = try? controller.connect("1") }

    XCTAssertNil(try controller.recoverIfNoneActive())
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true)])
    XCTAssertEqual(store.displays.map(\.isActive), [true, false])
  }

  func testDisplayConnectionOutcomePublicInitializerPreservesTypedFailure() {
    let display = fixture(1, active: false)
    let outcome = DisplayConnectionOutcome(
      display: display,
      result: .failure(.configurationFailed("failed"))
    )

    XCTAssertEqual(outcome.display, display)
    assertFailure(outcome.result, .configurationFailed("failed"))
  }

  func testDarwinLocksContendAndReleaseAfterSuccess() throws {
    let lockURL = uniqueLockURL()
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let holder = DarwinDisplayOperationLock(
      lockURL: lockURL, maximumAttempts: 100, retryDelayMicroseconds: 1_000)
    let contender = DarwinDisplayOperationLock(
      lockURL: lockURL, maximumAttempts: 2, retryDelayMicroseconds: 1_000)
    let acquired = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    DispatchQueue.global().async {
      defer { finished.signal() }
      try? holder.withLock {
        acquired.signal()
        release.wait()
      }
    }
    XCTAssertEqual(acquired.wait(timeout: .now() + 2), .success)
    XCTAssertThrowsError(try contender.withLock {}) {
      XCTAssertEqual($0 as? DisplayControlError, .lockTimeout)
    }
    release.signal()
    XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    XCTAssertNoThrow(try contender.withLock {})
  }

  func testDarwinLockReleasesAfterProtectedClosureThrows() {
    let lockURL = uniqueLockURL()
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let first = DarwinDisplayOperationLock(lockURL: lockURL)
    let second = DarwinDisplayOperationLock(lockURL: lockURL)

    XCTAssertThrowsError(try first.withLock { throw TestLockError.expected }) {
      XCTAssertTrue($0 is TestLockError)
    }
    XCTAssertNoThrow(try second.withLock {})
  }

  func testRefreshFailureAfterMutationBecomesPostconditionFailureWithUUIDAndCause() {
    let store = FakeDisplayStore([fixture(1, active: false)])
    store.snapshotFailureCall = 2

    XCTAssertThrowsError(try makeController(store).connect("1")) {
      assertPostcondition($0, contains: [store.displays[0].uuid.uuidString, "refresh failed"])
    }
  }

  func testPostconditionRequiresExactlyOneMatchingUUID() {
    let store = FakeDisplayStore([fixture(1, active: false)])
    store.duplicateAfterMutation = true

    XCTAssertThrowsError(try makeController(store).connect("1")) {
      assertPostcondition($0, contains: [store.displays[0].uuid.uuidString, "2 matches"])
    }
  }

  func testPostconditionRejectsMissingUUID() {
    let store = FakeDisplayStore([fixture(1, active: false)])
    store.removeAfterMutation = true

    XCTAssertThrowsError(try makeController(store).connect("1")) {
      assertPostcondition($0, contains: ["0 matches"])
    }
  }

  func testDisconnectSucceedsWhenDisabledDisplayDisappearsFromInventory() throws {
    let external = fixture(1, active: true, kind: .external)
    let other = fixture(2, active: true)
    let store = FakeDisplayStore([external, other])
    let ledger = FakeLedger()
    // macOS 26.5 and 27 drop a disabled display from the online list (hardware, D-005).
    store.reactions = [.init(id: 1, enabled: false): [other]]
    let controller = makeController(store, ledger: ledger)

    let display = try controller.disconnect("1")

    XCTAssertEqual(display.uuid, external.uuid)
    XCTAssertFalse(display.isActive)
    XCTAssertFalse(display.isOnline)
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: false)])
    XCTAssertEqual(ledger.entries, [entry(for: external)])

    // The ledger is then the only route back, and it works.
    store.reactions = [.init(id: 1, enabled: true): [external, other]]
    XCTAssertTrue(try controller.connect(external.uuid.uuidString).isActive)
    XCTAssertEqual(ledger.entries, [])
  }

  func testDisableFollowedByInconsistentInventoryRefreshIsNotSuccess() {
    let target = fixture(1, active: true)
    let other = fixture(2, active: true)
    let hardware = FakeDisplayStore([target, other])
    hardware.appliesChanges = false
    // The refresh's online sample omits the target while its active sample still holds it.
    let refresh = DisplayInventory(
      candidateDetector: UnknownDDCCandidateDetector(), onlineIDs: { [] }, activeIDs: { [1] })
    let snapshot = ScriptedSnapshot { call in
      call == 2 ? try refresh.snapshot() : [target, other]
    }
    let controller = ConnectionController(
      snapshot: snapshot, hardware: hardware, lock: FakeOperationLock(), ledger: FakeLedger(),
      bootSession: { currentBoot }, runtimeIDOwner: { _ in nil })

    XCTAssertThrowsError(try controller.disconnect("1")) {
      assertPostcondition($0, contains: ["inventoryChanged", "rollback not needed"])
    }
    XCTAssertEqual(hardware.requests, [.init(id: 1, enabled: false)])
  }

  func testDisconnectFailsWhenTargetLeavesListAndNothingIsActive() {
    let target = fixture(1, active: true)
    let other = fixture(2, active: true, kind: .external)
    let store = FakeDisplayStore([target, other])
    // Other display unplugged and the disabled target dropped from the list (D-005): nothing left.
    store.reactions = [
      .init(id: 1, enabled: false): [],
      .init(id: 1, enabled: true): [target],
    ]

    XCTAssertThrowsError(try makeController(store).disconnect("1")) {
      assertPostcondition($0, contains: ["no active display", "rollback enabled true completed"])
    }
    // Rollback found the target absent and enabled it by its recorded runtime ID.
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: false), .init(id: 1, enabled: true)])
  }

  func testDisconnectFailsAndRollsBackWhenNoDisplayRemainsActive() {
    let target = fixture(1, active: true)
    let other = fixture(2, active: true, kind: .external)
    let store = FakeDisplayStore([target, other])
    // The other display is unplugged between the last-active check and the disable.
    store.beforeRequest = { request in
      guard request == .init(id: 1, enabled: false) else { return }
      store.displays = [store.displays[0]]
    }

    XCTAssertThrowsError(try makeController(store).disconnect("1")) {
      assertPostcondition($0, contains: ["no active display", "rollback enabled true completed"])
    }
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: false), .init(id: 1, enabled: true)])
    XCTAssertTrue(store.displays.contains { $0.runtimeID == 1 && $0.isActive })
  }

  func testDisconnectRecordsLedgerEntryBeforeDisabling() throws {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: true)])
    let ledger = FakeLedger()
    var entriesAtDisable: [DisabledDisplayEntry]?
    store.beforeRequest = { request in
      if !request.enabled { entriesAtDisable = ledger.entries }
    }

    _ = try makeController(store, ledger: ledger).disconnect("1")

    XCTAssertEqual(entriesAtDisable, [entry(for: store.initialDisplays[0])])
  }

  func testRecordedIDMappedToAnotherUUIDRightBeforeEnableIsSkipped() throws {
    let external = fixture(1, active: true, kind: .external)
    let hidden = fixture(7, active: false).uuid
    let store = FakeDisplayStore([fixture(2, active: true)])
    let ledger = FakeLedger([entry(for: external)])
    // Core Graphics maps ID 1 to a display that the online list does not show.
    let controller = makeController(
      store, ledger: ledger, runtimeIDOwner: { $0 == 1 ? hidden : nil })

    XCTAssertThrowsError(try controller.connect(external.uuid.uuidString)) {
      assertSkipped($0, contains: ["runtime ID 1", hidden.uuidString])
    }
    let outcomes = try controller.connectAll()

    XCTAssertEqual(outcomes.count, 1)
    guard case .failure(let error) = outcomes[0].result else { return XCTFail("expected skip") }
    assertSkipped(error, contains: ["runtime ID 1", hidden.uuidString])
    XCTAssertEqual(store.requests, [])
    XCTAssertEqual(ledger.entries, [entry(for: external)])
  }

  func testRecordedIDMappedToOwnUUIDIsEnabled() throws {
    let external = fixture(1, active: true, kind: .external)
    let other = fixture(2, active: true)
    let store = FakeDisplayStore([other])
    let ledger = FakeLedger([entry(for: external)])
    store.reactions = [.init(id: 1, enabled: true): [external, other]]
    let controller = makeController(
      store, ledger: ledger, runtimeIDOwner: { $0 == 1 ? external.uuid : nil })

    XCTAssertTrue(try controller.connect(external.uuid.uuidString).isActive)
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true)])
  }

  func testRollbackSkipsRecordedIDMappedToAnotherUUID() {
    let external = fixture(1, active: true, kind: .external)
    let other = fixture(2, active: true)
    let hidden = fixture(7, active: false).uuid
    let store = FakeDisplayStore([external, other])
    let ledger = FakeLedger()
    store.reactions = [.init(id: 1, enabled: false): [other]]
    store.snapshotFailureCall = 2
    let controller = makeController(store, ledger: ledger, runtimeIDOwner: { _ in hidden })

    XCTAssertThrowsError(try controller.disconnect("1")) {
      assertPostcondition($0, contains: ["rollback skipped", "runtime ID 1", hidden.uuidString])
    }
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: false)])
    XCTAssertEqual(ledger.entries, [entry(for: external)])
  }

  func testUnreadableLedgerStillRecoversOnlineDisplaysAndReportsLedgerFailure() throws {
    let inactive = fixture(3, active: false)
    let store = FakeDisplayStore([fixture(2, active: true), inactive])
    let ledger = FakeLedger()
    ledger.loadError = .configurationFailed("Unable to decode display ledger")

    let outcomes = try makeController(store, ledger: ledger).connectAll()

    XCTAssertEqual(outcomes.count, 2)
    XCTAssertEqual(try outcomes[0].result.get().isActive, true)
    XCTAssertNil(outcomes[1].display)
    assertFailure(outcomes[1].result, .configurationFailed("Unable to decode display ledger"))
    XCTAssertEqual(store.requests, [.init(id: 3, enabled: true)])
  }

  func testConnectKindSelectorWithUnreadableLedgerNamesRecoveryRoutes() {
    let inactive = fixture(2, active: false, kind: .external)
    let store = FakeDisplayStore([fixture(1, active: true), inactive])
    let ledger = FakeLedger()
    ledger.loadError = .configurationFailed("Unable to decode display ledger")

    XCTAssertThrowsError(try makeController(store, ledger: ledger).connect("external")) {
      XCTAssertEqual(
        $0 as? DisplayControlError,
        .configurationFailed(
          "Unable to decode display ledger; use connect <UUID>, connect all, or forget all"
        )
      )
    }
    XCTAssertEqual(store.requests, [])
  }

  // Acceptance test 1.
  func testLaterConnectAllRestoresDisplayWhoseRollbackFailed() throws {
    let directory = uniqueStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let external = fixture(1, active: true, kind: .external)
    let other = fixture(2, active: true)
    let store = FakeDisplayStore([external, other])
    store.reactions = [.init(id: 1, enabled: false): [other]]
    store.failingRequests = [.init(id: 1, enabled: true)]
    store.snapshotFailureCall = 2

    XCTAssertThrowsError(try fileController(store, directory: directory).disconnect("1")) {
      assertPostcondition($0, contains: ["refresh failed", "rollback enabled true failed"])
    }
    XCTAssertEqual(try ledgerEntries(in: directory), [entry(for: external)])

    // A new process: macOS now honours the enable and lists the display again.
    store.failingRequests = []
    store.reactions = [.init(id: 1, enabled: true): [external, other]]
    let outcomes = try fileController(store, directory: directory).connectAll()

    XCTAssertEqual(outcomes.map(\.display?.uuid), [external.uuid])
    XCTAssertEqual(try outcomes[0].result.get().isActive, true)
    XCTAssertEqual(store.requests.last, .init(id: 1, enabled: true))
    XCTAssertEqual(try ledgerEntries(in: directory), [])
  }

  // Acceptance test 2.
  // The everyday flow: `disconnect internal`, then `connect internal` once it left the list.
  func testConnectKindSelectorFindsTheOnlyLedgerDisplayOfThatKind() throws {
    let builtIn = fixture(1, active: true, kind: .internal)
    let dell = fixture(2, active: true, kind: .external)
    let store = FakeDisplayStore([dell])
    let ledger = FakeLedger([entry(for: builtIn)])
    store.reactions = [.init(id: 1, enabled: true): [builtIn, dell]]

    let display = try makeController(store, ledger: ledger).connect("internal")

    XCTAssertEqual(display.uuid, builtIn.uuid)
    XCTAssertTrue(display.isActive)
    XCTAssertEqual(ledger.entries, [])
  }

  func testConnectKindSelectorIsAmbiguousAcrossOnlineAndLedgerCandidates() {
    let builtIn = fixture(1, active: true)
    let onlineDark = fixture(2, active: false, kind: .external)
    let ledgerOnly = fixture(3, active: true, kind: .external)
    let store = FakeDisplayStore([builtIn, onlineDark])
    let ledger = FakeLedger([entry(for: ledgerOnly)])

    XCTAssertThrowsError(try makeController(store, ledger: ledger).connect("external")) {
      XCTAssertEqual($0 as? DisplayControlError, .ambiguousSelector("external"))
    }
    XCTAssertEqual(store.requests, [])
    XCTAssertEqual(ledger.entries, [entry(for: ledgerOnly)])
  }

  func testConnectKindSelectorSkipsActiveOnlineDisplayForLedgerCandidate() throws {
    let builtIn = fixture(1, active: true)
    let onlineActive = fixture(2, active: true, kind: .external)
    let ledgerOnly = fixture(3, active: true, kind: .external)
    let store = FakeDisplayStore([builtIn, onlineActive])
    let ledger = FakeLedger([entry(for: ledgerOnly)])
    store.reactions = [.init(id: 3, enabled: true): [builtIn, onlineActive, ledgerOnly]]

    let display = try makeController(store, ledger: ledger).connect("external")

    XCTAssertEqual(display.uuid, ledgerOnly.uuid)
    XCTAssertTrue(display.isActive)
    XCTAssertEqual(store.requests, [.init(id: 3, enabled: true)])
    XCTAssertEqual(ledger.entries, [])
  }

  func testConnectUUIDForLedgerOnlyDisplayEnablesRecordedIDAndClearsEntry() throws {
    let external = fixture(1, active: true, kind: .external)
    let other = fixture(2, active: true)
    let store = FakeDisplayStore([other])
    let ledger = FakeLedger([entry(for: external)])
    store.reactions = [.init(id: 1, enabled: true): [external, other]]

    let display = try makeController(store, ledger: ledger).connect(external.uuid.uuidString)

    XCTAssertEqual(display.uuid, external.uuid)
    XCTAssertTrue(display.isActive)
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true)])
    XCTAssertEqual(ledger.entries, [])
  }

  // Acceptance test 3.
  func testRollbackEnablesCurrentRuntimeIDWhenUUIDReappearsUnderNewID() {
    let external = fixture(1, active: true, kind: .external)
    let other = fixture(2, active: true)
    let renumbered = fixture(uuid: 1, runtimeID: 5, active: false)
    let store = FakeDisplayStore([external, other])
    let ledger = FakeLedger()
    store.reactions = [.init(id: 1, enabled: false): [other]]
    store.snapshotFailureCall = 2
    // By the time the rollback looks again, macOS lists the display under a new ID.
    store.displaysAtSnapshot = [3: [renumbered, other]]

    XCTAssertThrowsError(try makeController(store, ledger: ledger).disconnect("1")) {
      assertPostcondition($0, contains: ["refresh failed", "rollback enabled true completed"])
    }
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: false), .init(id: 5, enabled: true)])
    XCTAssertEqual(ledger.entries, [])
  }

  func testConnectUUIDUsesCurrentRuntimeIDWhenOnlineUnderNewID() throws {
    let renumbered = fixture(uuid: 1, runtimeID: 5, active: false)
    let store = FakeDisplayStore([renumbered, fixture(2, active: true)])
    let ledger = FakeLedger([entry(for: renumbered, runtimeID: 1)])

    let display = try makeController(store, ledger: ledger).connect(renumbered.uuid.uuidString)

    XCTAssertEqual(display.runtimeID, 5)
    XCTAssertEqual(store.requests, [.init(id: 5, enabled: true)])
    XCTAssertEqual(ledger.entries, [])
  }

  // Acceptance test 4.
  func testRecordedIDHeldByAnotherUUIDIsSkippedWithoutMutation() throws {
    let external = fixture(1, active: true, kind: .external)
    let impostor = fixture(uuid: 7, runtimeID: 1, active: true)
    let store = FakeDisplayStore([impostor, fixture(2, active: true)])
    let ledger = FakeLedger([entry(for: external)])
    let controller = makeController(store, ledger: ledger)

    XCTAssertThrowsError(try controller.connect(external.uuid.uuidString)) {
      assertSkipped($0, contains: ["runtime ID 1", impostor.uuid.uuidString])
    }
    let outcomes = try controller.connectAll()

    XCTAssertEqual(outcomes.map(\.display?.uuid), [external.uuid])
    guard case .failure(let error) = outcomes[0].result else { return XCTFail("expected skip") }
    assertSkipped(error, contains: ["runtime ID 1"])
    XCTAssertEqual(store.requests, [])
    XCTAssertEqual(ledger.entries, [entry(for: external)])
  }

  func testRollbackSkipsRecordedIDNowHeldByAnotherUUID() {
    let external = fixture(1, active: true, kind: .external)
    let other = fixture(2, active: true)
    let impostor = fixture(uuid: 7, runtimeID: 1, active: false)
    let store = FakeDisplayStore([external, other])
    let ledger = FakeLedger()
    store.reactions = [.init(id: 1, enabled: false): [other]]
    store.snapshotFailureCall = 2
    store.displaysAtSnapshot = [3: [other, impostor]]

    XCTAssertThrowsError(try makeController(store, ledger: ledger).disconnect("1")) {
      assertPostcondition($0, contains: ["refresh failed", "rollback skipped", "runtime ID 1"])
    }
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: false)])
    XCTAssertEqual(ledger.entries, [entry(for: external)])
  }

  // Acceptance test 5.
  func testEntryFromEarlierBootIsSkippedWithoutMutation() throws {
    let external = fixture(1, active: true, kind: .external)
    let store = FakeDisplayStore([fixture(2, active: true)])
    let stale = entry(for: external, bootSession: "earlier-boot-session")
    let ledger = FakeLedger([stale])
    let controller = makeController(store, ledger: ledger)

    XCTAssertThrowsError(try controller.connect(external.uuid.uuidString)) {
      assertSkipped($0, contains: ["earlier boot"])
    }
    let outcomes = try controller.connectAll()

    XCTAssertEqual(outcomes.count, 1)
    guard case .failure(let error) = outcomes[0].result else { return XCTFail("expected skip") }
    assertSkipped(error, contains: ["earlier boot"])
    XCTAssertEqual(store.requests, [])
    XCTAssertEqual(ledger.entries, [stale])
  }

  // Acceptance test 6.
  func testEnableWithoutUUIDBecomingActiveFailsAndKeepsEntry() {
    let external = fixture(1, active: true, kind: .external)
    let store = FakeDisplayStore([fixture(2, active: true)])
    let ledger = FakeLedger([entry(for: external)])

    XCTAssertThrowsError(
      try makeController(store, ledger: ledger).connect(external.uuid.uuidString)
    ) {
      assertPostcondition($0, contains: [external.uuid.uuidString, "0 matches"])
    }
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true)])
    XCTAssertEqual(ledger.entries, [entry(for: external)])
  }

  // Acceptance test 7.
  func testLedgerWriteFailureRefusesDisconnectWithoutHardwareCall() throws {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: true)])
    let ledger = FakeLedger()
    ledger.saveError = .configurationFailed("disk full")

    XCTAssertThrowsError(try makeController(store, ledger: ledger).disconnect("1")) {
      XCTAssertEqual($0 as? DisplayControlError, .configurationFailed("disk full"))
    }
    XCTAssertEqual(store.requests, [])

    // The file ledger fails the same way when its directory is read-only.
    let directory = uniqueStateDirectory()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let fileLedger = FileDisabledDisplayLedger(url: DisplayControlState.ledgerURL(in: directory))
    XCTAssertThrowsError(try makeController(store, ledger: fileLedger).disconnect("1")) {
      guard case .configurationFailed(let message) = $0 as? DisplayControlError else {
        return XCTFail("unexpected error \($0)")
      }
      XCTAssertTrue(message.contains("Unable to write display ledger"), message)
    }
    XCTAssertEqual(store.requests, [])
  }

  // Acceptance test 8.
  func testConnectAllReportsStaleEntryAndStillReconnectsOthers() throws {
    let unplugged = fixture(1, active: true, kind: .external)
    let inactive = fixture(3, active: false)
    let store = FakeDisplayStore([fixture(2, active: true), inactive])
    let ledger = FakeLedger([entry(for: unplugged)])
    store.failingRequests = [.init(id: 1, enabled: true)]

    let outcomes = try makeController(store, ledger: ledger).connectAll()

    XCTAssertEqual(outcomes.map(\.display?.uuid), [inactive.uuid, unplugged.uuid])
    XCTAssertEqual(try outcomes[0].result.get().isActive, true)
    assertFailure(outcomes[1].result, .configurationFailed("fake failure 1"))
    XCTAssertEqual(store.requests, [.init(id: 3, enabled: true), .init(id: 1, enabled: true)])
    XCTAssertEqual(ledger.entries, [entry(for: unplugged)])
  }

  func testConnectAllClearsEntryForDisplayAlreadyActiveAgain() throws {
    let reverted = fixture(1, active: true, kind: .external)
    let store = FakeDisplayStore([reverted, fixture(2, active: true)])
    let ledger = FakeLedger([entry(for: reverted)])

    let outcomes = try makeController(store, ledger: ledger).connectAll()

    XCTAssertEqual(outcomes.map(\.display?.uuid), [reverted.uuid])
    XCTAssertEqual(try outcomes[0].result.get().isActive, true)
    XCTAssertEqual(store.requests, [])
    XCTAssertEqual(ledger.entries, [])
  }

  func testForgetRemovesEntriesWithoutTouchingDisplays() throws {
    let first = fixture(1, active: true, kind: .external)
    let second = fixture(3, active: true, kind: .external)
    let store = FakeDisplayStore([fixture(2, active: true)])
    let ledger = FakeLedger([entry(for: first), entry(for: second)])
    let controller = makeController(store, ledger: ledger)

    XCTAssertEqual(try controller.forget(first.uuid), entry(for: first))
    XCTAssertEqual(ledger.entries, [entry(for: second)])
    XCTAssertThrowsError(try controller.forget(first.uuid)) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound(first.uuid.uuidString))
    }
    XCTAssertEqual(try controller.forgetAll(), [entry(for: second)])
    XCTAssertEqual(ledger.entries, [])
    XCTAssertEqual(store.requests, [])
    XCTAssertEqual(store.snapshotCount, 0)
  }

  func testForgetAllResetsUndecodableLedgerAndForgetOneSuggestsIt() throws {
    let directory = uniqueStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = DisplayControlState.ledgerURL(in: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    let store = FakeDisplayStore([fixture(2, active: true)])
    let controller = fileController(store, directory: directory)

    XCTAssertThrowsError(try controller.forget(fixture(1, active: true).uuid)) {
      guard case .configurationFailed(let message) = $0 as? DisplayControlError else {
        return XCTFail("unexpected error \($0)")
      }
      XCTAssertTrue(message.contains("forget all"), message)
    }
    XCTAssertEqual(try controller.forgetAll(), [])
    XCTAssertEqual(try ledgerEntries(in: directory), [])
    XCTAssertEqual(store.requests, [])
  }

  func testFileLedgerRoundTripsAndTreatsMissingFileAsEmpty() throws {
    let directory = uniqueStateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = FileDisabledDisplayLedger(url: DisplayControlState.ledgerURL(in: directory))
    let recorded = entry(for: fixture(1, active: true, kind: .external))

    XCTAssertEqual(try ledger.load(), [])
    try ledger.save([recorded])

    XCTAssertEqual(try ledger.load(), [recorded])
  }

  func testBootSessionIsAStableUUIDWithinABoot() throws {
    let session = try BootSession.current()

    XCTAssertNotNil(UUID(uuidString: session), session)
    XCTAssertEqual(session, try BootSession.current())
  }

  func testCoreGraphicsTransactionCancelsEveryFailureAfterBegin() {
    for stage in TransactionStage.allCases {
      let api = FakeTransactionAPI(failingAt: stage)
      let hardware = CoreGraphicsDisplayConnectionHardware(api: api.functions)

      XCTAssertThrowsError(try hardware.setEnabled(7, enabled: true)) {
        guard case .configurationFailed(let message) = $0 as? DisplayControlError else {
          return XCTFail("unexpected error \($0)")
        }
        XCTAssertTrue(message.contains(stage.apiName))
        XCTAssertTrue(message.contains(String(stage.error.rawValue)))
        XCTAssertTrue(message.contains("display 7"))
        XCTAssertTrue(message.contains("enabled true"))
      }
      let expected = stage == .begin ? ["begin"] : stage.expectedOperations + ["cancel"]
      XCTAssertEqual(api.operations, expected)
      XCTAssertEqual(api.cancelCount, stage == .begin ? 0 : 1)
      if stage == .complete {
        XCTAssertEqual(api.cancelConfigs, [api.config])
      }
    }
  }

  func testCoreGraphicsTransactionCompletesWithoutCancellation() throws {
    let api = FakeTransactionAPI()

    try CoreGraphicsDisplayConnectionHardware(api: api.functions).setEnabled(7, enabled: false)

    XCTAssertEqual(api.operations, ["begin", "enable:7:false", "complete"])
    XCTAssertEqual(api.cancelCount, 0)
    XCTAssertEqual(api.enableConfigs, [api.config])
    XCTAssertEqual(api.completeConfigs, [api.config])
    XCTAssertEqual(api.completeOptions, [.forSession])
  }

  func testCoreGraphicsTransactionCancelsNilConfigAndResolutionFailure() {
    for api in [FakeTransactionAPI(nilConfig: true), FakeTransactionAPI(enableThrows: true)] {
      XCTAssertThrowsError(
        try CoreGraphicsDisplayConnectionHardware(api: api.functions).setEnabled(7, enabled: true)
      )
      XCTAssertEqual(api.cancelCount, 1)
      XCTAssertEqual(api.operations.last, "cancel")
      let expectedConfig: CGDisplayConfigRef? = api.nilConfig ? nil : api.config
      XCTAssertEqual(api.cancelConfigs, [expectedConfig])
    }
  }

  func testCancellationUsesBeginConfigAndPreservesCancellationFailure() {
    let api = FakeTransactionAPI(failingAt: .enable, cancelError: .failure)

    XCTAssertThrowsError(
      try CoreGraphicsDisplayConnectionHardware(api: api.functions).setEnabled(7, enabled: true)
    ) {
      guard case .configurationFailed(let message) = $0 as? DisplayControlError else {
        return XCTFail("unexpected error \($0)")
      }
      XCTAssertTrue(message.contains("CGSConfigureDisplayEnabled"))
      XCTAssertTrue(message.contains(String(CGError.illegalArgument.rawValue)))
      XCTAssertTrue(message.contains("CGCancelDisplayConfiguration"))
      XCTAssertTrue(message.contains(String(CGError.failure.rawValue)))
      XCTAssertTrue(message.contains("display 7"))
      XCTAssertTrue(message.contains("enabled true"))
    }
    XCTAssertEqual(api.cancelConfigs, [api.config])
  }
}

private final class FakeDisplayStore: DisplaySnapshotProviding, DisplayConnectionHardware,
  @unchecked Sendable
{
  var displays: [Display]
  let initialDisplays: [Display]
  struct Request: Hashable {
    let id: UInt32
    let enabled: Bool
  }
  var requests: [Request] = []
  var failureIDs: Set<UInt32> = []
  var failingRequests: Set<Request> = []
  /// What macOS lists after a request; replaces the default toggle of the matching runtime ID.
  var reactions: [Request: [Display]] = [:]
  /// What macOS lists from the given snapshot call onwards (1-based).
  var displaysAtSnapshot: [Int: [Display]] = [:]
  var appliesChanges = true
  var snapshotCount = 0
  var snapshotFailureCall: Int?
  var activateWhenEnabled: [UInt32: UInt32] = [:]
  var duplicateAfterMutation = false
  var removeAfterMutation = false
  /// Runs as each hardware request arrives, before the fake applies it.
  var beforeRequest: ((Request) -> Void)?

  init(_ displays: [Display]) {
    self.displays = displays
    initialDisplays = displays
  }

  func snapshot() throws -> [Display] {
    snapshotCount += 1
    if snapshotCount == snapshotFailureCall {
      throw DisplayControlError.configurationFailed("refresh failed")
    }
    if let scripted = displaysAtSnapshot[snapshotCount] {
      displays = scripted
    }
    return displays
  }

  func setEnabled(_ displayID: UInt32, enabled: Bool) throws {
    let request = Request(id: displayID, enabled: enabled)
    requests.append(request)
    beforeRequest?(request)
    if failureIDs.contains(displayID) || failingRequests.contains(request) {
      throw DisplayControlError.configurationFailed("fake failure \(displayID)")
    }
    if let reaction = reactions[request] {
      displays = reaction
      return
    }
    guard appliesChanges, let index = displays.firstIndex(where: { $0.runtimeID == displayID })
    else {
      return
    }
    displays[index] = replacing(displays[index], active: enabled)
    if let activatedID = activateWhenEnabled[displayID],
      let activatedIndex = displays.firstIndex(where: { $0.runtimeID == activatedID })
    {
      displays[activatedIndex] = replacing(displays[activatedIndex], active: true)
    }
    if duplicateAfterMutation {
      displays.append(displays[index])
    }
    if removeAfterMutation {
      displays.remove(at: index)
    }
  }
}

/// Answers each snapshot call (1-based) from `respond`.
private final class ScriptedSnapshot: DisplaySnapshotProviding, @unchecked Sendable {
  private var calls = 0
  private let respond: (Int) throws -> [Display]

  init(_ respond: @escaping (Int) throws -> [Display]) {
    self.respond = respond
  }

  func snapshot() throws -> [Display] {
    calls += 1
    return try respond(calls)
  }
}

private final class FakeOperationLock: DisplayOperationLocking, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var acquisitionCount = 0

  func withLock<T>(_ operation: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    acquisitionCount += 1
    return try operation()
  }
}

/// Runs `beforeNextOperation` once, outside the lock, before the next protected operation.
private final class PreemptedOperationLock: DisplayOperationLocking, @unchecked Sendable {
  var beforeNextOperation: (() -> Void)?

  func withLock<T>(_ operation: () throws -> T) throws -> T {
    if let before = beforeNextOperation {
      beforeNextOperation = nil
      before()
    }
    return try operation()
  }
}

private struct FailingOperationLock: DisplayOperationLocking {
  let error: DisplayControlError

  func withLock<T>(_ operation: () throws -> T) throws -> T {
    throw error
  }
}

private final class ResultCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<Display, Error>] = []

  func append(_ result: Result<Display, Error>) {
    lock.withLock { results.append(result) }
  }

  var successCount: Int {
    lock.withLock {
      results.reduce(into: 0) { count, result in
        if case .success = result { count += 1 }
      }
    }
  }

  var failures: [DisplayControlError] {
    lock.withLock {
      results.compactMap {
        guard case .failure(let error) = $0 else { return nil }
        return error as? DisplayControlError
      }
    }
  }
}

private enum TransactionStage: CaseIterable {
  case begin, enable, complete

  var apiName: String {
    switch self {
    case .begin: "CGBeginDisplayConfiguration"
    case .enable: "CGSConfigureDisplayEnabled"
    case .complete: "CGCompleteDisplayConfiguration"
    }
  }

  var error: CGError { self == .begin ? .failure : .illegalArgument }
  var expectedOperations: [String] {
    switch self {
    case .begin: ["begin"]
    case .enable: ["begin", "enable:7:true"]
    case .complete: ["begin", "enable:7:true", "complete"]
    }
  }
}

private final class FakeTransactionAPI: @unchecked Sendable {
  var operations: [String] = []
  let config = CGDisplayConfigRef(bitPattern: 0x1234)
  let failingAt: TransactionStage?
  let nilConfig: Bool
  let enableThrows: Bool
  let cancelError: CGError
  var enableConfigs: [CGDisplayConfigRef?] = []
  var completeConfigs: [CGDisplayConfigRef?] = []
  var completeOptions: [CGConfigureOption] = []
  var cancelConfigs: [CGDisplayConfigRef?] = []

  init(
    failingAt: TransactionStage? = nil,
    nilConfig: Bool = false,
    enableThrows: Bool = false,
    cancelError: CGError = .success
  ) {
    self.failingAt = failingAt
    self.nilConfig = nilConfig
    self.enableThrows = enableThrows
    self.cancelError = cancelError
  }

  var cancelCount: Int { operations.filter { $0 == "cancel" }.count }
  var functions: CoreGraphicsDisplayTransactionFunctions {
    CoreGraphicsDisplayTransactionFunctions(
      begin: { config in
        self.operations.append("begin")
        if self.failingAt == .begin { return self.failingAt!.error }
        if !self.nilConfig { config.pointee = self.config }
        return .success
      },
      enable: { config, id, enabled in
        self.enableConfigs.append(config)
        self.operations.append("enable:\(id):\(enabled)")
        if self.enableThrows {
          throw DisplayControlError.unsupportedAPI("CGSConfigureDisplayEnabled")
        }
        return self.failingAt == .enable ? self.failingAt!.error : .success
      },
      complete: { config, option in
        self.completeConfigs.append(config)
        self.completeOptions.append(option)
        self.operations.append("complete")
        return self.failingAt == .complete ? self.failingAt!.error : .success
      },
      cancel: { config in
        self.cancelConfigs.append(config)
        self.operations.append("cancel")
        return self.cancelError
      }
    )
  }
}

private func fixture(_ id: UInt32, active: Bool, kind: DisplayKind = .internal) -> Display {
  Display(
    uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
    runtimeID: id,
    name: "Display \(id)",
    kind: kind,
    isOnline: true,
    isActive: active,
    isMain: id == 1 && active,
    ddcCapability: .unknown
  )
}

private func replacing(_ display: Display, active: Bool) -> Display {
  Display(
    uuid: display.uuid, runtimeID: display.runtimeID, name: display.name, kind: display.kind,
    isOnline: display.isOnline, isActive: active, isMain: display.isMain,
    ddcCapability: display.ddcCapability
  )
}

private func assertFailure(
  _ result: Result<Display, DisplayControlError>,
  _ expected: DisplayControlError
) {
  switch result {
  case .success: XCTFail("expected failure")
  case .failure(let error): XCTAssertEqual(error, expected)
  }
}

private let currentBoot = "current-boot-session"

private func makeController(
  _ store: FakeDisplayStore,
  lock: any DisplayOperationLocking = FakeOperationLock(),
  ledger: any DisabledDisplayLedger = FakeLedger(),
  runtimeIDOwner: @escaping @Sendable (UInt32) -> UUID? = { _ in nil }
) -> ConnectionController {
  ConnectionController(
    snapshot: store, hardware: store, lock: lock, ledger: ledger, bootSession: { currentBoot },
    runtimeIDOwner: runtimeIDOwner)
}

private func entry(
  for display: Display, runtimeID: UInt32? = nil, bootSession: String = currentBoot
) -> DisabledDisplayEntry {
  DisabledDisplayEntry(
    uuid: display.uuid, runtimeID: runtimeID ?? display.runtimeID, name: display.name,
    kind: display.kind, bootSession: bootSession)
}

/// A display whose UUID comes from `id` but whose runtime ID is set separately.
private func fixture(
  uuid id: UInt32, runtimeID: UInt32, active: Bool, kind: DisplayKind = .external
) -> Display {
  let base = fixture(id, active: active, kind: kind)
  return Display(
    uuid: base.uuid, runtimeID: runtimeID, name: base.name, kind: kind, isOnline: true,
    isActive: active, isMain: false, ddcCapability: .unknown)
}

/// A controller backed by the real file ledger and lock in `directory`, as a new process would be.
private func fileController(_ store: FakeDisplayStore, directory: URL) -> ConnectionController {
  ConnectionController(
    snapshot: store, hardware: store,
    lock: DarwinDisplayOperationLock(lockURL: DisplayControlState.lockURL(in: directory)),
    ledger: FileDisabledDisplayLedger(url: DisplayControlState.ledgerURL(in: directory)),
    bootSession: { currentBoot }, runtimeIDOwner: { _ in nil })
}

private func ledgerEntries(in directory: URL) throws -> [DisabledDisplayEntry] {
  try FileDisabledDisplayLedger(url: DisplayControlState.ledgerURL(in: directory)).load()
}

private func assertSkipped(_ error: Error, contains fragments: [String]) {
  guard case .recoverySkipped(let message) = error as? DisplayControlError else {
    return XCTFail("unexpected error \(error)")
  }
  for fragment in fragments {
    XCTAssertTrue(message.contains(fragment), "\(message) does not contain \(fragment)")
  }
}

private func uniqueStateDirectory() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("displaycontrol-tests-\(UUID().uuidString)", isDirectory: true)
}

private final class FakeLedger: DisabledDisplayLedger, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [DisabledDisplayEntry]
  var saveError: DisplayControlError?
  var loadError: DisplayControlError?

  init(_ entries: [DisabledDisplayEntry] = []) {
    stored = entries
  }

  var entries: [DisabledDisplayEntry] { lock.withLock { stored } }

  func load() throws -> [DisabledDisplayEntry] {
    if let loadError { throw loadError }
    return entries
  }

  func save(_ entries: [DisabledDisplayEntry]) throws {
    try lock.withLock {
      if let saveError { throw saveError }
      stored = entries
    }
  }
}

private func assertPostcondition(_ error: Error, contains fragments: [String]) {
  guard case .postconditionFailed(let message) = error as? DisplayControlError else {
    return XCTFail("unexpected error \(error)")
  }
  for fragment in fragments {
    XCTAssertTrue(message.contains(fragment), "\(message) does not contain \(fragment)")
  }
}

private enum TestLockError: Error {
  case expected
}

private func uniqueLockURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("displaycontrol-tests-\(UUID().uuidString).lock")
}
