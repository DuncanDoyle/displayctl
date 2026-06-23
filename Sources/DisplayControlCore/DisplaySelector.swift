public enum DisplaySelector {
    public static func resolve(_ selector: String, in displays: [Display]) throws -> Display {
        if selector == DisplayKind.internal.rawValue {
            return try resolveAlias(selector, kind: .internal, in: displays)
        }

        if selector == DisplayKind.external.rawValue {
            return try resolveAlias(selector, kind: .external, in: displays)
        }

        if let display = displays.first(where: { $0.uuid.uuidString == selector }) {
            return display
        }

        if let runtimeID = UInt32(selector),
           let display = displays.first(where: { $0.runtimeID == runtimeID }) {
            return display
        }

        throw DisplayControlError.displayNotFound(selector)
    }

    private static func resolveAlias(
        _ selector: String,
        kind: DisplayKind,
        in displays: [Display]
    ) throws -> Display {
        let matches = displays.filter { $0.kind == kind }

        guard let display = matches.first else {
            throw DisplayControlError.displayNotFound(selector)
        }

        guard matches.count == 1 else {
            throw DisplayControlError.ambiguousSelector(selector)
        }

        return display
    }
}
