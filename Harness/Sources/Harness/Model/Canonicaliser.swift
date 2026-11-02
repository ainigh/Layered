/// Name stability (SPEC “Name stability”, rule 2): the harness canonicalises after
/// the model — trims, lowercases, strips a leading article, singularises with a small
/// rule set, and resolves near matches to existing nodes.
public enum Canonicaliser {
    static let articles: Set<String> = ["the", "a", "an"]

    /// Normal form of a name: lowercase, trimmed, article-free, singular.
    public static func canonical(_ raw: String) -> String {
        var words = Text.collapse(raw).lowercased().split(separator: " ").map(String.init)
        if words.count > 1, let first = words.first, articles.contains(first) {
            words.removeFirst()
        }
        guard let last = words.last else { return "" }
        words[words.count - 1] = singular(last)
        return words.joined(separator: " ")
    }

    /// Words the same in the singular, and plurals the rules below would get wrong.
    static let invariant: Set<String> = ["series", "species", "news", "means", "physics", "economics", "mathematics"]
    static let ieWords: Set<String> = ["movie", "cookie", "zombie", "calorie", "selfie", "rookie", "brownie", "goalie", "pie", "tie", "lie"]
    static let cheWords: Set<String> = ["cache", "niche", "ache", "headache", "avalanche", "moustache", "mustache"]

    /// A small singulariser: enough for the common cases, never clever.
    public static func singular(_ word: String) -> String {
        let w = word
        if w.count <= 3 || invariant.contains(w) { return w }
        if w.hasSuffix("ies") && w.count > 4 {
            let ie = String(w.dropLast())
            return ieWords.contains(ie) ? ie : String(w.dropLast(3)) + "y"
        }
        if w.hasSuffix("zzes") { return String(w.dropLast(2)) }
        if w.hasSuffix("ches"), cheWords.contains(String(w.dropLast())) { return String(w.dropLast()) }
        if w.hasSuffix("sses") || w.hasSuffix("shes") || w.hasSuffix("ches") || w.hasSuffix("xes") {
            return String(w.dropLast(2))
        }
        if w.hasSuffix("ss") || w.hasSuffix("us") || w.hasSuffix("is") || w.hasSuffix("ous") { return w }
        if w.hasSuffix("s") { return String(w.dropLast()) }
        return w
    }

    public struct Resolution: Equatable, Sendable {
        public var name: String
        public var existing: Bool
        public var reason: String?
    }

    /// Resolves a model-written name against existing names: exact, then canonical,
    /// then edit distance ≤ 2 (only for names long enough that a near match is not noise).
    public static func resolve(_ raw: String, among existing: some Collection<String>) -> Resolution {
        let canon = canonical(raw)
        if existing.contains(raw) { return Resolution(name: raw, existing: true, reason: nil) }
        if existing.contains(canon) {
            return Resolution(name: canon, existing: true, reason: canon == raw ? nil : "normalised `\(raw)` to `\(canon)`")
        }
        for name in existing where canonical(name) == canon {
            return Resolution(name: name, existing: true, reason: "`\(raw)` is a variant of `\(name)`")
        }
        if canon.count >= 5 {
            var near: [(name: String, distance: Int)] = []
            for name in existing {
                let distance = editDistance(canonical(name), canon)
                if distance <= 2 && distance < canon.count / 2 { near.append((name, distance)) }
            }
            near.sort { $0.distance == $1.distance ? $0.name < $1.name : $0.distance < $1.distance }
            if let match = near.first {
                return Resolution(name: match.name, existing: true, reason: "`\(raw)` is within edit distance 2 of `\(match.name)`")
            }
        }
        return Resolution(name: canon, existing: false, reason: canon == raw ? nil : "normalised `\(raw)` to `\(canon)`")
    }

    /// Are `a` and `b` at most `limit` edits apart? Only the diagonal band the answer can lie
    /// in is computed, and it stops as soon as every way through is over the limit.
    static func within(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], _ limit: Int) -> Bool {
        if abs(a.count - b.count) > limit { return false }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) <= limit }
        let over = limit + 1
        var previous = (0...b.count).map { min($0, over) }
        var current = [Int](repeating: over, count: b.count + 1)
        for i in 1...a.count {
            let lo = max(1, i - limit), hi = min(b.count, i + limit)
            current[0] = min(i, over)
            if lo > 1 { current[lo - 1] = over }
            var best = current[0]
            for j in lo...hi {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost, over)
                best = min(best, current[j])
            }
            if hi < b.count { current[hi + 1] = over }
            if best > limit { return false }
            swap(&previous, &current)
        }
        return previous[b.count] <= limit
    }

    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Cheap duplicate pass (SPEC “Duplicates”): pairs of existing names that
    /// canonicalise to the same thing or sit within edit distance 2.
    public static func likelyDuplicates(in names: [String]) -> [(String, String, String)] {
        var out: [(String, String, String)] = []
        let sorted = names.sorted()
        // Each name's normal form once, not once per pair; names more than two letters apart
        // in length are more than two edits apart, so they are not measured.
        let normal = sorted.map(canonical)
        let scalars = normal.map { Array($0.unicodeScalars) }
        let counts = sorted.map(\.count)
        // Only names whose normal forms are within two letters in length can match (the same
        // normal form has the same length), so each name meets only those.
        var byLength: [Int: [Int]] = [:]
        for (i, s) in scalars.enumerated() { byLength[s.count, default: []].append(i) }
        for i in sorted.indices {
            let n = scalars[i].count
            let near = (n - 2...n + 2).flatMap { byLength[$0] ?? [] }.filter { $0 > i }.sorted()
            for j in near {
                let a = sorted[i], b = sorted[j]
                if normal[i] == normal[j] {
                    out.append((a, b, "same normal form"))
                } else if min(counts[i], counts[j]) >= 5, within(scalars[i], scalars[j], 2) {
                    out.append((a, b, "edit distance ≤ 2"))
                }
            }
        }
        return out
    }
}
