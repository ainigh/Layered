import Foundation

/// One record in the append-only context (`context.md`). Most records hold text: pasted,
/// typed, transcribed, a clarification, a chat message or a model reply. The rest are
/// events on a context item (selected, deselected, removed, restored, extracted) and hold
/// no text. Nothing in the file is ever overwritten: an edit is a new record for the same
/// item, a delete is a `removed` event.
public struct ContextParagraph: Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case pasted, typed, transcript, clarification, chat, note
        /// Prose the model wrote in reply to an ask: context the user can select, never proof.
        case model
    }

    /// What happened to an item. Event records carry no body.
    public enum Event: String, Sendable, Codable, CaseIterable {
        case selected, deselected, removed, restored
        /// The item's text (the record's `textID`) went through Extract: it is on the map.
        case extracted
    }

    public var kind: Kind
    /// The context item this record belongs to. Records written before items existed have
    /// none; each of those is an item of its own, numbered in file order.
    public var item: Int?
    /// The text id (evidence store) of this record's body, or of the revision an event names.
    public var textID: Int?
    public var event: Event?
    /// For a model reply: what the user asked.
    public var question: String?
    public var date: Date
    public var body: String

    public init(kind: Kind, item: Int? = nil, textID: Int? = nil, event: Event? = nil, question: String? = nil, date: Date, body: String) {
        self.kind = kind
        self.item = item
        self.textID = textID
        self.event = event
        self.question = question
        self.date = date
        self.body = body
    }

    /// `[item 2 · text 3 · transcript · 2026-10-28T14:02:33Z]` followed by the body and a
    /// blank line. A body line that would read as a header is indented by a space.
    public var rendered: String {
        var label: [String] = []
        if let item { label.append("item \(item)") }
        if let textID { label.append("text \(textID)") }
        label.append(kind.rawValue)
        if let event { label.append(event.rawValue) }
        if let question { label.append("re: " + ContextParagraph.headerSafe(question)) }
        label.append(Turn.format(date))
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            ContextDocument.parseHeader(String(line)) == nil ? String(line) : " " + line
        }
        return "[\(label.joined(separator: " · "))]\n\(lines.joined(separator: "\n"))\n\n"
    }

    /// A question fits on the header line: one line, no field separator.
    static func headerSafe(_ text: String) -> String {
        Text.collapse(text.replacingOccurrences(of: "·", with: "-"))
    }
}

/// A context item: what the Context panel lists. Built from the records that share an item
/// number: the latest text record gives its body, events give its state.
public struct ContextItem: Equatable, Sendable, Identifiable {
    /// Where an item came from, as the panel tells them apart.
    public enum Origin: String, Sendable, CaseIterable {
        case you, audio, clarification, model
    }

    /// One version of the item's text, in the order written.
    public struct Revision: Equatable, Sendable {
        public var textID: Int?
        public var body: String
        public var date: Date
    }

    public var id: Int
    public var kind: ContextParagraph.Kind
    public var revisions: [Revision]
    public var question: String?
    /// In the current context: the model reads only selected items.
    public var selected: Bool
    public var removed: Bool
    /// Text ids that have been through Extract.
    public var extracted: Set<Int>

    public var body: String { revisions.last?.body ?? "" }
    /// The text id of the latest revision.
    public var textID: Int? { revisions.last?.textID }
    public var textIDs: [Int] { revisions.compactMap(\.textID) }
    public var added: Date { revisions.first?.date ?? Date(timeIntervalSince1970: 0) }
    public var edited: Date? { revisions.count > 1 ? revisions.last?.date : nil }

    public var origin: Origin {
        switch kind {
        case .transcript: return .audio
        case .clarification: return .clarification
        case .model: return .model
        case .pasted, .typed, .chat, .note: return .you
        }
    }

    /// Text from audio stays as transcribed, so it keeps in step with the recording.
    public var isEditable: Bool { kind != .transcript }
    /// Its latest text has been through Extract.
    public var isOnMap: Bool { textID.map(extracted.contains) ?? false }
    /// Submit would send it: selected, not removed, not a model reply, latest text not yet extracted.
    public var isPending: Bool { selected && !removed && kind != .model && textID != nil && !isOnMap }

    /// The latest revision already on the map, which Submit diffs against.
    public var lastExtracted: Revision? {
        revisions.last { $0.textID.map(extracted.contains) ?? false }
    }

    /// New items are in the context; a model reply waits until the user selects it.
    static func selectedByDefault(_ kind: ContextParagraph.Kind) -> Bool { kind != .model }
}

public struct ContextDocument: Equatable, Sendable {
    public private(set) var paragraphs: [ContextParagraph] = []

    public init() {}

