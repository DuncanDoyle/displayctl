import DisplayControlCore
import XCTest

@testable import DisplayMenuKit

final class LiveBrightnessConversionTests: XCTestCase {
  func testRoundsToPercent() throws {
    XCTAssertEqual(try BrightnessPercent.from(DDCValue(current: 50, maximum: 200)), 25)
  }

  func testZeroMaximumThrows() {
    XCTAssertThrowsError(try BrightnessPercent.from(DDCValue(current: 10, maximum: 0))) { error in
      XCTAssertEqual(
        error as? DisplayControlError, .ddcInvalidResponse("maximum is 0"))
    }
  }
}
