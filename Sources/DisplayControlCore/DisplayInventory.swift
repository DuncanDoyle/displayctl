import AppKit
import ColorSync
import CoreGraphics
import Foundation

public protocol DisplaySnapshotProviding: Sendable {
  func snapshot() throws -> [Display]
}

struct DisplayMetadata: Sendable {
  let uuid: UUID
  let isBuiltIn: Bool
  let isActive: Bool
  let isMain: Bool
  let vendorNumber: UInt32
  let modelNumber: UInt32
  let localizedName: String?
}

public struct DisplayInventory: DisplaySnapshotProviding {
  private let candidateDetector: any DDCCandidateDetecting
  private let sampleOnlineIDs: @Sendable () throws -> [UInt32]
  private let sampleActiveIDs: @Sendable () throws -> [UInt32]

  public init() {
    self.init(
      candidateDetector: ResolverDDCCandidateDetector(resolver: IORegistryDDCServiceResolver()))
  }

  /// Tests inject the online and active ID samples; they default to Core Graphics.
  init(
    candidateDetector: any DDCCandidateDetecting,
    onlineIDs: @escaping @Sendable () throws -> [UInt32] = { try onlineDisplayIDs() },
    activeIDs: @escaping @Sendable () throws -> [UInt32] = { try activeDisplayIDs() }
  ) {
    self.candidateDetector = candidateDetector
    sampleOnlineIDs = onlineIDs
    sampleActiveIDs = activeIDs
  }

  public func snapshot() throws -> [Display] {
    let onlineIDs = try sampleOnlineIDs()
    let activeIDs = try sampleActiveIDs()
    let activeIDSet = Set(activeIDs)
    // An active ID missing from the online sample means the topology changed between the two calls.
    guard activeIDSet.isSubset(of: onlineIDs) else {
      throw DisplayControlError.configurationFailed(
        "Display inventory changed while sampling; retry")
    }
    let localizedNames = Self.localizedNames(for: activeIDSet)

    var metadata: [UInt32: DisplayMetadata] = [:]
    metadata.reserveCapacity(onlineIDs.count)

    for displayID in onlineIDs {
      guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
        throw DisplayControlError.configurationFailed(
          "Unable to create UUID for display \(displayID)"
        )
      }

      let cfUUID = rawUUID.takeRetainedValue()
      let uuidString = CFUUIDCreateString(nil, cfUUID) as String
      guard let uuid = UUID(uuidString: uuidString) else {
        throw DisplayControlError.configurationFailed(
          "Invalid UUID for display \(displayID): \(uuidString)"
        )
      }

      metadata[displayID] = DisplayMetadata(
        uuid: uuid,
        isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
        isActive: CGDisplayIsActive(displayID) != 0,
        isMain: CGDisplayIsMain(displayID) != 0,
        vendorNumber: CGDisplayVendorNumber(displayID),
        modelNumber: CGDisplayModelNumber(displayID),
        localizedName: localizedNames[displayID]
      )
    }

