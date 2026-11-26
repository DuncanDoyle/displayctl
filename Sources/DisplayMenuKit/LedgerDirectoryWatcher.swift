import Foundation

/// Watches the ledger's directory: the CLI replaces the ledger atomically, so the directory, not
/// the file, sees each write. A deleted or replaced directory is created again and reopened.
@MainActor
public final class LedgerDirectoryWatcher {
  private let directory: URL
  private let onChange: @MainActor () -> Void
  private var source: (any DispatchSourceFileSystemObject)?

  /// `onChange` runs on the main actor after every change seen in the directory.
  public init(directory: URL, onChange: @escaping @MainActor () -> Void) {
    self.directory = directory
    self.onChange = onChange
  }

  /// Creates the directory if missing and opens the watch on it; false if that fails.
  @discardableResult
  public func restart() -> Bool {
    stop()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { return false }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
    source.setEventHandler { [weak self, weak source] in
      MainActor.assumeIsolated {
        guard let self, let source else { return }
        // The descriptor follows the old directory, so watch a new one on the same path.
        if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) { self.restart() }
        self.onChange()
      }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    self.source = source
    return true
  }

  /// Cancels the watch until the next `restart()`.
  public func stop() {
    source?.cancel()
    source = nil
  }
}
