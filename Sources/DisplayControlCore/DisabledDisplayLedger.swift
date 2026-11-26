import Darwin
import Foundation

/// A display that `displayctl` disabled, recorded so it can be found again after macOS drops it
/// from the online display list.
public struct DisabledDisplayEntry: Codable, Equatable, Sendable {
  /// The display's persistent UUID.
  public let uuid: UUID
  /// The runtime display ID the display had when it was disabled.
  public let runtimeID: UInt32
  /// The display name at the time it was disabled.
  public let name: String
  /// Whether the display was internal or external.
  public let kind: DisplayKind
  /// The `kern.bootsessionuuid` of the boot that disabled the display.
  public let bootSession: String

  /// Creates a ledger entry.
  public init(uuid: UUID, runtimeID: UInt32, name: String, kind: DisplayKind, bootSession: String) {
    self.uuid = uuid
    self.runtimeID = runtimeID
    self.name = name
    self.kind = kind
    self.bootSession = bootSession
  }

  /// The entry as an offline, inactive display, used to report outcomes for it.
  var placeholder: Display {
    Display(
      uuid: uuid, runtimeID: runtimeID, name: name, kind: kind, isOnline: false,
      isActive: false, isMain: false, ddcCapability: .unknown)
  }
}

protocol DisabledDisplayLedger: Sendable {
  func load() throws -> [DisabledDisplayEntry]
  func save(_ entries: [DisabledDisplayEntry]) throws
}

/// The per-user directory that holds the ledger and the display operation lock.
public enum DisplayControlState {
  /// `~/Library/Application Support/displayctl/`.
  public static var defaultDirectory: URL {
    URL.applicationSupportDirectory.appendingPathComponent("displayctl", isDirectory: true)
  }

  static func ledgerURL(in directory: URL) -> URL {
    directory.appendingPathComponent("disabled-displays.json")
  }

  static func lockURL(in directory: URL) -> URL {
    directory.appendingPathComponent("operation.lock")
  }
}

struct FileDisabledDisplayLedger: DisabledDisplayLedger {
  let url: URL

  func load() throws -> [DisabledDisplayEntry] {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      throw ledgerFailure("read", error)
    }
    do {
      return try JSONDecoder().decode([DisabledDisplayEntry].self, from: data)
    } catch {
      throw ledgerFailure("decode", error)
    }
  }

  func save(_ entries: [DisabledDisplayEntry]) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(entries).write(to: url, options: .atomic)
    } catch {
      throw ledgerFailure("write", error)
    }
  }

  private func ledgerFailure(_ action: String, _ error: Error) -> DisplayControlError {
    .configurationFailed("Unable to \(action) display ledger at \(url.path): \(error)")
  }
}

public enum BootSession {
  /// Reads `kern.bootsessionuuid`, which changes on every boot and ignores clock changes.
  public static func current() throws -> String {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
      throw failure()
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
      throw failure()
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let value = String(decoding: bytes, as: UTF8.self)
    guard !value.isEmpty else {
      throw DisplayControlError.configurationFailed("sysctl kern.bootsessionuuid returned no value")
    }
    return value
  }

  private static func failure() -> DisplayControlError {
    let code = errno
    return .configurationFailed(
      "sysctl kern.bootsessionuuid failed with errno \(code): " + String(cString: strerror(code)))
  }
}
