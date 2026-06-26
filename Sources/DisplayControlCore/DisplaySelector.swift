public enum DisplaySelector {
  public static func resolve(_ selector: String, in displays: [Display]) throws -> Display {
    if selector == DisplayKind.internal.rawValue {
      return try resolveMatches(selector, displays.filter { $0.kind == .internal })
    }

    if selector == DisplayKind.external.rawValue {
      return try resolveMatches(selector, displays.filter { $0.kind == .external })
    }

    let uuidMatches = displays.filter { $0.uuid.uuidString == selector }
    if !uuidMatches.isEmpty {
      return try resolveMatches(selector, uuidMatches)
    }

    if let runtimeID = UInt32(selector) {
      return try resolveMatches(selector, displays.filter { $0.runtimeID == runtimeID })
    }

    throw DisplayControlError.displayNotFound(selector)
  }

  private static func resolveMatches(
    _ selector: String,
    _ matches: [Display]
  ) throws -> Display {
    guard let display = matches.first else {
      throw DisplayControlError.displayNotFound(selector)
    }

    guard matches.count == 1 else {
      throw DisplayControlError.ambiguousSelector(selector)
    }

    return display
  }
}
