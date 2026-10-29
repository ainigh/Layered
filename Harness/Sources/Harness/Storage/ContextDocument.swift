import Foundation

/// The append-only context (`context.md`): pasted text, transcripts, clarifications and
/// chat messages, each a labelled paragraph. Nothing in it is ever overwritten.
public struct ContextParagraph: Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case pasted, typed, transcript, clarification, chat, note
    }

    public var kind: Kind
    /// The text id this paragraph was submitted as, once submitted.
    public var textID: Int?
    public var date: Date
    public var body: String

    public init(kind: Kind, textID: Int? = nil, date: Date, body: String) {
        self.kind = kind
        self.textID = textID
        self.date = date
        self.body = body
    }

    /// `[text 3 · transcript · 2026-10-28T14:02:33Z]` followed by the body and a blank line.
    public var rendered: String {
        var label = [kind.rawValue, Turn.format(date)]
        if let textID { label.insert("text \(textID)", at: 0) }
        return "[\(label.joined(separator: " · "))]\n\(body)\n\n"
    }
}

public struct ContextDocument: Equatable, Sendable {
    public private(set) var paragraphs: [ContextParagraph] = []

    public init() {}

    public init(markdown: String) {
        var current: ContextParagraph?
        var body: [String] = []
        func close() {
            if var p = current {
                p.body = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                paragraphs.append(p)
            }
            current = nil
            body = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if let header = ContextDocument.parseHeader(String(line)) {
                close()
                current = header
            } else if current != nil {
                body.append(String(line))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                current = ContextParagraph(kind: .note, date: Date(timeIntervalSince1970: 0), body: "")
                body.append(String(line))
            }
        }
        close()
    }

    static func parseHeader(_ line: String) -> ContextParagraph? {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        let parts = line.dropFirst().dropLast().components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
        var textID: Int?
        var kind: ContextParagraph.Kind?
        var date = Date(timeIntervalSince1970: 0)
        for part in parts {
            if part.hasPrefix("text "), let n = Int(part.dropFirst(5)) { textID = n }
            else if let k = ContextParagraph.Kind(rawValue: part) { kind = k }
            else if let d = ISO8601DateFormatter().date(from: part) { date = d }
        }
        guard let kind else { return nil }
        return ContextParagraph(kind: kind, textID: textID, date: date, body: "")
    }

    public var markdown: String { paragraphs.map(\.rendered).joined() }

    /// Appends a paragraph and returns the text to append to `context.md`.
    @discardableResult
    public mutating func append(_ paragraph: ContextParagraph) -> String {
        paragraphs.append(paragraph)
        return paragraph.rendered
    }

    /// The whole context as one text, the way Extract reads it.
    public var plainText: String {
        paragraphs.map { p in
            switch p.kind {
            case .clarification: return "[clarification] \(p.body)"
            case .chat: return "[chat] \(p.body)"
            default: return p.body
            }
        }.joined(separator: "\n\n")
    }

    public func paragraphs(ofKind kind: ContextParagraph.Kind) -> [ContextParagraph] {
        paragraphs.filter { $0.kind == kind }
    }
}

/// Submit modes (SPEC “Submit modes”).
public enum Submit {
    /// All at once: paragraphs are hashed and only new or changed ones are sent.
    public static func changedParagraphs(previous: String?, current: String) -> [String] {
        let before = Set((previous ?? "").components(separatedBy: "\n\n").map { Text.collapse($0) }.filter { !$0.isEmpty })
        return current.components(separatedBy: "\n\n").map { Text.collapse($0) }.filter { !$0.isEmpty && !before.contains($0) }
    }
}

/// One sentence at a time: walks a text, one call per sentence against the latest map.
public struct SentenceWalk: Equatable, Sendable {
    public var textID: Int
    public var sentences: [Sentence]
    public var index = 0
    public var paused = false

    public init(textID: Int, sentences: [Sentence]) {
        self.textID = textID
        self.sentences = sentences
    }

    public var current: Sentence? { index < sentences.count ? sentences[index] : nil }
    public var isFinished: Bool { index >= sentences.count }
    public var progress: Double { sentences.isEmpty ? 1 : Double(index) / Double(sentences.count) }

    public mutating func advance() { index = min(index + 1, sentences.count) }
}
