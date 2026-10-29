import Foundation

/// The icon set: a folder of SVGs with `manifest.json` mapping keywords and synonyms to
/// files (`{"dog": ["dog", "puppy", "hound"]}`). Name tokens are matched after
/// singularising; every match yields an icon (SPEC “Icons”).
public struct IconManifest: Equatable, Sendable {
    /// file (without extension) → keywords
    public var entries: [String: [String]]
    private var lookup: [String: String] = [:]

    public init(entries: [String: [String]] = [:]) {
        self.entries = entries
        for (file, words) in entries {
            for word in words + [file] { lookup[Canonicaliser.singular(word.lowercased())] = file }
        }
    }

    public init(json: Data) throws {
        self.init(entries: try JSONDecoder().decode([String: [String]].self, from: json))
    }

    /// Icons for a node name, in token order, without repeats.
    public func icons(for name: String) -> [String] {
        var out: [String] = []
        for token in name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let file = lookup[Canonicaliser.singular(String(token))] { out.appendUnique(file) }
        }
        return out
    }

    /// How the badge shows them: up to three stacked, then “+n”.
    public static func badge(_ icons: [String]) -> (shown: [String], more: Int) {
        (Array(icons.prefix(3)), max(0, icons.count - 3))
    }

    /// The built-in SF Symbol names for each kind, used when no icon matches.
    public static func fallbackSymbol(kind: String?) -> String {
        switch kind {
        case "person": return "person"
        case "place": return "mappin.and.ellipse"
        case "thing": return "cube"
        case "action": return "bolt"
        case "event": return "calendar"
        case "idea": return "lightbulb"
        default: return "circle"
        }
    }
}
