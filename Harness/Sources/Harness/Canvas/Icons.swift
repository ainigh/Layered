import Foundation

/// The icon set: a folder of SVGs with `manifest.json` mapping keywords and synonyms to
/// files (`{"dog": ["dog", "puppy", "hound"]}`). Name tokens are matched after
/// singularising; every match yields an icon (SPEC “Icons”). A token the project's own
/// icons do not cover is looked up in `library`.
public struct IconManifest: Equatable, Sendable {
    /// file (without extension) → keywords
    public var entries: [String: [String]]
    private var lookup: [String: String] = [:]
    /// Words → SF Symbols, for tokens the entries do not cover (empty unless the app sets it).
    public var library = IconLibrary()

    public init(entries: [String: [String]] = [:]) {
        self.entries = entries
        for (file, words) in entries {
            for word in words + [file] { lookup[Canonicaliser.singular(word.lowercased())] = file }
        }
    }

    public init(json: Data) throws {
        self.init(entries: try JSONDecoder().decode([String: [String]].self, from: json))
    }

    /// Icons for a node name, in token order, without repeats: the project's own for a token,
    /// else the library's best symbol for it that is `available` (the app asks the system).
    public func icons(for name: String, available: (String) -> Bool = { _ in true }) -> [String] {
        var out: [String] = []
        for token in name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = Canonicaliser.singular(String(token))
            if let file = lookup[word] {
                out.appendUnique(file)
            } else if let symbol = library.symbols(for: word).first(where: available) {
                out.appendUnique(symbol)
            }
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

/// Words → SF Symbols, for names the project's own icons do not cover: the built-in words
/// maps tend to hold (`builtIn`) and, added by the app, the names and search tags of the
/// symbols on the Mac. Each word keeps its symbols best first; words added later go behind.
public struct IconLibrary: Equatable, Sendable {
    private var lookup: [String: [String]] = [:]

    public init() {}

    /// How many words it knows.
    public var count: Int { lookup.count }

    public func symbols(for word: String) -> [String] {
        lookup[Canonicaliser.singular(word.lowercased())] ?? []
    }

    /// Adds symbols for a word, behind any it has. A word shorter than `minLength`, with
    /// anything but letters, or too common to mean a thing (`stopWords`) is skipped.
    public mutating func add(_ word: String, _ symbols: [String], minLength: Int = 2) {
        let key = Canonicaliser.singular(word.lowercased())
        guard key.count >= minLength, key.allSatisfy(\.isLetter), !Self.stopWords.contains(key) else { return }
        var list = lookup[key] ?? []
        for symbol in symbols where !list.contains(symbol) { list.append(symbol) }
        lookup[key] = list
    }

    /// Words that name nothing on their own; a symbol tagged with one would land on half the map.
    public static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "do", "does", "for", "from",
        "had", "has", "have", "he", "her", "his", "if", "in", "into", "is", "it", "its", "me", "my", "no",
        "not", "of", "off", "on", "one", "or", "our", "out", "she", "so", "than", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "those", "to", "too", "up", "us", "was", "we",
        "were", "what", "when", "where", "which", "who", "why", "will", "with", "you", "your", "all", "any",
        "some", "more", "most", "other", "such", "only", "own", "same", "very", "just", "also", "new", "old",
        "fill", "filled", "circle", "square", "badge", "slash", "left", "right", "top", "bottom", "half",
    ]

    /// The words maps tend to hold, each with the SF Symbols that draw it (best first; later
    /// ones stand in where an older macOS lacks the first).
    public static let builtIn: IconLibrary = {
        var library = IconLibrary()
        for (symbols, words) in BuiltInIcons.entries {
            let list = symbols.split(separator: "|").map(String.init)
            for word in words.split(separator: " ") { library.add(String(word), list) }
        }
        return library
    }()
}
