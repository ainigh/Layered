import AppKit
import Harness

/// The icons a node's name can match beyond the project's own: the harness's built-in words
/// first, then every SF Symbol on this Mac under the first word of its name ("car" for
/// car.fill), then under the words Apple's symbol search finds it by. Both come from the copy
/// of SF Symbols macOS keeps (CoreGlyphs); if those files are missing or move, the built-in
/// words still work.
enum SymbolLibrary {
    static let all: IconLibrary = {
        var library = IconLibrary.builtIn
        let dir = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
        func plist(_ name: String) -> Any? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        var named: [String: [String]] = [:]
        if let symbols = (plist("name_availability.plist") as? [String: Any])?["symbols"] as? [String: Any] {
            for name in symbols.keys { named[String(name.prefix { $0 != "." }), default: []].append(name) }
        }
        var tagged: [String: [String]] = [:]
        if let search = plist("symbol_search.plist") as? [String: [String]] {
            for (name, terms) in search {
                for term in terms where !term.contains(" ") { tagged[term, default: []].append(name) }
            }
        }
        // Names before tags, so "car" draws a car before anything merely tagged "car".
        for (word, names) in named { library.add(word, plainestFirst(names), minLength: 3) }
        for (word, names) in tagged { library.add(word, plainestFirst(names), minLength: 3) }
        return library
    }()

    /// The plainest symbol first: fewest parts (car before car.fill), then shortest.
    private static func plainestFirst(_ names: [String]) -> [String] {
        names.sorted {
            let a = $0.split(separator: ".").count, b = $1.split(separator: ".").count
            return a != b ? a < b : $0.count != $1.count ? $0.count < $1.count : $0 < $1
        }
    }

    private static let cache = Cache()

    /// Whether this Mac has the symbol (asked once per name).
    static func exists(_ name: String) -> Bool { cache.exists(name) }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Bool] = [:]

        func exists(_ name: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let known = known[name] { return known }
            let found = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            known[name] = found
            return found
        }
    }
}
