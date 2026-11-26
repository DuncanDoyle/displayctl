import DisplayControlCore
import Foundation
import XCTest

@testable import DisplayMenuKit

@MainActor
final class PanelModelBrightnessTests: XCTestCase {
  private let brightness = FakeBrightness()

  private func model(_ operations: FakeOperations) -> PanelModel {
    PanelModel(operations: operations, brightness: brightness)
  }

  func testOpeningReadsOnlyBrightnessRowsAndNeverWrites() async {
    let operations = FakeOperations([
      builtIn(), dell(), display(lgID, "LG UltraFine", ddc: .unsupported),
    ])
    let model = model(operations)

    await model.panelOpened()

    XCTAssertEqual(brightness.reads, [dellID])
    XCTAssertEqual(brightness.writes, [])
    XCTAssertEqual(
      model.brightness(for: dellID), BrightnessState(percent: 40, sliderValue: 40, error: nil))
    XCTAssertNil(model.brightness(for: builtInID))
    XCTAssertNil(model.brightness(for: lgID))
  }

  func testReadFailureShowsDashAndSliderAtFifty() async {
    brightness.setRead(dellID, .failure(.ddcTimeout))
    let model = model(FakeOperations([builtIn(), dell()]))

    await model.panelOpened()

    XCTAssertEqual(
      model.brightness(for: dellID),
      BrightnessState(percent: nil, sliderValue: 50, error: "DDC operation timed out"))
  }

  func testNewlyEligibleRowIsReadWhileOpen() async {
    let operations = FakeOperations([builtIn(), dell(active: false)])
    let model = model(operations)
    await model.panelOpened()
    XCTAssertEqual(brightness.reads, [])

    operations.setCurrent([builtIn(), dell()])
    await model.refresh()

    XCTAssertEqual(brightness.reads, [dellID])
    XCTAssertEqual(model.brightness(for: dellID)?.percent, 40)
  }

  func testRowEligibleWhileClosedIsReadOnReopen() async {
    let operations = FakeOperations([builtIn(), dell(active: false)])
    let model = model(operations)
    await model.panelOpened()
    model.panelClosed()

    operations.setCurrent([builtIn(), dell()])
    await model.refresh()
    XCTAssertEqual(brightness.reads, [])

    await model.panelOpened()
    XCTAssertEqual(brightness.reads, [dellID])
  }

  func testReleasedValueWinsThroughModel() async {
    let gate = brightness.holdWrite(0)
    let model = model(FakeOperations([builtIn(), dell()]))
    await model.panelOpened()

    model.setBrightness(10, for: dellID)
    await gate.arrived()
    model.setBrightness(20, for: dellID)
    model.setBrightness(30, for: dellID)
    model.setBrightness(45, for: dellID)
    gate.open()
    await model.coalescers[dellID]?.idle()

    XCTAssertEqual(brightness.writes.last, 45)
    XCTAssertEqual(model.brightness(for: dellID)?.sliderValue, 45)
  }

  func testReopenReadDoesNotOverwritePendingSliderValue() async {
    let gate = brightness.holdWrite(0)
    let model = model(FakeOperations([builtIn(), dell()]))
    await model.panelOpened()

    model.setBrightness(10, for: dellID)
    await gate.arrived()
    model.setBrightness(45, for: dellID)
    model.panelClosed()
    // The monitor still reports 10 because the 45 write has not reached it.
    brightness.setRead(dellID, .success(10))
    await model.panelOpened()
    gate.open()
    await model.coalescers[dellID]?.idle()

    XCTAssertEqual(brightness.writes, [10, 45])
    XCTAssertEqual(
      model.brightness(for: dellID), BrightnessState(percent: 45, sliderValue: 45, error: nil))
  }

  func testReopenReadResumingAfterWritesFinishDoesNotOverwriteSlider() async {
    let writeGate = brightness.holdWrite(0)
    let model = model(FakeOperations([builtIn(), dell()]))
    await model.panelOpened()

    model.setBrightness(10, for: dellID)
    await writeGate.arrived()
    model.setBrightness(45, for: dellID)
    model.panelClosed()
    // The reopen read samples 10 before the 45 write reaches the monitor.
    brightness.setRead(dellID, .success(10))
    let readGate = brightness.holdRead(1)
    let reopen = Task { await model.panelOpened() }
    await readGate.arrived()
    writeGate.open()
    await model.coalescers[dellID]?.idle()
    readGate.open()
    await reopen.value

    XCTAssertEqual(brightness.writes, [10, 45])
    XCTAssertEqual(
      model.brightness(for: dellID), BrightnessState(percent: 45, sliderValue: 45, error: nil))
  }

  func testDisplayLeavingInvalidatesPendingWrite() async {
    let gate = brightness.holdWrite(0)
    let operations = FakeOperations([builtIn(), dell()])
    let model = model(operations)
    await model.panelOpened()

    model.setBrightness(10, for: dellID)
    await gate.arrived()
    model.setBrightness(20, for: dellID)
    let coalescer = model.coalescers[dellID]
    XCTAssertNotNil(coalescer)

    operations.setCurrent([builtIn()])
    await model.refresh()
    XCTAssertNil(model.coalescers[dellID])
    XCTAssertNil(model.brightness(for: dellID))

    gate.open()
    await coalescer?.idle()
    XCTAssertEqual(brightness.writes, [10])
  }
}
