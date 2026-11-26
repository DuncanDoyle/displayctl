import Foundation
import Synchronization
import XCTest

@testable import DisplayMenuKit

private final class InFlight: Sendable {
  let current = Atomic<Int>(0)
  let highest = Atomic<Int>(0)
}

private struct WorkFailed: Error {}

final class BlockingExecutorTests: XCTestCase {
  @MainActor
  func testRunsWorkOffMainThread() async throws {
    let executor = BlockingExecutor()

    let onMain = try await executor.run { Thread.isMainThread }

    XCTAssertFalse(onMain)
  }

  func testRunsSerially() async throws {
    let executor = BlockingExecutor()
    let inFlight = InFlight()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<20 {
        group.addTask {
          try await executor.run {
            let now = inFlight.current.add(1, ordering: .sequentiallyConsistent).newValue
            inFlight.highest.max(now, ordering: .sequentiallyConsistent)
            // Holds the queue briefly so overlapping calls would be caught.
            usleep(1_000)
            inFlight.current.subtract(1, ordering: .sequentiallyConsistent)
          }
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(inFlight.highest.load(ordering: .sequentiallyConsistent), 1)
  }

  func testPropagatesThrow() async {
    let executor = BlockingExecutor()

    do {
      _ = try await executor.run { () throws -> Int in throw WorkFailed() }
      XCTFail("expected a throw")
    } catch {
      XCTAssertTrue(error is WorkFailed)
    }
  }
}
