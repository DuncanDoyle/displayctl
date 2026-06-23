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
      XCTAssertEqual(
        $0 as? DisplayControlError,
        .postconditionFailed("Display 1 did not become active")
      )
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
}

private final class FakeDisplayStore: DisplaySnapshotProviding, DisplayConnectionHardware,
  @unchecked Sendable
{
  var displays: [Display]
  struct Request: Equatable { let id: UInt32; let enabled: Bool }
  var requests: [Request] = []
  var failureIDs: Set<UInt32> = []
  var appliesChanges = true
  var snapshotCount = 0

  init(_ displays: [Display]) { self.displays = displays }

  func snapshot() throws -> [Display] {
    snapshotCount += 1
    return displays
  }

  func setEnabled(_ displayID: UInt32, enabled: Bool) throws {
    requests.append(.init(id: displayID, enabled: enabled))
    if failureIDs.contains(displayID) {
      throw DisplayControlError.configurationFailed("fake failure \(displayID)")
    }
    guard appliesChanges, let index = displays.firstIndex(where: { $0.runtimeID == displayID }) else {
      return
    }
    displays[index] = replacing(displays[index], active: enabled)
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
  let failingAt: TransactionStage?
  let nilConfig: Bool
  let enableThrows: Bool
  init(failingAt: TransactionStage? = nil, nilConfig: Bool = false, enableThrows: Bool = false) {
    self.failingAt = failingAt
    self.nilConfig = nilConfig
    self.enableThrows = enableThrows
  }

  var cancelCount: Int { operations.filter { $0 == "cancel" }.count }
  var functions: CoreGraphicsDisplayTransactionFunctions {
    CoreGraphicsDisplayTransactionFunctions(
      begin: { config in
        self.operations.append("begin")
        if self.failingAt == .begin { return self.failingAt!.error }
        if !self.nilConfig { config.pointee = OpaquePointer(bitPattern: 1) }
        return .success
      },
      enable: { _, id, enabled in
        self.operations.append("enable:\(id):\(enabled)")
        if self.enableThrows { throw DisplayControlError.unsupportedAPI("CGSConfigureDisplayEnabled") }
        return self.failingAt == .enable ? self.failingAt!.error : .success
      },
      complete: { _, _ in
        self.operations.append("complete")
        return self.failingAt == .complete ? self.failingAt!.error : .success
      },
      cancel: { _ in
        self.operations.append("cancel")
        return .success
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
