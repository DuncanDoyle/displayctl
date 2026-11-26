import DisplayControlCore
import Foundation
import XCTest

@testable import DisplayMenuKit

final class PanelRowsTests: XCTestCase {
  private func make(
    _ displays: [Display], ledger: [DisabledDisplayEntry] = [], busy: UUID? = nil,
    errors: [UUID: String] = [:]
  ) -> [DisplayRow] {
    PanelRows.make(
      displays: displays, ledger: ledger, currentBoot: thisBoot, busy: busy, errors: errors)
  }

  func testBuiltInFirstThenExternalsByName() {
    let rows = make([display(lgID, "LG UltraFine"), dell(), builtIn()])

    XCTAssertEqual(rows.map(\.name), ["Built-in Retina Display", "DELL U2720Q", "LG UltraFine"])
  }

  func testLedgerOnlyDisplayIsAnOffRow() {
    let rows = make([builtIn()], ledger: [entry(dellID, "DELL U2720Q")])

    let row = rows.first { $0.id == dellID }
    XCTAssertEqual(row?.name, "DELL U2720Q")
    XCTAssertEqual(row?.isOn, false)
    XCTAssertEqual(row?.isSwitchEnabled, true)
    XCTAssertEqual(row?.showsBrightness, false)
  }

  func testEarlierBootLedgerEntryHasNoRow() {
    let rows = make([builtIn()], ledger: [entry(dellID, "DELL U2720Q", boot: "boot-earlier")])

    XCTAssertEqual(rows.map(\.id), [builtInID])
  }

  func testOnlineDisplayWinsOverItsLedgerEntry() {
    let rows = make([builtIn(), dell()], ledger: [entry(dellID, "Old name")])

    XCTAssertEqual(rows.map(\.id), [builtInID, dellID])
    XCTAssertEqual(rows[1].name, "DELL U2720Q")
    XCTAssertTrue(rows[1].isOn)
  }

  func testOnlyActiveDisplaySwitchDisabledWithCaption() {
    let rows = make([builtIn(), dell(active: false)])

    XCTAssertFalse(rows[0].isSwitchEnabled)
    XCTAssertEqual(rows[0].caption, "Only active display")
    XCTAssertTrue(rows[1].isSwitchEnabled)
    XCTAssertNil(rows[1].caption)

    let both = make([builtIn(), dell()])
    XCTAssertTrue(both.allSatisfy { $0.isSwitchEnabled && $0.caption == nil })
  }

  func testPlaceholderHasNoRowAndNeverCountsAsActive() {
    let placeholder = Display(
      uuid: lgID, runtimeID: 12, name: "External Display", kind: .external, isOnline: true,
      isActive: true, isMain: true, ddcCapability: .unknown, isPlaceholder: true)

    let rows = make([builtIn(active: false), dell(), placeholder])

    XCTAssertEqual(rows.map(\.id), [builtInID, dellID])
    XCTAssertFalse(rows[1].isSwitchEnabled)
    XCTAssertEqual(rows[1].caption, "Only active display")
    XCTAssertEqual(make([placeholder]), [])
  }

  func testLedgerEntryWithTheOnlinePlaceholderUUIDHasNoRow() {
    let placeholder = Display(
      uuid: lgID, runtimeID: 12, name: "External Display", kind: .external, isOnline: true,
      isActive: true, isMain: true, ddcCapability: .unknown, isPlaceholder: true)

    let rows = make([builtIn(), placeholder], ledger: [entry(lgID, "LG UltraFine")])

    XCTAssertEqual(rows.map(\.id), [builtInID])
  }

  func testAllSwitchesDisabledWhileBusy() {
    let rows = make(
      [builtIn(), dell()], ledger: [entry(lgID, "LG UltraFine")], busy: dellID,
      errors: [builtInID: "failed"])

    XCTAssertTrue(rows.allSatisfy { !$0.isSwitchEnabled })
    XCTAssertEqual(rows.filter(\.isBusy).map(\.id), [dellID])
    XCTAssertEqual(rows[0].error, "failed")
  }

  func testShowsBrightnessOnlyForActiveExternalNotUnsupported() {
    let rows = make([
      builtIn(),
      dell(),
      display(lgID, "LG UltraFine", active: false),
      display(UUID(), "Projector", ddc: .unsupported),
      display(UUID(), "Samsung", ddc: .unknown),
    ])

    XCTAssertEqual(
      rows.filter(\.showsBrightness).map(\.name), ["DELL U2720Q", "Samsung"])
  }
}
