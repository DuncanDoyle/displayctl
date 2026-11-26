import Foundation

/// Runs blocking work on one serial DispatchQueue and resumes the caller with the result.
public final class BlockingExecutor: Sendable {
  private let queue: DispatchQueue

  public init(label: String = "displayctl.blocking") {
    queue = DispatchQueue(label: label)
  }

  public func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try work() }) }
    }
  }
}