    public init(markdown: String) {
        var current: ContextParagraph?
        var body: [String] = []
        func close() {
            if var p = current {
                p.body = body.map { $0.hasPrefix(" [") && ContextDocument.parseHeader(String($0.dropFirst())) != nil ? String($0.dropFirst()) : $0 }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
        var item: Int?
        var textID: Int?
        var kind: ContextParagraph.Kind?
        var event: ContextParagraph.Event?
        var question: String?
        var date = Date(timeIntervalSince1970: 0)
        for part in parts {
            if part.hasPrefix("re: ") { question = String(part.dropFirst(4)) }
            else if part.hasPrefix("item "), let n = Int(part.dropFirst(5)) { item = n }
            else if part.hasPrefix("text "), let n = Int(part.dropFirst(5)) { textID = n }
            else if let k = ContextParagraph.Kind(rawValue: part) { kind = k }
            else if let e = ContextParagraph.Event(rawValue: part) { event = e }
            else if let d = ISO8601DateFormatter().date(from: part) { date = d }
        }
        guard let kind else { return nil }
        return ContextParagraph(kind: kind, item: item, textID: textID, event: event, question: question, date: date, body: "")
    }

    public var markdown: String { paragraphs.map(\.rendered).joined() }

    /// Appends a record and returns the text to append to `context.md`.
    @discardableResult
    public mutating func append(_ paragraph: ContextParagraph) -> String {
        paragraphs.append(paragraph)
        return paragraph.rendered
    }

    /// Records that hold text (not events).
    public var textParagraphs: [ContextParagraph] { paragraphs.filter { $0.event == nil } }

    /// The whole context as one text, the way Extract reads it.
    public var plainText: String {
        textParagraphs.map { p in
            switch p.kind {
            case .clarification: return "[clarification] \(p.body)"
            case .chat: return "[chat] \(p.body)"
            case .model: return "[model] \(p.body)"
            default: return p.body
            }
        }.joined(separator: "\n\n")
    }

    public func paragraphs(ofKind kind: ContextParagraph.Kind) -> [ContextParagraph] {
        textParagraphs.filter { $0.kind == kind }
    }

    // MARK: - Items

    /// The items, in the order they were first added.
    public var items: [ContextItem] {
        var order: [Int] = []
        var byID: [Int: ContextItem] = [:]
        var next = 1
        for p in paragraphs {
            if let event = p.event {
                guard let id = p.item, var item = byID[id] else { continue }
                switch event {
                case .selected: item.selected = true
                case .deselected: item.selected = false
                case .removed: item.removed = true
                case .restored: item.removed = false
                case .extracted: if let t = p.textID { item.extracted.insert(t) }
                }
                byID[id] = item
                continue
            }
            let id = p.item ?? next
            next = max(next, id + 1)
            let revision = ContextItem.Revision(textID: p.textID, body: p.body, date: p.date)
            if var item = byID[id] {
                item.revisions.append(revision)
                item.kind = p.kind
                if let q = p.question { item.question = q }
                byID[id] = item
            } else {
                order.append(id)
                // A record from before items was submitted when it was written.
                let extracted: Set<Int> = p.item == nil ? Set([p.textID].compactMap { $0 }) : []
                byID[id] = ContextItem(id: id, kind: p.kind, revisions: [revision], question: p.question,
                                       selected: ContextItem.selectedByDefault(p.kind), removed: false, extracted: extracted)
            }
        }
        return order.compactMap { byID[$0] }
    }

    public func item(_ id: Int) -> ContextItem? { items.first { $0.id == id } }

    /// The item a text id belongs to (any of its revisions).
    public func item(forText textID: Int) -> ContextItem? { items.first { $0.textIDs.contains(textID) } }

    /// The number the next new item gets.
    public var nextItemID: Int {
        var next = 1
        for p in paragraphs where p.event == nil { next = max(next, (p.item ?? next) + 1) }
        return next
    }

    /// Text ids of the current context: the latest text of every selected item not removed.
    public var selectedTexts: [Int] {
        items.filter { $0.selected && !$0.removed }.compactMap(\.textID)
    }

    /// Text ids the model wrote. Its replies are context the user may select, never proof.
    public var replyTexts: Set<Int> {
        Set(textParagraphs.filter { $0.kind == .model }.compactMap(\.textID))
    }

    /// Items Submit would send, in order.
    public var pendingItems: [ContextItem] { items.filter(\.isPending) }
}

/// Submit modes (SPEC “Submit modes”).
public enum Submit {
    /// All at once: paragraphs are hashed and only new or changed ones are sent.
    public static func changedParagraphs(previous: String?, current: String) -> [String] {
        let before = Set((previous ?? "").components(separatedBy: "\n\n").map { Text.collapse($0) }.filter { !$0.isEmpty })
        return current.components(separatedBy: "\n\n").map { Text.collapse($0) }.filter { !$0.isEmpty && !before.contains($0) }
    }

    /// What Submit sends for an item: its paragraphs that are new or changed since the
    /// revision already on the map (all of them the first time). Empty when an edit only
    /// removed text: there is nothing new to extract.
    public static func request(for item: ContextItem) -> String {
        changedParagraphs(previous: item.lastExtracted?.body, current: item.body).joined(separator: "\n\n")
    }
}

/// One sentence at a time: walks texts, one call per sentence against the latest map.
public struct SentenceWalk: Equatable, Sendable {
    public var textID: Int
    public var sentences: [Sentence]
    public var index = 0
    public var paused = false

    public init(textID: Int, sentences: [Sentence]) {
        self.textID = textID
        self.sentences = sentences
    }

    /// A walk over several texts in turn; `textID` is the first.
    public init(sentences: [Sentence]) {
        self.init(textID: sentences.first?.text ?? 0, sentences: sentences)
    }

    public var current: Sentence? { index < sentences.count ? sentences[index] : nil }
    public var isFinished: Bool { index >= sentences.count }
    public var progress: Double { sentences.isEmpty ? 1 : Double(index) / Double(sentences.count) }

    /// Moves on; returns the text id whose last sentence was just done, if one was.
    @discardableResult
    public mutating func advance() -> Int? {
        let done = current?.text
        index = min(index + 1, sentences.count)
        return done != nil && current?.text != done ? done : nil
    }
}
