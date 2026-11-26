import Foundation

/// One write in flight; newest pending value written after it; last submitted value always written;
/// after invalidate(), pending values are discarded and late results ignored.
/// Main-actor isolated so slider values arrive in order through synchronous submit().
@MainActor public final class BrightnessCoalescer {
  private let write: @Sendable (Int) async throws -> Void
  private let onError: @Sendable (String?) -> Void
  private var task: Task<Void, Never>?
  private var pending: Int?
  /// The value of the last write that started; nil after a failure so the next value is retried.
  private var lastWritten: Int?
  private var isInvalidated = false

  public init(
    write: @escaping @Sendable (Int) async throws -> Void,
    onError: @escaping @Sendable (String?) -> Void
  ) {
    self.write = write
    self.onError = onError
  }

  public func submit(_ percent: Int) {
    guard !isInvalidated else { return }
    if task == nil {
      start(percent)
    } else {
      pending = percent
    }
  }

  /// True while a write is in flight or a value waits behind it.
  var isWriting: Bool { task != nil }

  public func invalidate() {
    isInvalidated = true
    pending = nil
  }

  /// Waits until no write is in flight.
  func idle() async {
    while let current = task { await current.value }
  }

  private func start(_ percent: Int) {
    lastWritten = percent
    let write = write
    task = Task {
      var failure: String?
      do { try await write(percent) } catch { failure = ErrorText.short(error) }
      finished(failure)
    }
  }

  private func finished(_ failure: String?) {
    task = nil
    guard !isInvalidated else { return }
    if failure != nil { lastWritten = nil }
    onError(failure)
    if let next = pending {
      pending = nil
      if next != lastWritten { start(next) }
    }
  }
}
