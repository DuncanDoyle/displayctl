import CoreGraphics
import Foundation
import XCTest

@testable import DisplayControlCore

final class ConnectionControllerTests: XCTestCase {
  func testConnectInactiveDisplayReturnsRefreshedActiveDisplay() throws {
    let store = FakeDisplayStore([fixture(1, active: false), fixture(2, active: true)])
    let controller = ConnectionController(snapshot: store, hardware: store)

    let display = try controller.connect("1")

    XCTAssertTrue(display.isActive)
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true)])
  }

  func testDisconnectActiveDisplayReturnsRefreshedInactiveDisplay() throws {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: true)])
    let controller = ConnectionController(snapshot: store, hardware: store)

    let display = try controller.disconnect("1")

    XCTAssertFalse(display.isActive)
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: false)])
  }

  func testRejectsTransitionsFromInvalidStateBeforeHardwareCall() {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: false)])
    let controller = ConnectionController(snapshot: store, hardware: store)

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
    let controller = ConnectionController(snapshot: store, hardware: store)

    XCTAssertThrowsError(try controller.disconnect("1")) {
      XCTAssertEqual($0 as? DisplayControlError, .lastActiveDisplay)
    }
    XCTAssertEqual(store.requests.count, 0)
  }

  func testConcurrentControllersSerializeLastActiveValidation() {
    let store = FakeDisplayStore([fixture(1, active: true), fixture(2, active: true)])
    let operationLock = FakeOperationLock()
    let first = ConnectionController(snapshot: store, hardware: store, lock: operationLock)
    let second = ConnectionController(snapshot: store, hardware: store, lock: operationLock)
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
    let controller = ConnectionController(snapshot: store, hardware: store, lock: lock)

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
    let controller = ConnectionController(snapshot: store, hardware: store)

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

    XCTAssertThrowsError(try ConnectionController(snapshot: store, hardware: store).connect("1")) {
      assertPostcondition($0, contains: [store.displays[0].uuid.uuidString, "active"])
    }
    XCTAssertEqual(store.snapshotCount, 2)
  }

  func testConnectAllAttemptsEligibleDisplaysInInventoryOrder() throws {
    let displays = [fixture(3, active: false), fixture(1, active: true), fixture(2, active: false)]
    let store = FakeDisplayStore(displays)
    store.failureIDs = [3]

    let results = try ConnectionController(snapshot: store, hardware: store).connectAll()

    XCTAssertEqual(store.requests, [.init(id: 3, enabled: true), .init(id: 2, enabled: true)])
    XCTAssertEqual(results.count, 2)
    assertFailure(results[0], .configurationFailed("fake failure 3"))
    XCTAssertEqual(try results[1].get().runtimeID, 2)
  }

  func testConnectAllTreatsCandidateActivatedBeforeTurnAsSuccessAndContinues() throws {
    let store = FakeDisplayStore([
      fixture(1, active: false), fixture(2, active: false), fixture(3, active: false),
    ])
    store.activateWhenEnabled = [1: 2]
    let operationLock = FakeOperationLock()
    let controller = ConnectionController(
      snapshot: store, hardware: store, lock: operationLock)

    let results = try controller.connectAll()

    XCTAssertEqual(try results.map { try $0.get().runtimeID }, [1, 2, 3])
    XCTAssertEqual(store.requests, [.init(id: 1, enabled: true), .init(id: 3, enabled: true)])
    XCTAssertEqual(operationLock.acquisitionCount, 1)
  }

  func testRefreshFailureAfterMutationBecomesPostconditionFailureWithUUIDAndCause() {
    let store = FakeDisplayStore([fixture(1, active: false)])
    store.snapshotFailureCall = 2

    XCTAssertThrowsError(try controller(store).connect("1")) {
      assertPostcondition($0, contains: [store.displays[0].uuid.uuidString, "refresh failed"])
    }
  }

  func testPostconditionRequiresExactlyOneMatchingUUID() {
    let store = FakeDisplayStore([fixture(1, active: false)])
    store.duplicateAfterMutation = true

    XCTAssertThrowsError(try controller(store).connect("1")) {
      assertPostcondition($0, contains: [store.displays[0].uuid.uuidString, "2 matches"])
    }
  }

  func testPostconditionRejectsMissingUUID() {
    let store = FakeDisplayStore([fixture(1, active: false)])
    store.removeAfterMutation = true

    XCTAssertThrowsError(try controller(store).connect("1")) {
      assertPostcondition($0, contains: ["0 matches"])
    }
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
  struct Request: Equatable {
    let id: UInt32
    let enabled: Bool
  }
  var requests: [Request] = []
  var failureIDs: Set<UInt32> = []
  var appliesChanges = true
  var snapshotCount = 0
  var snapshotFailureCall: Int?
  var activateWhenEnabled: [UInt32: UInt32] = [:]
  var duplicateAfterMutation = false
  var removeAfterMutation = false

  init(_ displays: [Display]) { self.displays = displays }

  func snapshot() throws -> [Display] {
    snapshotCount += 1
    if snapshotCount == snapshotFailureCall {
      throw DisplayControlError.configurationFailed("refresh failed")
    }
    return displays
  }

  func setEnabled(_ displayID: UInt32, enabled: Bool) throws {
    requests.append(.init(id: displayID, enabled: enabled))
    if failureIDs.contains(displayID) {
      throw DisplayControlError.configurationFailed("fake failure \(displayID)")
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

private func controller(_ store: FakeDisplayStore) -> ConnectionController {
  ConnectionController(snapshot: store, hardware: store, lock: FakeOperationLock())
}

private func assertPostcondition(_ error: Error, contains fragments: [String]) {
  guard case .postconditionFailed(let message) = error as? DisplayControlError else {
    return XCTFail("unexpected error \(error)")
  }
  for fragment in fragments {
    XCTAssertTrue(message.contains(fragment), "\(message) does not contain \(fragment)")
  }
}
