import Foundation

/// One sentence in the evidence store: `{text, s, sentence, t0?, t1?}` (SPEC “Storage”).
public struct Sentence: Codable, Equatable, Hashable, Sendable {
    public var text: Int
    public var s: Int
    public var sentence: String
    public var t0: Double?
    public var t1: Double?
    public var speaker: String?

    public init(text: Int, s: Int, sentence: String, t0: Double? = nil, t1: Double? = nil, speaker: String? = nil) {
        self.text = text
        self.s = s
        self.sentence = sentence
        self.t0 = t0
        self.t1 = t1
        self.speaker = speaker
    }

    /// The proof note the harness writes on a node or edge: `@text 3 s12`.
    public var proofNote: String { "text \(text) s\(s)" }

    public var id: SentenceID { SentenceID(text: text, s: s) }
}

public struct SentenceID: Hashable, Sendable, Comparable {
    public var text: Int
    public var s: Int

    public init(text: Int, s: Int) {
        self.text = text
        self.s = s
    }

    public static func < (lhs: SentenceID, rhs: SentenceID) -> Bool {
        lhs.text == rhs.text ? lhs.s < rhs.s : lhs.text < rhs.text
    }

    /// Parses a `@text 3 s12` note value (`"3 s12"`).
    public static func parse(noteValue: String) -> SentenceID? {
        let parts = noteValue.split(separator: " ")
        guard parts.count == 2, let text = Int(parts[0]), parts[1].hasPrefix("s"), let s = Int(parts[1].dropFirst()) else { return nil }
        return SentenceID(text: text, s: s)
    }
}

/// Append-only evidence store. Nothing is ever removed, so proof always resolves,
/// even after the context is cleared or a source is forgotten.
public struct EvidenceStore: Equatable, Sendable {
    public private(set) var sentences: [Sentence] = []
    private var index: [SentenceID: Int] = [:]

    public init() {}

    public init(jsonl: String) throws {
        let decoder = JSONDecoder()
        for line in jsonl.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            append(try decoder.decode(Sentence.self, from: Data(line.utf8)))
        }
    }

    /// The next text id: texts are numbered 1, 2, … in submission order.
    public var nextTextID: Int { (sentences.map(\.text).max() ?? 0) + 1 }

    public var count: Int { sentences.count }

    public func sentence(_ id: SentenceID) -> Sentence? {
        index[id].map { sentences[$0] }
    }

    public func sentence(text: Int, s: Int) -> Sentence? {
        sentence(SentenceID(text: text, s: s))
    }

    public func sentences(text: Int) -> [Sentence] {
        sentences.filter { $0.text == text }
    }

    /// Appends one sentence. A sentence with an id already in the store is ignored:
    /// the store never rewrites.
    public mutating func append(_ sentence: Sentence) {
        guard index[sentence.id] == nil else { return }
        index[sentence.id] = sentences.count
        sentences.append(sentence)
    }

    /// Splits a submitted text into sentences, appends them under a new text id and
    /// returns that id with the sentences added.
    @discardableResult
    public mutating func appendText(_ text: String, id: Int? = nil) -> (text: Int, sentences: [Sentence]) {
        let textID = id ?? nextTextID
        var added: [Sentence] = []
        for (offset, sentence) in SentenceSplitter.split(text).enumerated() {
            let entry = Sentence(text: textID, s: offset + 1, sentence: sentence)
            append(entry)
            added.append(entry)
        }
        return (textID, added)
    }

    /// JSON Lines, one sentence per line, in store order. Appending to the file on
    /// disk and re-reading gives the same store.
    public func jsonl() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sentences.map { String(decoding: try! encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + (sentences.isEmpty ? "" : "\n")
    }

    public static func == (lhs: EvidenceStore, rhs: EvidenceStore) -> Bool {
        lhs.sentences == rhs.sentences
    }
}

/// Splits text into sentences with stable numbering: `.`, `!` or `?` followed by
/// whitespace ends a sentence; a paragraph break always ends one.
public enum SentenceSplitter {
    public static func split(_ text: String) -> [String] {
        var out: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var current = ""
            var previous: Character?
            for ch in paragraph {
                if ch.isWhitespace, let p = previous, ".!?".contains(p), !current.isEmpty {
                    out.append(Text.collapse(current))
                    current = ""
                } else {
                    current.append(ch)
                }
                previous = ch
            }
            let last = Text.collapse(current)
            if !last.isEmpty { out.append(last) }
        }
        return out
    }
}
