/// Six prompts, one notation (SPEC “Model layer”). The defaults live here; a folder
/// can override any of them with `prompts/<kind>.md`. Placeholders: `{map}`,
/// `{context}`, `{nodes}`, `{item}`.
public struct PromptSet: Equatable, Sendable {
    public var overrides: [PromptKind: String]

    public init(overrides: [PromptKind: String] = [:]) {
        self.overrides = overrides
    }

    public func template(for kind: PromptKind) -> String {
        overrides[kind] ?? PromptSet.defaultTemplate(for: kind)
    }

    public func isDefault(_ kind: PromptKind) -> Bool { overrides[kind] == nil }

    /// Fills the template. `item` is the one thing the request is about.
    public func render(_ kind: PromptKind, map: String, context: String, nodes: [String], item: String) -> String {
        template(for: kind)
            .replacingOccurrences(of: "{map}", with: map.isEmpty ? "(empty)" : map)
            .replacingOccurrences(of: "{context}", with: context.isEmpty ? "(empty)" : context)
            .replacingOccurrences(of: "{nodes}", with: nodes.isEmpty ? "(none)" : nodes.joined(separator: ", "))
            .replacingOccurrences(of: "{item}", with: item)
    }

    static let rules = """
    Rules for names: lowercase, singular, no articles; the shortest noun phrase that is still unique in the text; a person by first name unless two share it; a place by its common name; an action is the base verb (review, not reviewing). Reuse a name from the node list exactly when it is the same thing. Never write name@scope.
    Line forms:
    | name                      declare a node
    | name - verb | name        a link with a short label, four words or fewer
    | name @kind person         kinds: person, place, thing, action, event, idea
    | old = new                 two names that clearly mean one thing
    """

    public static func defaultTemplate(for kind: PromptKind) -> String {
        switch kind {
        case .extract:
            return """
            You turn text into a mind map written in a line notation. Output ONLY the new lines to append, one per line, nothing else.
            \(rules)
            Nodes are people, places, things, actions, events and ideas actually named in the text. One line per fact. Edges read as a short phrasal verb left to right.
            Everything comes from the text: write @src text on every line, and end each line with @s n naming the sentence number it came from. Do not invent.
            Do not rename or delete existing nodes unless two names clearly mean one thing; then write old = new.

            Example
            text:
            s1: I'm Sam. s2: I'm writing a paper, Ana reviews it on Nov 3.
            output:
            | sam @kind person @src text @s 1
            | paper @kind thing @src text @s 2
            | sam - writes | paper @src text @s 2
            | ana @kind person @src text @s 2
            | ana - reviews | paper @src text @s 2
            | paper @date 2026-11-03 @src text @s 2

            The same sentence always gives the same lines:
            text:
            s1: I'm writing a paper, Ana reviews it on Nov 3.
            output:
            | paper @kind thing @src text @s 1
            | ana @kind person @src text @s 1
            | ana - reviews | paper @src text @s 1

            Existing nodes: {nodes}
            Map:
            {map}
            Context:
            {context}
            New text to extract:
            {item}
            output:
            """
        case .expand:
            return """
            You add detail about one node of a mind map written in a line notation. Output ONLY new lines to append, at most 8, one per line, nothing else.
            \(rules)
            Mark each line with its source: @src text when the context states it (then also @s n for the sentence), @src world for general knowledge, @src guess when unsure, @src advice for something the user should do, consider or avoid. If unsure, @src guess. Advice is never stated as a fact about the text.
            Links between two existing nodes are allowed when the text supports them.

            Existing nodes: {nodes}
            Map:
            {map}
            Context:
            {context}
            Expand this node (its one-hop neighbourhood follows):
            {item}
            output:
            """
        case .chat:
            return """
            You answer a question about a mind map and the text behind it. Answer in plain prose, briefly. If the answer adds facts worth keeping on the map, put them after the prose in one ```mm block, one line each, marked @src world or @src advice (or @src text with @s n when the context states it).
            \(rules)

            Existing nodes: {nodes}
            Map:
            {map}
            Context:
            {context}
            Message:
            {item}
            """
        case .clarify:
            return """
            You read a context and ask the questions whose answers would make a mind map of it precise: who is speaking, who a pronoun refers to, where and when something happened, what an abbreviation means. Ask at most 5. Output ONLY questions, one per line, in this form:
            s<sentence number> [<reason>] <question>
            Reasons: speaker, pronoun, place, time, abbreviation, other.

            Example
            context:
            s1 (Speaker 1): He said the paper is late.
            output:
            s1 [speaker] Who is Speaker 1?
            s1 [pronoun] Who is "he"?

            Map:
            {map}
            Context:
            {context}
            output:
            """
        case .dedupe:
            return """
            You find nodes in a mind map that are the same thing under two names (the same person, place, thing, action, event or idea). Output ONLY merge lines, each followed by a one-line reason as a comment, nothing else:
            | old = new
            reason
            Keep the shorter or more common name. If nothing looks the same, output nothing.

            Example
            nodes: dr. ana (person, degree 2), ana (person, degree 5), paper (thing, degree 4)
            output:
            | dr. ana = ana
            both are the person reviewing the paper

            Nodes with their notes and degree:
            {item}
            Map:
            {map}
            output:
            """
        case .verify:
            return """
            You check a text against a mind map. For each sentence that states a fact the map lacks, output the sentence number on its own line, then the lines that would add it (same notation as the map; every line @src text). Then, for each node marked @src text that you cannot find in the context, output: missing: <name>. Output nothing else.
            \(rules)

            Example
            output:
            s4
            | ana - reviews | paper @src text @s 4
            missing: dragon

            Existing nodes: {nodes}
            Map:
            {map}
            Context:
            {context}
            output:
            """
        }
    }
}

