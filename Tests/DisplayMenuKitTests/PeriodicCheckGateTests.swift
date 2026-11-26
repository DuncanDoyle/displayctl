import DisplayControlCore
import Foundation
import XCTest

@testable import DisplayMenuKit

@MainActor
final class PeriodicCheckGateTests: XCTestCase {
  private final class Changes {
    var values: [Bool] = []
  }

  private func gate(_ operations: FakeOperations, _ changes: Changes) -> PeriodicCheckGate {
    PeriodicCheckGate(operations: operations) { changes.values.append($0) }
  }

  func testLedgerWrittenAndEmptiedByTheCLIStartsAndStopsTheCheck() async {
    let operations = FakeOperations([builtIn(), dell()])
    let changes = Changes()
    let gate = gate(operations, changes)
    await gate.reload()
    XCTAssertFalse(gate.isRunning)

    operations.setLedger(.success([entry(builtInID, "Built-in Retina Display")]))
    await gate.reload()
    await gate.reload()
    XCTAssertTrue(gate.isRunning)

    operations.setLedger(.success([]))
    await gate.reload()

    XCTAssertFalse(gate.isRunning)
    XCTAssertEqual(changes.values, [true, false])
  }

  func testEarlierBootEntryDoesNotStartTheCheck() async {
    let operations = FakeOperations(
      [dell()], ledger: .success([entry(builtInID, "Built-in", boot: "boot-earlier")]))
    let changes = Changes()
    let gate = gate(operations, changes)

    await gate.reload()

    XCTAssertFalse(gate.isRunning)
    XCTAssertEqual(changes.values, [])
  }

  func testUnreadableLedgerTurnsTheCheckOff() async {
    let operations = FakeOperations([dell()], ledger: .success([entry(builtInID, "Built-in")]))
    let changes = Changes()
    let gate = gate(operations, changes)
    await gate.reload()
    XCTAssertTrue(gate.isRunning)

    operations.setLedger(.failure(.configurationFailed("Unable to decode display ledger")))
    await gate.reload()

    XCTAssertFalse(gate.isRunning)
    XCTAssertEqual(changes.values, [true, false])
  }

  func testUnreadableLedgerAtLaunchLeavesTheCheckOff() async {
    let operations = FakeOperations(
      [dell()], ledger: .failure(.configurationFailed("Unable to decode display ledger")))
    let changes = Changes()
    let gate = gate(operations, changes)

    await gate.reload()

    XCTAssertFalse(gate.isRunning)
    XCTAssertEqual(changes.values, [])
  }
}
