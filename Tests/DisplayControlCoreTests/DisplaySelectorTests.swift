import XCTest
@testable import DisplayControlCore

final class DisplaySelectorTests: XCTestCase {
    func testResolvesExactUUID() throws {
        let display = fixture(id: 1, kind: .internal)

        XCTAssertEqual(try DisplaySelector.resolve(display.uuid.uuidString, in: [display]), display)
    }

    func testResolvesDecimalRuntimeID() throws {
        let display = fixture(id: 2, kind: .external)

        XCTAssertEqual(try DisplaySelector.resolve("2", in: [display]), display)
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
        name: String = "Fixture Display"
    ) -> Display {
        let uuids: [UInt32: UUID] = [
            1: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            2: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            3: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        ]

        return Display(
            uuid: uuids[id]!,
            runtimeID: id,
            name: name,
            kind: kind,
            isOnline: true,
            isActive: true,
            isMain: id == 1,
            ddcCapability: kind == .external ? .candidate : .unsupported
        )
    }
}
