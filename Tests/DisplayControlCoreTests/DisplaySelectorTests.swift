import XCTest
@testable import DisplayControlCore

final class DisplaySelectorTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(DisplayControlCoreVersion.current, "0.1.0")
    }
}
