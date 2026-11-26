import Foundation
import XCTest

@testable import DisplayControlCore
@testable import DisplayMenuKit

/// Real directory and real dispatch source: the one place these tests wait on an OS event.
@MainActor
final class LedgerDirectoryWatcherTests: XCTestCase {
  /// Reads the ledger file the way the app does; snapshots and switches are not used.
  private struct FileLedgerOperations: DisplayOperating {
    let ledger: FileDisabledDisplayLedger
    func snapshot() async throws -> [Display] { [] }
    func disabledDisplays() async throws -> [DisabledDisplayEntry] { try ledger.load() }
    func bootSession() async throws -> String { thisBoot }
    func connect(_ uuid: UUID) async throws -> Display { throw DisplayControlError.lockTimeout }
    func disconnect(_ uuid: UUID) async throws -> Display { throw DisplayControlError.lockTimeout }
  }

  /// Fulfils the expectation that is current when the gate changes.
  private final class Changes {
    var values: [Bool] = []
    var expectation: XCTestExpectation?
  }

  private var directory: URL!
  private var ledger: FileDisabledDisplayLedger!
  private var changes: Changes!
  private var gate: PeriodicCheckGate!
  private var watcher: LedgerDirectoryWatcher!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ledger-watch-\(UUID().uuidString)", isDirectory: true)
    ledger = FileDisabledDisplayLedger(url: DisplayControlState.ledgerURL(in: directory))
    try ledger.save([])
    let changes = Changes()
    self.changes = changes
    let gate = PeriodicCheckGate(operations: FileLedgerOperations(ledger: ledger)) {
      changes.values.append($0)
      changes.expectation?.fulfill()
      changes.expectation = nil
    }
    self.gate = gate
    watcher = LedgerDirectoryWatcher(directory: directory) { Task { await gate.reload() } }
    await gate.reload()
  }

  override func tearDown() async throws {
    watcher.stop()
    try? FileManager.default.removeItem(at: directory)
  }

  /// Saves through the production atomic path and waits for the gate to change.
  private func save(_ entries: [DisabledDisplayEntry]) async throws {
    let expectation = expectation(description: "gate changed")
    changes.expectation = expectation
    try ledger.save(entries)
    await fulfillment(of: [expectation], timeout: 5)
  }

  func testCLIWritesStartAndStopTheCheck() async throws {
    XCTAssertFalse(gate.isRunning)
    XCTAssertTrue(watcher.restart())

    try await save([entry(builtInID, "Built-in Retina Display")])
    XCTAssertTrue(gate.isRunning)

    try await save([])
    XCTAssertFalse(gate.isRunning)
    XCTAssertEqual(changes.values, [true, false])
  }

  func testRestartRecoversAfterTheDirectoryIsDeletedAndRecreated() async throws {
    XCTAssertTrue(watcher.restart())
    try FileManager.default.removeItem(at: directory)
    XCTAssertFalse(watcher.restart())

    try ledger.save([])
    XCTAssertTrue(watcher.restart())

    try await save([entry(builtInID, "Built-in Retina Display")])
    XCTAssertTrue(gate.isRunning)
    XCTAssertEqual(changes.values, [true])
  }
}
