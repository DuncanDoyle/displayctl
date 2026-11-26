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
  var isPlaceholder = false
}

public struct DisplayInventory: DisplaySnapshotProviding {
  private let candidateDetector: any DDCCandidateDetecting
  private let sampleOnlineIDs: @Sendable () throws -> [UInt32]
  private let sampleActiveIDs: @Sendable () throws -> [UInt32]
  private let retryDelayMicroseconds: useconds_t
  private var namesOnMainThread = false

  public init() {
    self.init(
      candidateDetector: ResolverDDCCandidateDetector(resolver: IORegistryDDCServiceResolver()))
  }

  /// For an app whose main thread runs AppKit: display names are read there. The CLI must not
  /// use this: macOS then waits about 10 s for the CLI to handle each display change.
  public init(namesOnMainThread: Bool) {
    self.init()
    self.namesOnMainThread = namesOnMainThread
  }

  /// Tests inject the online and active ID samples; they default to Core Graphics.
  init(
    candidateDetector: any DDCCandidateDetecting,
    onlineIDs: @escaping @Sendable () throws -> [UInt32] = { try onlineDisplayIDs() },
    activeIDs: @escaping @Sendable () throws -> [UInt32] = { try activeDisplayIDs() },
    retryDelayMicroseconds: useconds_t = 20_000
  ) {
    self.candidateDetector = candidateDetector
    sampleOnlineIDs = onlineIDs
    sampleActiveIDs = activeIDs
    self.retryDelayMicroseconds = retryDelayMicroseconds
  }

  /// Samples up to 3 times in total, 20 ms apart, while the display setup changes; then throws `inventoryChanged`.
  public func snapshot() throws -> [Display] {
    for _ in 1..<Self.maximumSampleAttempts {
      do {
        return try sampleOnce()
      } catch DisplayControlError.inventoryChanged {
        usleep(retryDelayMicroseconds)
      }
    }
    return try sampleOnce()
  }

  private static let maximumSampleAttempts = 3

  private func sampleOnce() throws -> [Display] {
    let onlineIDs = try sampleOnlineIDs()
    let activeIDs = try sampleActiveIDs()
    let activeIDSet = Set(activeIDs)
    // An active ID missing from the online sample means the topology changed between the two calls.
    guard activeIDSet.isSubset(of: onlineIDs) else {
      throw DisplayControlError.inventoryChanged
    }
    let localizedNames = localizedNames(for: activeIDSet)

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
        localizedName: localizedNames[displayID],
        isPlaceholder: Self.isPlaceholder(displayID)
      )
    }

    let displays = try Self.makeDisplays(
      onlineIDs: onlineIDs,
      activeIDs: activeIDs,
      metadata: metadata
    )
    return Self.applyingDDCCapabilities(to: displays, detector: candidateDetector)
  }

  /// The macOS placeholder signature seen on macOS 27.0.1 (D-012): vendor 'unkn', model 'virt',
  /// 0×0 mm and no current mode. A heuristic: all four must hold.
  static func isPlaceholder(
    vendorNumber: UInt32, modelNumber: UInt32, sizeMillimeters: CGSize, hasCurrentMode: Bool
  ) -> Bool {
    vendorNumber == placeholderVendor && modelNumber == placeholderModel
      && sizeMillimeters == .zero && !hasCurrentMode
  }

  private static let placeholderVendor: UInt32 = 0x756E_6B6E  // 'unkn'
  private static let placeholderModel: UInt32 = 0x7669_7274  // 'virt'

  /// Reads the placeholder signals from Core Graphics; size and mode only when the IDs match.
  static func isPlaceholder(_ displayID: CGDirectDisplayID) -> Bool {
    guard CGDisplayVendorNumber(displayID) == placeholderVendor,
      CGDisplayModelNumber(displayID) == placeholderModel
    else { return false }
    return isPlaceholder(
      vendorNumber: placeholderVendor, modelNumber: placeholderModel,
      sizeMillimeters: CGDisplayScreenSize(displayID),
      hasCurrentMode: CGDisplayCopyDisplayMode(displayID) != nil)
  }

  /// Active displays minus placeholders; cheap enough for the safety net's re-arm check.
  static func usableActiveCount(activeIDs: [UInt32], isPlaceholder: (UInt32) -> Bool) -> Int {
    activeIDs.filter { !isPlaceholder($0) }.count
  }

  /// The live usable active count, without a full inventory; an error counts as zero.
  public static func usableActiveDisplayCount() -> Int {
    guard let activeIDs = try? activeDisplayIDs() else { return 0 }
    return usableActiveCount(activeIDs: activeIDs, isPlaceholder: isPlaceholder(_:))
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

      // The active list and CGDisplayIsActive are separate calls; disagreement means the topology moved.
      let isActive = activeIDSet.contains(displayID)
      guard isActive == displayMetadata.isActive else {
        throw DisplayControlError.inventoryChanged
      }
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
        ddcCapability: .unknown,
        isPlaceholder: displayMetadata.isPlaceholder
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
        // The placeholder has no DDC bus, so skip the registry lookup.
        ddcCapability: display.isPlaceholder ? .unsupported : detector.capability(for: display),
        isPlaceholder: display.isPlaceholder
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

    // The list kept changing between its count and values reads: same as an inconsistent sample.
    throw DisplayControlError.inventoryChanged
  }

  /// With `namesOnMainThread`, a caller on another thread waits for the main thread to read NSScreen.
  private func localizedNames(for activeIDs: Set<UInt32>) -> [UInt32: String] {
    guard !namesOnMainThread || Thread.isMainThread else {
      return DispatchQueue.main.sync { Self.screenNames(for: activeIDs) }
    }
    return Self.screenNames(for: activeIDs)
  }

  private static func screenNames(for activeIDs: Set<UInt32>) -> [UInt32: String] {
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
