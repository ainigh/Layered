import Foundation

/// Reading a passage (SPEC “Reading in passages”): the model does the language, the
/// harness does the notation. `read` rewrites each sentence as plain standalone sentences
/// (`s3: Ana reviews the paper.`); `facts` turns those into `s3: ana (person) | reviews |
/// paper (thing)`; this file turns both into what the rest of the harness uses.

/// One plain sentence `read` wrote, and the sentence of the text it came from.
public struct Reading: Equatable, Sendable {
    public var s: Int
    public var text: String

    public init(s: Int, text: String) {
        self.s = s
        self.text = text
    }

    /// The passage as `read` gets it: one numbered sentence per line.
    public static func passage(_ sentences: [Sentence]) -> String {
        sentences.map { "s\($0.s): \(Text.collapse($0.sentence))" }.joined(separator: "\n")
    }

    /// Lines `s3: text`. A line without a number belongs to the sentence before it (or the
    /// passage's first); a number not in the passage is the model's slip, and goes with it
    /// too. A line that is only a dash or “nothing” says the sentence holds nothing.
    public static func parse(_ output: String, passage: [Int]) -> [Reading] {
        guard let first = passage.first else { return [] }
        var out: [Reading] = []
        var last = first
        for raw in output.split(separator: "\n") {
            let (number, rest) = Numbered.split(String(raw))
            if let number { last = passage.contains(number) ? number : last }
            let text = Text.collapse(rest)
            guard !text.isEmpty, !Numbered.isNothing(text) else { continue }
            out.append(Reading(s: last, text: text))
        }
        return out
    }

    /// What `facts` gets: the readings, numbered as their sentences.
    public static func render(_ readings: [Reading]) -> String {
        readings.map { "s\($0.s): \($0.text)" }.joined(separator: "\n")
    }

    /// Each sentence's readings as one string, for the gate's proof check.
    public static func bySentence(_ readings: [Reading]) -> [Int: String] {
        var out: [Int: String] = [:]
        for r in readings { out[r.s] = out[r.s].map { $0 + " " + r.text } ?? r.text }
        return out
    }
}

/// One fact: `subject (kind) | relation | object (kind)`, or a name on its own.
public struct Fact: Equatable, Sendable {
    public var s: Int
    public var subject: String
    public var subjectKind: String?
    public var relation: String?
    public var object: String?
    public var objectKind: String?

    public init(s: Int, subject: String, subjectKind: String? = nil, relation: String? = nil, object: String? = nil, objectKind: String? = nil) {
        self.s = s
        self.subject = subject
        self.subjectKind = subjectKind
        self.relation = relation
        self.object = object
        self.objectKind = objectKind
    }
}

public enum Facts {
    public static let kinds: Set<String> = ["person", "place", "thing", "action", "event", "idea"]

    /// One line of `facts`. `s` is the sentence it belongs to when it has no number of its
    /// own. Nil when it is not a fact (prose, an empty name).
    public static func parse(_ line: String, s: Int) -> Fact? {
        let (number, rest) = Numbered.split(line)
        let parts = rest.split(separator: "|", omittingEmptySubsequences: false).map { Text.collapse($0) }
        let s = number ?? s
        switch parts.count {
        case 1:
            // A name on its own carries its kind (`sam (person)`); without one it is prose.
            let (name, kind) = named(parts[0])
            guard let name, let kind else { return nil }
            return Fact(s: s, subject: name, subjectKind: kind)
        case 2:
            // `a | b`: two names with no relation between them.
            let (a, ak) = named(parts[0]), (b, bk) = named(parts[1])
            guard let a, let b else { return nil }
            return Fact(s: s, subject: a, subjectKind: ak, object: b, objectKind: bk)
        case 3:
            let (a, ak) = named(parts[0]), (b, bk) = named(parts[2])
            guard let a else { return nil }
            let relation = label(parts[1])
            guard let b else { return Fact(s: s, subject: a, subjectKind: ak) }
            return Fact(s: s, subject: a, subjectKind: ak, relation: relation, object: b, objectKind: bk)
        default:
            return nil
        }
    }

    /// The notation for a fact: a kind note on each name the first time, then the link.
    public static func notation(_ fact: Fact) -> [String] {
        var lines: [String] = []
        if let kind = fact.subjectKind { lines.append(Render.path(Path(names: [Name(fact.subject)], notes: ["kind \(kind)"]))) }
        if let object = fact.object, object != fact.subject {
            if let kind = fact.objectKind { lines.append(Render.path(Path(names: [Name(object)], notes: ["kind \(kind)"]))) }
            let link = Link(labels: fact.relation.map { [$0] } ?? [])
            lines.append(Render.path(Path(names: [Name(fact.subject), Name(object)], links: [link])))
        } else if fact.subjectKind == nil {
            lines.append(Render.path(Path(names: [Name(fact.subject)])))
        }
        return lines
    }

    /// `paper (thing)` → (`paper`, `thing`). The name is cleaned for the notation; a kind
    /// outside the six is dropped.
    static func named(_ raw: String) -> (String?, String?) {
        var text = raw
        var kind: String?
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let inside = Text.collapse(text[text.index(after: open)..<text.index(before: text.endIndex)]).lowercased()
            text = String(text[..<open])
            kind = kinds.contains(inside) ? inside : nil
        }
        let name = Canonicaliser.canonical(clean(text))
        return (name.isEmpty ? nil : name, kind)
    }

    /// A relation as a link label: lowercase words, no notation symbols.
    static func label(_ raw: String) -> String? {
        let words = clean(raw).lowercased()
        return words.isEmpty ? nil : words
    }

    /// Words only: what would read as notation (`|`, `@`, `=`, a lone `-`) becomes a space.
    static func clean(_ raw: String) -> String {
        let symbols: Set<Character> = ["|", "@", "=", "(", ")", "[", "]", "{", "}", "\"", "`", "*", "#", ":", ";"]
        let spaced = String(raw.map { symbols.contains($0) ? " " : $0 })
        let words = spaced.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-.,!?")) }.filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }
}

/// `s3: text`, `s3 text`, `3: text`, `- s3: text`: the sentence number, and the rest.
enum Numbered {
    static func split(_ line: String) -> (Int?, String) {
        var rest = Substring(Text.collapse(line))
        while let c = rest.first, c == "-" || c == "*" || c == "•" { rest = rest.dropFirst().drop(while: { $0 == " " }) }
        var probe = rest
        let lettered = probe.first == "s" || probe.first == "S"
        if lettered { probe = probe.dropFirst() }
        let digits = probe.prefix(while: \.isNumber)
        guard !digits.isEmpty, let n = Int(digits) else { return (nil, String(rest)) }
        let after = probe.dropFirst(digits.count)
        // A number is a label when a colon follows it (or a space after `s3`): “3 people came”
        // is a sentence, not sentence 3.
        let marks: Set<Character> = lettered ? [":", ".", ")", " "] : [":", ")"]
        guard let next = after.first, marks.contains(next) else { return (nil, String(rest)) }
        return (n, String(after.dropFirst()))
    }

    static func isNothing(_ text: String) -> Bool {
        let t = Text.collapse(text).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".-–— "))
        return t.isEmpty || t == "nothing" || t == "none" || t == "(nothing)"
    }
}
