import XCTest

@testable import DisplayControlCore

final class DisplaySelectorTests: XCTestCase {
  func testResolvesExactUUID() throws {
    let display = fixture(id: 1, kind: .internal)

    XCTAssertEqual(try DisplaySelector.resolve(display.uuid.uuidString, in: [display]), display)
  }

  func testRejectsDuplicateUUIDMatchesAsAmbiguous() {
    let first = fixture(id: 1, kind: .internal)
    let second = fixture(id: 2, kind: .external, uuid: first.uuid)
    let selector = first.uuid.uuidString

    XCTAssertThrowsError(try DisplaySelector.resolve(selector, in: [first, second])) {
      XCTAssertEqual($0 as? DisplayControlError, .ambiguousSelector(selector))
    }
  }

  func testRejectsNonCanonicalLowercaseUUID() {
    let display = fixture(id: 1, kind: .internal)
    let selector = display.uuid.uuidString.lowercased()

    XCTAssertThrowsError(try DisplaySelector.resolve(selector, in: [display])) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound(selector))
    }
  }

  func testResolvesDecimalRuntimeID() throws {
    let display = fixture(id: 2, kind: .external)

    XCTAssertEqual(try DisplaySelector.resolve("2", in: [display]), display)
  }

  func testRejectsDuplicateRuntimeIDMatchesAsAmbiguous() {
    let first = fixture(id: 2, kind: .external)
    let second = fixture(id: 3, kind: .external, runtimeID: first.runtimeID)
    let selector = String(first.runtimeID)

    XCTAssertThrowsError(try DisplaySelector.resolve(selector, in: [first, second])) {
      XCTAssertEqual($0 as? DisplayControlError, .ambiguousSelector(selector))
    }
  }

  func testInternalAliasResolvesUniqueInternalDisplay() throws {
    let internalDisplay = fixture(id: 1, kind: .internal)
    let externalDisplay = fixture(id: 2, kind: .external)

    XCTAssertEqual(
      try DisplaySelector.resolve("internal", in: [internalDisplay, externalDisplay]),
      internalDisplay
    )
  }

  func testExternalAliasResolvesUniqueExternalDisplay() throws {
    let internalDisplay = fixture(id: 1, kind: .internal)
    let externalDisplay = fixture(id: 2, kind: .external)

    XCTAssertEqual(
      try DisplaySelector.resolve("external", in: [internalDisplay, externalDisplay]),
      externalDisplay
    )
  }

  func testExternalAliasRejectsMultipleExternalDisplays() throws {
    let displays = [fixture(id: 2, kind: .external), fixture(id: 3, kind: .external)]
    XCTAssertThrowsError(try DisplaySelector.resolve("external", in: displays)) {
      XCTAssertEqual($0 as? DisplayControlError, .ambiguousSelector("external"))
    }
  }

  func testInternalAliasRejectsMultipleInternalDisplays() {
    let displays = [fixture(id: 1, kind: .internal), fixture(id: 2, kind: .internal)]

    XCTAssertThrowsError(try DisplaySelector.resolve("internal", in: displays)) {
      XCTAssertEqual($0 as? DisplayControlError, .ambiguousSelector("internal"))
    }
  }

  func testMissingAliasRejectsSelector() {
    XCTAssertThrowsError(try DisplaySelector.resolve("internal", in: [])) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound("internal"))
    }
  }

  func testMissingSelectorIsRejected() {
    XCTAssertThrowsError(try DisplaySelector.resolve("unknown", in: [])) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound("unknown"))
    }
  }

  func testMissingNumericRuntimeIDIsRejected() {
    let displays = [fixture(id: 1, kind: .internal), fixture(id: 2, kind: .external)]

    XCTAssertThrowsError(try DisplaySelector.resolve("3", in: displays)) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound("3"))
    }
  }

  func testUInt32OverflowSelectorIsRejected() {
    let selector = "4294967296"

    XCTAssertThrowsError(try DisplaySelector.resolve(selector, in: [])) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound(selector))
    }
  }

  func testNonDecimalNumericLikeSelectorIsRejected() {
    let selector = "0x2"

    XCTAssertThrowsError(
      try DisplaySelector.resolve(selector, in: [fixture(id: 2, kind: .external)])
    ) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound(selector))
    }
  }

  func testAllSelectorIsRejected() {
    XCTAssertThrowsError(try DisplaySelector.resolve("all", in: [fixture(id: 2, kind: .external)]))
    {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound("all"))
    }
  }

  func testDifferentlyCasedInternalAliasIsRejected() {
    XCTAssertThrowsError(
      try DisplaySelector.resolve("Internal", in: [fixture(id: 1, kind: .internal)])
    ) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound("Internal"))
    }
  }

  func testDifferentlyCasedExternalAliasIsRejected() {
    XCTAssertThrowsError(
      try DisplaySelector.resolve("EXTERNAL", in: [fixture(id: 2, kind: .external)])
    ) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound("EXTERNAL"))
    }
  }

  func testEmptySelectorIsRejected() {
    XCTAssertThrowsError(try DisplaySelector.resolve("", in: [])) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound(""))
    }
  }

  func testDisplayNameIsNeverResolved() {
    let display = fixture(id: 2, kind: .external, name: "Studio Display")

    XCTAssertThrowsError(try DisplaySelector.resolve("Studio Display", in: [display])) {
      XCTAssertEqual($0 as? DisplayControlError, .displayNotFound("Studio Display"))
    }
  }

  private func fixture(
    id: UInt32,
    kind: DisplayKind,
    name: String = "Fixture Display",
    uuid: UUID? = nil,
    runtimeID: UInt32? = nil
  ) -> Display {
    let uuids: [UInt32: UUID] = [
      1: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
      2: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      3: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
    ]

    return Display(
      uuid: uuid ?? uuids[id]!,
      runtimeID: runtimeID ?? id,
      name: name,
      kind: kind,
      isOnline: true,
      isActive: true,
      isMain: id == 1,
      ddcCapability: kind == .external ? .candidate : .unsupported
    )
  }
}
