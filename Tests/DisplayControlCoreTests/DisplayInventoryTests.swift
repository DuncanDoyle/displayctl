import CoreGraphics
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
      metadata: metadata(inactive: [1])
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
      metadata: metadata(inactive: [2])
    )

    XCTAssertEqual(result.first { $0.runtimeID == 2 }?.isActive, false)
  }

  func testActiveListAndPerDisplayCheckDisagreeingFailsAsInconsistent() {
    // Listed active but CGDisplayIsActive false, then the reverse.
    for (activeIDs, inactive) in [([UInt32(1)], Set<UInt32>([1])), ([], [])] {
      XCTAssertThrowsError(
        try DisplayInventory.makeDisplays(
          onlineIDs: [1],
          activeIDs: activeIDs,
          metadata: metadata(inactive: inactive)
        )
      ) {
        XCTAssertEqual(
          $0 as? DisplayControlError,
          .inventoryChanged)
      }
    }
  }

  func testEmptyOnlineInventoryReturnsNoDisplays() throws {
    XCTAssertEqual(
      try DisplayInventory.makeDisplays(onlineIDs: [], activeIDs: [], metadata: [:]),
      []
    )
  }

  func testMissingMetadataFailsConfiguration() {
    XCTAssertThrowsError(
      try DisplayInventory.makeDisplays(onlineIDs: [7], activeIDs: [], metadata: [:])
    ) {
      XCTAssertEqual(
        $0 as? DisplayControlError,
        .configurationFailed("Missing metadata for online display 7")
      )
    }
  }

  func testDisplayListQueryReturnsStableRead() throws {
    var callCount = 0

    let result = try DisplayInventory.queryDisplayIDs(apiName: "TestDisplayList") {
      maxDisplays, displays, displayCount in
      callCount += 1
      switch callCount {
      case 1:
        displayCount?.pointee = 2
      case 2:
        XCTAssertEqual(maxDisplays, 2)
        displays?[0] = 11
        displays?[1] = 22
        displayCount?.pointee = 2
      case 3:
        displayCount?.pointee = 2
      default:
        XCTFail("Unexpected list query call")
      }
      return .success
    }

    XCTAssertEqual(result, [11, 22])
    XCTAssertEqual(callCount, 3)
  }

  func testDisplayListQueryRetriesGrowthBetweenCountAndValues() throws {
    var callCount = 0

    let result = try DisplayInventory.queryDisplayIDs(apiName: "TestDisplayList") {
      maxDisplays, displays, displayCount in
      callCount += 1
      switch callCount {
      case 1:
        displayCount?.pointee = 1
      case 2:
        XCTAssertEqual(maxDisplays, 1)
        displays?[0] = 11
        // Core Graphics may report only the number that fit in the supplied buffer.
        displayCount?.pointee = 1
      case 3, 4:
        displayCount?.pointee = 2
      case 5:
        XCTAssertEqual(maxDisplays, 2)
        displays?[0] = 11
        displays?[1] = 22
        displayCount?.pointee = 2
      case 6:
        displayCount?.pointee = 2
      default:
        XCTFail("Unexpected list query call")
      }
      return .success
    }

    XCTAssertEqual(result, [11, 22])
    XCTAssertEqual(callCount, 6)
  }

  func testDisplayListQueryRetriesWhenInitialZeroCountGrows() throws {
    var callCount = 0

    let result = try DisplayInventory.queryDisplayIDs(apiName: "TestDisplayList") {
      maxDisplays, displays, displayCount in
      callCount += 1
      switch callCount {
      case 1:
        displayCount?.pointee = 0
      case 2:
        XCTAssertEqual(maxDisplays, 0)
        displayCount?.pointee = 1
      case 3, 4:
        displayCount?.pointee = 1
      case 5:
        displays?[0] = 42
        displayCount?.pointee = 1
      case 6:
        displayCount?.pointee = 1
      default:
        XCTFail("Unexpected list query call")
      }
      return .success
    }

    XCTAssertEqual(result, [42])
    XCTAssertEqual(callCount, 6)
  }

  func testDisplayListQueryReturnsCoherentShrink() throws {
    var callCount = 0

    let result = try DisplayInventory.queryDisplayIDs(apiName: "TestDisplayList") {
      _, displays, displayCount in
      callCount += 1
      switch callCount {
      case 1:
        displayCount?.pointee = 3
      case 2:
        displays?[0] = 8
        displays?[1] = 9
        displayCount?.pointee = 2
      case 3:
        displayCount?.pointee = 2
      default:
        XCTFail("Unexpected list query call")
      }
      return .success
    }

    XCTAssertEqual(result, [8, 9])
    XCTAssertEqual(callCount, 3)
  }

  func testDisplayListQueryRetriesChangeAfterValueRead() throws {
    var callCount = 0

    let result = try DisplayInventory.queryDisplayIDs(apiName: "TestDisplayList") {
      _, displays, displayCount in
      callCount += 1
      switch callCount {
      case 1:
        displayCount?.pointee = 2
      case 2:
        displays?[0] = 11
        displays?[1] = 22
        displayCount?.pointee = 2
      case 3, 4:
        displayCount?.pointee = 1
      case 5:
        displays?[0] = 33
        displayCount?.pointee = 1
      case 6:
        displayCount?.pointee = 1
      default:
        XCTFail("Unexpected list query call")
      }
      return .success
    }

    XCTAssertEqual(result, [33])
    XCTAssertEqual(callCount, 6)
  }

  func testDisplayListQueryMapsCGError() {
    XCTAssertThrowsError(
      try DisplayInventory.queryDisplayIDs(apiName: "TestDisplayList") {
        _, _, _ in .failure
      }
    ) {
      XCTAssertEqual(
        $0 as? DisplayControlError,
        .configurationFailed("TestDisplayList count failed with error 1000")
      )
    }
  }

  func testDisplayListQueryFailsAfterBoundedUnstableReads() {
    var callCount = 0

    XCTAssertThrowsError(
      try DisplayInventory.queryDisplayIDs(
        apiName: "TestDisplayList",
        maxAttempts: 2
      ) { _, displays, displayCount in
        callCount += 1
        switch callCount % 3 {
        case 1:
          displayCount?.pointee = 1
        case 2:
          displays?[0] = 11
          displayCount?.pointee = 1
        default:
          displayCount?.pointee = 2
        }
        return .success
      }
    ) {
      XCTAssertEqual($0 as? DisplayControlError, .inventoryChanged)
    }
    XCTAssertEqual(callCount, 6)
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
      metadata: metadata(
        localizedNames: [1: "Internal Panel", 2: "Inactive Screen"], inactive: [2])
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

  func testActiveIDMissingFromOnlineSampleFailsAsInconsistent() {
    let inventory = DisplayInventory(
      candidateDetector: UnknownDDCCandidateDetector(), onlineIDs: { [] }, activeIDs: { [1] })

    XCTAssertThrowsError(try inventory.snapshot()) {
      XCTAssertEqual(
        $0 as? DisplayControlError,
        .inventoryChanged)
    }
  }

  func testSnapshotRetriesInconsistentSample() throws {
    let online = SampleCounter()
    let active = SampleCounter()
    // First sample: online [7] but active [1]; second sample: both empty. A retry that kept the
    // first online list would see [7] online with no metadata and fail.
    let inventory = DisplayInventory(
      candidateDetector: UnknownDDCCandidateDetector(),
      onlineIDs: { online.next() == 1 ? [7] : [] },
      activeIDs: { active.next() == 1 ? [1] : [] }, retryDelayMicroseconds: 0)

    XCTAssertEqual(try inventory.snapshot(), [])
    XCTAssertEqual(online.count, 2)
    XCTAssertEqual(active.count, 2)
  }

  func testSnapshotThrowsInventoryChangedAfterRetries() {
    let samples = SampleCounter()
    let inventory = DisplayInventory(
      candidateDetector: UnknownDDCCandidateDetector(), onlineIDs: { [] },
      activeIDs: {
        _ = samples.next()
        return [1]
      }, retryDelayMicroseconds: 0)

    XCTAssertThrowsError(try inventory.snapshot()) {
      XCTAssertEqual($0 as? DisplayControlError, .inventoryChanged)
    }
    XCTAssertEqual(samples.count, 3)
  }

  // Values measured on macOS 27.0.1 (D-012).
  private static let unkn: UInt32 = 0x756E_6B6E
  private static let virt: UInt32 = 0x7669_7274

  func testPlaceholderSignatureNeedsAllFourSignals() {
    func classify(_ vendor: UInt32, _ model: UInt32, _ width: Double, _ height: Double, mode: Bool)
      -> Bool
    {
      DisplayInventory.isPlaceholder(
        vendorNumber: vendor, modelNumber: model,
        sizeMillimeters: CGSize(width: width, height: height), hasCurrentMode: mode)
    }
    XCTAssertEqual(Self.unkn, 1_970_170_734)
    XCTAssertEqual(Self.virt, 1_986_622_068)
    XCTAssertTrue(classify(Self.unkn, Self.virt, 0, 0, mode: false))
    // Dell U2720Q and the built-in panel.
    XCTAssertFalse(classify(4268, 16821, 599, 339, mode: true))
    XCTAssertFalse(classify(1552, 41053, 0, 0, mode: false))
    // Each signal alone, or three of four, is not enough.
    XCTAssertFalse(classify(Self.unkn, Self.virt, 599, 339, mode: false))
    XCTAssertFalse(classify(Self.unkn, Self.virt, 0, 339, mode: false))
    XCTAssertFalse(classify(Self.unkn, Self.virt, 0, 0, mode: true))
    XCTAssertFalse(classify(Self.unkn, 16821, 0, 0, mode: false))
    XCTAssertFalse(classify(4268, Self.virt, 0, 0, mode: false))
    XCTAssertFalse(classify(4268, 16821, 0, 0, mode: false))
  }

  func testPlaceholderStaysInSnapshotFlaggedAsReported() throws {
    var entries = metadata(inactive: [1])
    entries[2] = DisplayMetadata(
      uuid: externalUUID, isBuiltIn: false, isActive: true, isMain: true,
      vendorNumber: Self.unkn, modelNumber: Self.virt, localizedName: nil, isPlaceholder: true)

    let result = try DisplayInventory.makeDisplays(
      onlineIDs: [1, 2], activeIDs: [2], metadata: entries)
    let ddc = DisplayInventory.applyingDDCCapabilities(
      to: result, detector: UnknownDDCCandidateDetector())

    let placeholder = try XCTUnwrap(ddc.first { $0.runtimeID == 2 })
    XCTAssertTrue(placeholder.isPlaceholder)
    XCTAssertTrue(placeholder.isOnline && placeholder.isActive && placeholder.isMain)
    XCTAssertFalse(placeholder.isUsableActive)
    XCTAssertFalse(try XCTUnwrap(ddc.first { $0.runtimeID == 1 }).isPlaceholder)
  }

  func testPlaceholderSkipsDDCLookup() throws {
    let detector = CountingDDCCandidateDetector()
    let placeholder = Display(
      uuid: externalUUID, runtimeID: 12, name: "External Display", kind: .external,
      isOnline: true, isActive: true, isMain: true, ddcCapability: .unknown, isPlaceholder: true)

    let result = DisplayInventory.applyingDDCCapabilities(to: [placeholder], detector: detector)

    XCTAssertEqual(result.first?.ddcCapability, .unsupported)
    XCTAssertTrue(try XCTUnwrap(result.first).isPlaceholder)
    XCTAssertEqual(detector.calls, 0)
  }

  func testUsableActiveCountSkipsPlaceholders() {
    XCTAssertEqual(
      DisplayInventory.usableActiveCount(activeIDs: [], isPlaceholder: { _ in false }), 0)
    XCTAssertEqual(
      DisplayInventory.usableActiveCount(activeIDs: [12], isPlaceholder: { $0 == 12 }), 0)
    XCTAssertEqual(
      DisplayInventory.usableActiveCount(activeIDs: [1, 12], isPlaceholder: { $0 == 12 }), 1)
  }

  private func metadata(
    localizedNames: [UInt32: String] = [1: "Internal Panel", 2: "Studio Display"],
    inactive: Set<UInt32> = []
  )
    -> [UInt32: DisplayMetadata]
  {
    [
      1: DisplayMetadata(
        uuid: internalUUID,
        isBuiltIn: true,
        isActive: !inactive.contains(1),
        isMain: true,
        vendorNumber: 0,
        modelNumber: 0,
        localizedName: localizedNames[1]
      ),
      2: DisplayMetadata(
        uuid: externalUUID,
        isBuiltIn: false,
        isActive: !inactive.contains(2),
        isMain: false,
        vendorNumber: 610,
        modelNumber: 0x1234,
        localizedName: localizedNames[2]
      ),
    ]
  }
}

struct UnknownDDCCandidateDetector: DDCCandidateDetecting {
  func capability(for display: Display) -> DDCCapability { .unknown }
}

private final class CountingDDCCandidateDetector: DDCCandidateDetecting, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var calls: Int { lock.withLock { count } }

  func capability(for display: Display) -> DDCCapability {
    lock.withLock { count += 1 }
    return .candidate
  }
}

/// Counts sampler calls; `next()` returns the 1-based call number.
private final class SampleCounter: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var count = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
}
