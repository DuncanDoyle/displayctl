import Foundation
import XCTest
@testable import DisplayControlCore

final class DisplayInventoryTests: XCTestCase {
    private let internalUUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let externalUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testMergesOnlineAndActiveState() throws {
        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [1, 2],
            activeIDs: [2],
            metadata: metadata()
        )

        XCTAssertEqual(result.map(\.runtimeID), [1, 2])
        XCTAssertEqual(result.first { $0.runtimeID == 1 }?.isOnline, true)
        XCTAssertEqual(result.first { $0.runtimeID == 1 }?.isActive, false)
        XCTAssertEqual(result.first { $0.runtimeID == 2 }?.isOnline, true)
        XCTAssertEqual(result.first { $0.runtimeID == 2 }?.isActive, true)
    }

    func testClassifiesBuiltInAndExternalDisplays() throws {
        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [1, 2],
            activeIDs: [1, 2],
            metadata: metadata()
        )

        XCTAssertEqual(result.first { $0.runtimeID == 1 }?.kind, .internal)
        XCTAssertEqual(result.first { $0.runtimeID == 2 }?.kind, .external)
    }

    func testPropagatesStableUUIDAndMainDisplayState() throws {
        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [1, 2],
            activeIDs: [1, 2],
            metadata: metadata()
        )

        XCTAssertEqual(result.first { $0.runtimeID == 1 }?.uuid, internalUUID)
        XCTAssertEqual(result.first { $0.runtimeID == 1 }?.isMain, true)
        XCTAssertEqual(result.first { $0.runtimeID == 2 }?.uuid, externalUUID)
        XCTAssertEqual(result.first { $0.runtimeID == 2 }?.isMain, false)
    }

    func testOnlineButInactiveDisplayRemainsInSnapshot() throws {
        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [1, 2],
            activeIDs: [1],
            metadata: metadata()
        )

        XCTAssertEqual(result.first { $0.runtimeID == 2 }?.isActive, false)
    }

    func testMetadataInactiveOverridesActiveListMembership() throws {
        var displayMetadata = metadata()
        displayMetadata[1] = DisplayMetadata(
            uuid: internalUUID,
            isBuiltIn: true,
            isActive: false,
            isMain: true,
            vendorNumber: 0,
            modelNumber: 0,
            localizedName: "Internal Panel"
        )

        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [1],
            activeIDs: [1],
            metadata: displayMetadata
        )

        XCTAssertEqual(result.first?.isActive, false)
    }

    func testUsesFallbackNamesWhenLocalizedNamesAreUnavailable() throws {
        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [1, 2],
            activeIDs: [1, 2],
            metadata: metadata(localizedNames: [:])
        )

        XCTAssertEqual(result.first { $0.runtimeID == 1 }?.name, "Built-in Display")
        XCTAssertEqual(result.first { $0.runtimeID == 2 }?.name, "External Display 610:4660")
    }

    func testUsesLocalizedNameOnlyForActiveDisplay() throws {
        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [1, 2],
            activeIDs: [1],
            metadata: metadata(localizedNames: [1: "Internal Panel", 2: "Inactive Screen"])
        )

        XCTAssertEqual(result.first { $0.runtimeID == 1 }?.name, "Internal Panel")
        XCTAssertEqual(result.first { $0.runtimeID == 2 }?.name, "External Display 610:4660")
    }

    func testSortsInternalFirstThenByCanonicalUUID() throws {
        let lowerExternalUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [2, 3, 1],
            activeIDs: [1, 2, 3],
            metadata: [
                1: DisplayMetadata(
                    uuid: internalUUID,
                    isBuiltIn: true,
                    isActive: true,
                    isMain: true,
                    vendorNumber: 0,
                    modelNumber: 0,
                    localizedName: nil
                ),
                2: DisplayMetadata(
                    uuid: externalUUID,
                    isBuiltIn: false,
                    isActive: true,
                    isMain: false,
                    vendorNumber: 610,
                    modelNumber: 0x1234,
                    localizedName: nil
                ),
                3: DisplayMetadata(
                    uuid: lowerExternalUUID,
                    isBuiltIn: false,
                    isActive: true,
                    isMain: false,
                    vendorNumber: 1,
                    modelNumber: 2,
                    localizedName: nil
                ),
            ]
        )

        XCTAssertEqual(result.map(\.uuid), [internalUUID, lowerExternalUUID, externalUUID])
    }

    func testDefaultsDDCCapabilityToUnknown() throws {
        let result = try DisplayInventory.makeDisplays(
            onlineIDs: [1, 2],
            activeIDs: [1, 2],
            metadata: metadata()
        )

        XCTAssertTrue(result.allSatisfy { $0.ddcCapability == .unknown })
    }

    private func metadata(localizedNames: [UInt32: String] = [1: "Internal Panel", 2: "Studio Display"])
        -> [UInt32: DisplayMetadata]
    {
        [
            1: DisplayMetadata(
                uuid: internalUUID,
                isBuiltIn: true,
                isActive: true,
                isMain: true,
                vendorNumber: 0,
                modelNumber: 0,
                localizedName: localizedNames[1]
            ),
            2: DisplayMetadata(
                uuid: externalUUID,
                isBuiltIn: false,
                isActive: true,
                isMain: false,
                vendorNumber: 610,
                modelNumber: 0x1234,
                localizedName: localizedNames[2]
            ),
        ]
    }
}
