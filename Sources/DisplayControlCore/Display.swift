import Foundation

public enum DisplayControlCoreVersion {
  public static let current = "0.1.0"
}

public enum DisplayKind: String, Codable, Sendable {
  case `internal`
  case external
}

public enum DDCCapability: String, Codable, Sendable {
  case candidate
  case unsupported
  case unknown
}

public struct Display: Codable, Equatable, Sendable {
  public let uuid: UUID
  public let runtimeID: UInt32
  public let name: String
  public let kind: DisplayKind
  public let isOnline: Bool
  public let isActive: Bool
  public let isMain: Bool
  public let ddcCapability: DDCCapability
  /// The stand-in macOS adds when no real display is left (D-012); it is never usable.
  /// Not encoded: `list --json` omits placeholders, so the field would always read false.
  public private(set) var isPlaceholder = false

  /// Online and active, and not the macOS placeholder.
  public var isUsableActive: Bool { isOnline && isActive && !isPlaceholder }

  private enum CodingKeys: String, CodingKey {
    case uuid, runtimeID, name, kind, isOnline, isActive, isMain, ddcCapability
  }

  public init(
    uuid: UUID,
    runtimeID: UInt32,
    name: String,
    kind: DisplayKind,
    isOnline: Bool,
    isActive: Bool,
    isMain: Bool,
    ddcCapability: DDCCapability,
    isPlaceholder: Bool = false
  ) {
    self.uuid = uuid
    self.runtimeID = runtimeID
    self.name = name
    self.kind = kind
    self.isOnline = isOnline
    self.isActive = isActive
    self.isMain = isMain
    self.ddcCapability = ddcCapability
    self.isPlaceholder = isPlaceholder
  }
}
