import DisplayControlCore

public enum BrightnessPercent {
  /// Rounds a DDC reading to 0...100; a reply with maximum 0 counts as a failed read.
  public static func from(_ value: DDCValue) throws -> Int {
    guard value.maximum != 0 else {
      throw DisplayControlError.ddcInvalidResponse("maximum is 0")
    }
    let percent = (Double(value.current) * 100 / Double(value.maximum)).rounded()
    return min(100, max(0, Int(percent)))
  }
}
