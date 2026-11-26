import DisplayControlCore
import Foundation
import XCTest

@testable import DisplayMenuKit

@MainActor
final class PanelModelTests: XCTestCase {
  private func model(_ operations: FakeOperations) -> PanelModel {
    PanelModel(operations: operations, brightness: UnusedBrightness())
  }

  private func row(_ model: PanelModel, _ id: UUID) -> DisplayRow? {
    model.rows.first { $0.id == id }
  }

  func testRefreshBuildsRows() async {
    let operations = FakeOperations(
      [dell(), builtIn()], ledger: .success([entry(lgID, "LG UltraFine")]))
    let model = model(operations)

    await model.refresh()

    XCTAssertEqual(model.rows.map(\.id), [builtInID, dellID, lgID])
    XCTAssertEqual(model.rows.map(\.isOn), [true, true, false])
    XCTAssertNil(model.panelNote)
    XCTAssertFalse(model.isBusy)
  }

  func testTurnOffCallsDisconnectThenRefreshes() async {
    let operations = FakeOperations([builtIn(), dell()])
    operations.addSwitch(SwitchStep(then: [builtIn(), dell(active: false)]))
    let model = model(operations)
    await model.refresh()

    await model.setDisplay(dellID, on: false)

    XCTAssertEqual(operations.calls, ["disconnect \(dellID.uuidString)"])
    XCTAssertEqual(row(model, dellID)?.isOn, false)
    XCTAssertEqual(row(model, builtInID)?.caption, "Only active display")
    XCTAssertFalse(model.isBusy)
  }

  func testLockTimeoutShowsBusyTextAndRealState() async {
    let operations = FakeOperations([builtIn(), dell()])
    operations.addSwitch(SwitchStep(error: .lockTimeout))
    let model = model(operations)
    await model.refresh()

    await model.setDisplay(dellID, on: false)

    XCTAssertEqual(row(model, dellID)?.error, "Busy — another displayctl is running. Try again.")
    XCTAssertEqual(row(model, dellID)?.isOn, true)
    XCTAssertEqual(row(model, dellID)?.isBusy, false)
    XCTAssertFalse(model.isBusy)
  }

  func testErrorClearsOnNextSuccessForThatDisplay() async {
    let operations = FakeOperations([builtIn(), dell()])
    operations.addSwitch(SwitchStep(error: .postconditionFailed("still active")))
    operations.addSwitch(SwitchStep(then: [builtIn(), dell(active: false)]))
    let model = model(operations)
    await model.refresh()

    await model.setDisplay(dellID, on: false)
    XCTAssertEqual(row(model, dellID)?.error, "still active")

    await model.setDisplay(dellID, on: false)
    XCTAssertNil(row(model, dellID)?.error)
    XCTAssertEqual(row(model, dellID)?.isOn, false)
  }

  func testBackgroundRefreshKeepsErrorPanelOpenedClearsIt() async {
    let operations = FakeOperations([builtIn(), dell()])
    operations.addSwitch(SwitchStep(error: .lastActiveDisplay))
    let model = model(operations)
    await model.panelOpened()
    await model.setDisplay(dellID, on: false)

    await model.refresh()
    XCTAssertEqual(row(model, dellID)?.error, "Cannot turn off the only active display")

    model.panelClosed()
    await model.panelOpened()
    XCTAssertNil(row(model, dellID)?.error)
  }

  func testSecondClickWhileBusyIsIgnored() async {
    let gate = Gate()
    let operations = FakeOperations([builtIn(), dell()])
    operations.addSwitch(SwitchStep(gate: gate, then: [builtIn(), dell(active: false)]))
    let model = model(operations)
    await model.refresh()

    let first = Task { await model.setDisplay(dellID, on: false) }
    await gate.arrived()
    XCTAssertTrue(model.isBusy)
    XCTAssertTrue(model.rows.allSatisfy { !$0.isSwitchEnabled })
    await model.setDisplay(builtInID, on: false)
    gate.open()
    await first.value

    XCTAssertEqual(operations.calls, ["disconnect \(dellID.uuidString)"])
    XCTAssertFalse(model.isBusy)
  }

  func testStaleRefreshCannotOverwriteNewerOperation() async {
    let gate = Gate()
    let operations = FakeOperations([builtIn(), dell()])
    operations.addSnapshot(SnapshotStep(gate: gate, result: .success([builtIn(), dell()])))
    operations.addSwitch(SwitchStep(then: [builtIn(), dell(active: false)]))
    let model = model(operations)

    let stale = Task { await model.refresh() }
    await gate.arrived()
    await model.setDisplay(dellID, on: false)
    gate.open()
    await stale.value

    XCTAssertEqual(row(model, dellID)?.isOn, false)
    XCTAssertNil(row(model, dellID)?.error)
    XCTAssertEqual(row(model, builtInID)?.caption, "Only active display")
    XCTAssertFalse(model.isBusy)
  }

  func testNewerRefreshDoesNotDropFailedSwitchError() async {
    let gate = Gate()
    let operations = FakeOperations([builtIn(), dell()])
    let model = model(operations)
    await model.refresh()
    operations.addSwitch(SwitchStep(error: .postconditionFailed("still active")))
    // Holds the switch's follow-up snapshot so a later refresh publishes first.
    operations.addSnapshot(SnapshotStep(gate: gate, result: .success([builtIn(), dell()])))

    let operation = Task { await model.setDisplay(dellID, on: false) }
    await gate.arrived()
    operations.setCurrent([builtIn(), dell(), display(lgID, "LG UltraFine")])
    await model.refresh()
    XCTAssertEqual(row(model, dellID)?.isBusy, true)
    gate.open()
    await operation.value

    XCTAssertEqual(model.rows.map(\.id), [builtInID, dellID, lgID])
    XCTAssertEqual(row(model, dellID)?.error, "still active")
    XCTAssertEqual(row(model, dellID)?.isBusy, false)
    XCTAssertFalse(model.isBusy)
  }

  func testUnreadableLedgerShowsNoteAndOnlineRows() async {
    let operations = FakeOperations(
      [builtIn(), dell()], ledger: .failure(.configurationFailed("bad json")))
    let model = model(operations)

    await model.refresh()

    XCTAssertEqual(model.panelNote, "Saved display list unreadable. See README › Recovery.")
    XCTAssertEqual(model.rows.map(\.id), [builtInID, dellID])
  }

  func testRowDisappearsAfterUnplugDuringOperation() async {
    let gate = Gate()
    let operations = FakeOperations([builtIn(), dell()])
    operations.addSwitch(
      SwitchStep(gate: gate, error: .displayNotFound(dellID.uuidString), then: nil))
    let model = model(operations)
    await model.refresh()

    let operation = Task { await model.setDisplay(dellID, on: false) }
    await gate.arrived()
    operations.setCurrent([builtIn()])
    gate.open()
    await operation.value

    XCTAssertEqual(model.rows.map(\.id), [builtInID])
    XCTAssertFalse(model.isBusy)

    // The dropped row's error does not come back when the display returns.
    operations.setCurrent([builtIn(), dell()])
    await model.refresh()
    XCTAssertNil(row(model, dellID)?.error)
  }
}
