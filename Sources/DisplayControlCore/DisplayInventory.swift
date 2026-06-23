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
    public init() {}

    public func snapshot() throws -> [Display] {
        let onlineIDs = try Self.onlineDisplayIDs()
        let activeIDs = try Self.activeDisplayIDs()
        let activeIDSet = Set(activeIDs)
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

        return try Self.makeDisplays(
            onlineIDs: onlineIDs,
            activeIDs: activeIDs,
            metadata: metadata
        )
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
            let fallbackName = displayMetadata.isBuiltIn
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

    private static func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        try queryDisplayIDs(
            apiName: "CGGetOnlineDisplayList",
            listCall: CGGetOnlineDisplayList
        )
    }

    private static func activeDisplayIDs() throws -> [CGDirectDisplayID] {
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
