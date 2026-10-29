import Foundation

/// Text helpers shared by the parser, the canonicaliser and the gate.
public enum Text {
    /// Trims and collapses internal runs of whitespace to one space (notation §2).
    public static func collapse(_ s: some StringProtocol) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Splits a log into trimmed lines, keeping 1-based line numbers for errors.
    static func numberedLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (number: $0.offset + 1, text: $0.element.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

extension Array where Element: Equatable {
    /// Ordered-set append: notes and labels keep first-seen order without duplicates (§4).
    mutating func appendUnique(_ element: Element) {
        if !contains(element) { append(element) }
    }
}