/// Renders the evidence store as the numbered context the prompts expect.
public enum ContextRenderer {
    public static func numbered(_ evidence: EvidenceStore, texts: [Int]? = nil) -> String {
        var out: [String] = []
        var currentText: Int?
        for sentence in evidence.sentences where texts?.contains(sentence.text) ?? true {
            if sentence.text != currentText {
                out.append("[text \(sentence.text)]")
                currentText = sentence.text
            }
            let speaker = sentence.speaker.map { " (\($0))" } ?? ""
            out.append("s\(sentence.s)\(speaker): \(sentence.sentence)")
        }
        return out.joined(separator: "\n")
    }

    /// One sentence, as the sentence-at-a-time mode shows it.
    public static func single(_ sentence: Sentence) -> String {
        let speaker = sentence.speaker.map { " (\($0))" } ?? ""
        return "s\(sentence.s)\(speaker): \(sentence.sentence)"
    }
}

/// Output of the Clarify prompt: `s12 [pronoun] Who is "he"?`
public struct ClarifyQuestion: Equatable, Sendable, Codable {
    public var sentence: Int
    public var reason: String
    public var question: String

    public init(sentence: Int, reason: String, question: String) {
        self.sentence = sentence
        self.reason = reason
        self.question = question
    }

    public static func parse(_ output: String, limit: Int = 5) -> [ClarifyQuestion] {
        var out: [ClarifyQuestion] = []
        for raw in output.split(separator: "\n") {
            let line = Text.collapse(raw)
            guard line.hasPrefix("s"), let space = line.firstIndex(of: " "), let n = Int(line[line.index(after: line.startIndex)..<space]) else { continue }
            var rest = Text.collapse(line[space...])
            var reason = "other"
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                reason = Text.collapse(rest[rest.index(after: rest.startIndex)..<close]).lowercased()
                rest = Text.collapse(rest[rest.index(after: close)...])
            }
            guard !rest.isEmpty else { continue }
            out.append(ClarifyQuestion(sentence: n, reason: reason, question: rest))
            if out.count == limit { break }
        }
        return out
    }
}

/// Output of the Verify prompt: proposals per sentence, plus `text` nodes the model could not find.
public struct VerifyReport: Equatable, Sendable {
    public struct Proposal: Equatable, Sendable {
        public var sentence: Int
        public var lines: [String]
    }

    public var proposals: [Proposal] = []
    public var missingNodes: [String] = []

    public static func parse(_ output: String) -> VerifyReport {
        var report = VerifyReport()
        for raw in output.split(separator: "\n") {
            let line = Text.collapse(raw)
            if line.hasPrefix("s"), let n = Int(line.dropFirst()) {
                report.proposals.append(Proposal(sentence: n, lines: []))
            } else if line.lowercased().hasPrefix("missing:") {
                let name = Canonicaliser.canonical(String(line.dropFirst("missing:".count)))
                if !name.isEmpty { report.missingNodes.append(name) }
            } else if line.hasPrefix("|") {
                if report.proposals.isEmpty { report.proposals.append(Proposal(sentence: 0, lines: [])) }
                report.proposals[report.proposals.count - 1].lines.append(line)
            }
        }
        report.proposals.removeAll { $0.lines.isEmpty }
        return report
    }
}

/// A chat reply: prose plus an optional ```mm block of lines to apply.
public struct ChatReply: Equatable, Sendable {
    public var prose: String
    public var lines: [String]

    public static func parse(_ output: String) -> ChatReply {
        var prose: [String] = []
        var lines: [String] = []
        var inBlock = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inBlock = !inBlock && line.lowercased().hasPrefix("```mm")
                continue
            }
            if inBlock { if line.hasPrefix("|") { lines.append(line) } } else { prose.append(String(raw)) }
        }
        return ChatReply(prose: prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), lines: lines)
    }
}
