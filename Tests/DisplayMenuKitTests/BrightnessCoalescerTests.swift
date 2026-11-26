import DisplayControlCore
import Foundation
import Synchronization
import XCTest

@testable import DisplayMenuKit

/// Collects `onError` calls; `nil` entries are clears.
private final class ErrorLog: Sendable {
  private let entries = Mutex<[String?]>([])
  var all: [String?] { entries.withLock { $0 } }
  func record(_ message: String?) { entries.withLock { $0.append(message) } }
}

@MainActor
final class BrightnessCoalescerTests: XCTestCase {
  private let fake = FakeBrightness()
  private let errors = ErrorLog()

  private func coalescer() -> BrightnessCoalescer {
    let fake = fake
    let errors = errors
    return BrightnessCoalescer(
      write: { try await fake.set($0, for: dellID) }, onError: { errors.record($0) })
  }

  func testFirstValueWrittenImmediately() async {
    let gate = fake.holdWrite(0)
    let coalescer = coalescer()

    coalescer.submit(10)
    await gate.arrived()

    XCTAssertEqual(fake.writes, [10])
    gate.open()
    await coalescer.idle()
  }

  func testValuesDuringInFlightWriteCollapseToNewest() async {
    let gate = fake.holdWrite(0)
    let coalescer = coalescer()

    coalescer.submit(10)
    await gate.arrived()
    coalescer.submit(20)
    coalescer.submit(25)
    coalescer.submit(30)
    gate.open()
    await coalescer.idle()

    XCTAssertEqual(fake.writes, [10, 30])
  }

  func testSameValueAfterInFlightIsNotRewritten() async {
    let gate = fake.holdWrite(0)
    let coalescer = coalescer()

    coalescer.submit(10)
    await gate.arrived()
    coalescer.submit(20)
    coalescer.submit(10)
    gate.open()
    await coalescer.idle()

    XCTAssertEqual(fake.writes, [10])
  }

  func testFailedWriteReportsErrorAndNextSubmitWrites() async {
    fake.failWrite(0, .ddcTimeout)
    let coalescer = coalescer()

    coalescer.submit(10)
    await coalescer.idle()
    XCTAssertEqual(errors.all, ["DDC operation timed out"])

    coalescer.submit(10)
    await coalescer.idle()
    XCTAssertEqual(fake.writes, [10, 10])
    XCTAssertEqual(errors.all, ["DDC operation timed out", nil])
  }

  func testInvalidateDropsPendingAndIgnoresLateResult() async {
    let gate = fake.holdWrite(0)
    // A failing late result would show up in the error log if it were not ignored.
    fake.failWrite(0, .ddcTimeout)
    let coalescer = coalescer()

    coalescer.submit(10)
    await gate.arrived()
    coalescer.submit(20)
    coalescer.invalidate()
    gate.open()
    await coalescer.idle()
    coalescer.submit(30)
    await coalescer.idle()

    XCTAssertEqual(fake.writes, [10])
    XCTAssertEqual(errors.all, [])
  }
}