    let displays = try Self.makeDisplays(
      onlineIDs: onlineIDs,
      activeIDs: activeIDs,
      metadata: metadata
    )
    return Self.applyingDDCCapabilities(to: displays, detector: candidateDetector)
  }

  /// The UUID Core Graphics maps `runtimeID` to right now, or nil when it maps none.
  static func uuid(forRuntimeID runtimeID: UInt32) -> UUID? {
    guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(runtimeID) else { return nil }
    return UUID(uuidString: CFUUIDCreateString(nil, rawUUID.takeRetainedValue()) as String)
  }

  static func makeDisplays(
    onlineIDs: [UInt32],
    activeIDs: [UInt32],
    metadata: [UInt32: DisplayMetadata]
  ) throws -> [Display] {
    let activeIDSet = Set(activeIDs)
    let displays = try onlineIDs.map { displayID in
      guard let displayMetadata = metadata[displayID] else {
        throw DisplayControlError.configurationFailed(
          "Missing metadata for online display \(displayID)"
        )
      }

      let isActive = activeIDSet.contains(displayID) && displayMetadata.isActive
      let kind: DisplayKind = displayMetadata.isBuiltIn ? .internal : .external
      let fallbackName =
        displayMetadata.isBuiltIn
        ? "Built-in Display"
        : "External Display \(displayMetadata.vendorNumber):\(displayMetadata.modelNumber)"

      return Display(
        uuid: displayMetadata.uuid,
        runtimeID: displayID,
        name: isActive ? displayMetadata.localizedName ?? fallbackName : fallbackName,
        kind: kind,
        isOnline: true,
        isActive: isActive,
        isMain: isActive && displayMetadata.isMain,
        ddcCapability: .unknown
      )
    }

    return displays.sorted { lhs, rhs in
      if lhs.kind != rhs.kind {
        return lhs.kind == .internal
      }
      return lhs.uuid.uuidString < rhs.uuid.uuidString
    }
  }

  static func applyingDDCCapabilities(
    to displays: [Display],
    detector: any DDCCandidateDetecting
  ) -> [Display] {
    displays.map { display in
      guard display.kind == .external else { return display }
      return Display(
        uuid: display.uuid,
        runtimeID: display.runtimeID,
        name: display.name,
        kind: display.kind,
        isOnline: display.isOnline,
        isActive: display.isActive,
        isMain: display.isMain,
        ddcCapability: detector.capability(for: display)
      )
    }
  }

  static func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
    try queryDisplayIDs(
      apiName: "CGGetOnlineDisplayList",
      listCall: CGGetOnlineDisplayList
    )
  }

  static func activeDisplayIDs() throws -> [CGDirectDisplayID] {
    try queryDisplayIDs(
      apiName: "CGGetActiveDisplayList",
      listCall: CGGetActiveDisplayList
    )
  }

  typealias DisplayListCall = (
    UInt32,
    UnsafeMutablePointer<CGDirectDisplayID>?,
    UnsafeMutablePointer<UInt32>?
  ) -> CGError

  static func queryDisplayIDs(
    apiName: String,
    maxAttempts: Int = 3,
    listCall: DisplayListCall
  ) throws -> [CGDirectDisplayID] {
    for _ in 0..<maxAttempts {
      var capacity: UInt32 = 0
      let countError = listCall(0, nil, &capacity)
      guard countError == .success else {
        throw DisplayControlError.configurationFailed(
          "\(apiName) count failed with error \(countError.rawValue)"
        )
      }

      var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
      var returnedCount = capacity
      let valuesError = displayIDs.withUnsafeMutableBufferPointer { buffer in
        listCall(capacity, buffer.baseAddress, &returnedCount)
      }
      guard valuesError == .success else {
        throw DisplayControlError.configurationFailed(
          "\(apiName) values failed with error \(valuesError.rawValue)"
        )
      }

      var verifiedCount: UInt32 = 0
      let verificationError = listCall(0, nil, &verifiedCount)
      guard verificationError == .success else {
        throw DisplayControlError.configurationFailed(
          "\(apiName) verification count failed with error \(verificationError.rawValue)"
        )
      }

      guard returnedCount <= capacity, returnedCount == verifiedCount else {
        continue
      }

      return Array(displayIDs.prefix(Int(returnedCount)))
    }

    throw DisplayControlError.configurationFailed(
      "\(apiName) display list was unstable after \(maxAttempts) attempts"
    )
  }

  private static func localizedNames(for activeIDs: Set<UInt32>) -> [UInt32: String] {
    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    return NSScreen.screens.reduce(into: [:]) { result, screen in
      guard
        let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber,
        activeIDs.contains(screenNumber.uint32Value)
      else {
        return
      }

      result[screenNumber.uint32Value] = screen.localizedName
    }
  }
}
