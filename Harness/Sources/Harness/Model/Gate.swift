/// The gate checks every model line before it reaches the log (SPEC “Checks before
/// append”): parse, names, proof, duplicates, provenance, budget. Nothing is silently
/// altered: every change or drop is reported as a `GateEvent`.
public enum PromptKind: String, Sendable, CaseIterable, Codable {
    case clarify, extract, expand, chat, dedupe, verify
}

/// The closed provenance set. Anything else becomes `guess`.
public enum Provenance: String, Sendable, CaseIterable, Codable {
    case text, world, guess, advice, user
}

public struct GateOptions: Sendable {
    public var prompt: PromptKind
    /// The text the model was reading, so `@s n` resolves to `@text id sn`.
    public var textID: Int?
    /// Aliases from clarification: node name → other strings that name it in the text.
    public var aliases: [String: [String]]
    /// Appends per call; `nil` means unlimited.
    public var budget: Int?
    /// Edge labels longer than this are trimmed (SPEC: four words or fewer).
    public var labelWordCap: Int
    /// Append a line even when the map already says it (the log allows repeats).
    public var keepDuplicates: Bool

    public init(prompt: PromptKind, textID: Int? = nil, aliases: [String: [String]] = [:], budget: Int?? = nil, labelWordCap: Int = 4, keepDuplicates: Bool = false) {
        self.prompt = prompt
        self.textID = textID
        self.aliases = aliases
        self.budget = budget ?? GateOptions.defaultBudget(for: prompt)
        self.labelWordCap = labelWordCap
        self.keepDuplicates = keepDuplicates
    }

    /// Everything that passes the checks goes on the map, repeats and all, with no budget:
    /// the user reviews the model's additions on the map itself (`Review`).
    public static func appendAll(prompt: PromptKind, textID: Int? = nil, aliases: [String: [String]] = [:]) -> GateOptions {
        GateOptions(prompt: prompt, textID: textID, aliases: aliases, budget: .some(nil), keepDuplicates: true)
    }

    public static func defaultBudget(for prompt: PromptKind) -> Int? {
        switch prompt {
        case .expand, .chat: return 8
        default: return nil
        }
    }
}

/// One entry in the “what was held back” drawer.
public struct GateEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// The line was not appended.
        case dropped
        /// The line was appended in a different form (`result`).
        case rewritten
        /// The line was valid but over budget; it is offered as a suggestion.
        case deferred
    }

    public var kind: Kind
    public var raw: String
    public var result: [String]
    public var reason: String

    public init(kind: Kind, raw: String, result: [String] = [], reason: String) {
        self.kind = kind
        self.raw = raw
        self.result = result
        self.reason = reason
    }
}

public struct GateResult: Equatable, Sendable {
    /// Lines to append, in order.
    public var lines: [String] = []
    /// Valid lines over budget, in order: the “more suggestions” list.
    public var deferred: [[String]] = []
    /// Everything changed, dropped or deferred.
    public var events: [GateEvent] = []
    /// Lines that failed to parse, with the error text to send back once (SPEC check 1).
    public var parseErrors: [(line: String, error: String)] { parseFailures }
    var parseFailures: [(line: String, error: String)] = []

    public static func == (lhs: GateResult, rhs: GateResult) -> Bool {
        lhs.lines == rhs.lines && lhs.deferred == rhs.deferred && lhs.events == rhs.events
    }
}

public struct Gate: Sendable {
    public var options: GateOptions

    public init(options: GateOptions) {
        self.options = options
    }

    public static func run(_ output: String, graph: Graph, evidence: EvidenceStore, options: GateOptions) -> GateResult {
        Gate(options: options).run(output, graph: graph, evidence: evidence)
    }

    public func run(_ output: String, graph: Graph, evidence: EvidenceStore) -> GateResult {
        var session = GateSession(gate: self, graph: graph, evidence: evidence)
        for (number, text) in Text.numberedLines(output) where !text.isEmpty {
            session.feed(text, number: number)
        }
        return session.result
    }

    // MARK: - Edits

    func gateEdit(_ edit: Edit, known: Set<String>, reasons: inout [String]) -> [String]? {
        guard let new = edit.new else {
            reasons.append("deleting is a user action; the model may only merge with `old = new`")
            return nil
        }
        let old = Canonicaliser.resolve(edit.old.text, among: known)
        guard old.existing else {
            reasons.append("`\(edit.old.text)` is not a node in the map")
            return nil
        }
        let target = Canonicaliser.resolve(new.text, among: known)
        if let r = old.reason { reasons.append(r) }
        if let r = target.reason { reasons.append(r) }
        guard old.name != target.name else {
            reasons.append("`\(edit.old.text)` and `\(new.text)` are already the same node")
            return nil
        }
        return [Render.edit(Edit(old: Name(old.name), new: Name(target.name)))]
    }

    // MARK: - Paths

    func gatePath(_ input: Path, known: inout Set<String>, evidence: EvidenceStore, reasons: inout [String]) -> [String]? {
        var path = input

        // 2. Names.
        var newNames: [String] = []
        for index in path.names.indices {
            let resolution = Canonicaliser.resolve(path.names[index].text, among: known)
            if let reason = resolution.reason { reasons.append(reason) }
            path.names[index] = Name(resolution.name)
            if !resolution.existing, !newNames.contains(resolution.name) { newNames.append(resolution.name) }
        }
        for index in path.links.indices {
            path.links[index].labels = path.links[index].labels.map { label in
                let words = label.split(separator: " ")
                guard words.count > options.labelWordCap else { return label }
                let trimmed = words.prefix(options.labelWordCap).joined(separator: " ")
                reasons.append("label `\(label)` trimmed to \(options.labelWordCap) words")
                return trimmed
            }
        }

        // Pull the harness-owned notes out of wherever the model put them.
        var src: String?
        var cited: Int?
        for index in path.links.indices {
            src = takeNote(kind: "src", from: &path.links[index].notes) ?? src
            cited = takeSentence(from: &path.links[index].notes) ?? cited
            if takeNote(kind: "text", from: &path.links[index].notes) != nil { reasons.append("`@text` proof is written by the harness, not the model") }
        }
        src = takeNote(kind: "src", from: &path.notes) ?? src
        cited = takeSentence(from: &path.notes) ?? cited
        if takeNote(kind: "text", from: &path.notes) != nil { reasons.append("`@text` proof is written by the harness, not the model") }

        // 5. Provenance.
        var provenance: Provenance
        switch options.prompt {
        case .extract, .verify:
            if let src, src != Provenance.text.rawValue {
                reasons.append("Extract may only write `@src text`, not `@src \(src)`")
                return nil
            }
            if src == nil { reasons.append("added `@src text`") }
            provenance = .text
        default:
            if let src, let known = Provenance(rawValue: src), known != .user {
                provenance = known
            } else {
                reasons.append(src.map { "unknown provenance `\($0)` becomes `guess`" } ?? "missing `@src` becomes `guess`")
                provenance = .guess
            }
        }

        // 3. Proof. The sentence must name the nodes this line adds; a line between
        // existing nodes needs the sentence to name at least one of them.
        var proof: Sentence?
        if provenance == .text {
            let names = path.names.map(\.text)
            let required = newNames.isEmpty ? nil : newNames
            if let cited, let textID = options.textID, let sentence = evidence.sentence(text: textID, s: cited), supports(sentence, names: names, required: required) {
                proof = sentence
            } else {
                let candidates = options.textID.map { evidence.sentences(text: $0) } ?? evidence.sentences
                if let found = candidates.first(where: { supports($0, names: names, required: required) }) {
                    proof = found
                    reasons.append(cited == nil ? "found proof in \(found.proofNote)" : "sentence \(cited!) does not name \(describe(required ?? names)); using \(found.proofNote)")
                } else {
                    reasons.append("no sentence names \(describe(required ?? names)); downgraded to `guess`")
                    provenance = .guess
                }
            }
        }

        // Emit: provenance (and proof) on every edge of the line and on every new node.
        var tags = ["src \(provenance.rawValue)"]
        if let proof { tags.append(proof.proofNote) }

        var lines: [String] = []
        for name in newNames where path.links.count > 0 || name != path.names[0].text {
            lines.append(Render.path(Path(names: [Name(name)], notes: tags)))
            known.insert(name)
            reasons.append("declared new node `\(name)`")
        }
        if path.links.isEmpty {
            for tag in tags { NoteKind.add(tag, to: &path.notes, singleValued: Graph.appSingleValuedNoteKinds) }
            known.insert(path.names[0].text)
        } else {
            if src != nil { reasons.append("moved `@src` onto the edge") }
            for index in path.links.indices {
                for tag in tags { NoteKind.add(tag, to: &path.links[index].notes, singleValued: Graph.appSingleValuedNoteKinds) }
            }
        }
        lines.append(Render.path(path))
        return lines
    }

    private func takeNote(kind: String, from notes: inout [String]) -> String? {
        guard let index = notes.firstIndex(where: { NoteKind.split($0)?.kind == kind }) else { return nil }
        let value = NoteKind.split(notes.remove(at: index))!.value
        return Text.collapse(value).lowercased()
    }

    /// `@s 12` or `@s12` from Extract: the sentence number the line came from.
    private func takeSentence(from notes: inout [String]) -> Int? {
        for (index, note) in notes.enumerated() {
            let compact = note.replacingOccurrences(of: " ", with: "")
            if compact.hasPrefix("s"), let n = Int(compact.dropFirst()) {
                notes.remove(at: index)
                return n
            }
        }
        return nil
    }

    // MARK: - Proof matching

    /// `required` names must all appear; otherwise any one of `names` is enough.
    func supports(_ sentence: Sentence, names: [String], required: [String]?) -> Bool {
        if let required { return required.allSatisfy { mentions(sentence, $0) } }
        return names.contains { mentions(sentence, $0) }
    }

    func mentions(_ sentence: Sentence, _ name: String) -> Bool {
        let speaker = sentence.speaker.map { " " + Gate.matchable($0) } ?? ""
        let hay = " " + Gate.matchable(sentence.sentence) + speaker + " "
        return ([name] + (options.aliases[name] ?? [])).contains { candidate in
            let m = Gate.matchable(candidate)
            guard !m.isEmpty else { return false }
            var forms = [m, m + "s", m + "es", m + "ed", m + "ing", m + "d"]
            if m.hasSuffix("y") { forms.append(String(m.dropLast()) + "ies") }
            if m.hasSuffix("e") { forms.append(String(m.dropLast()) + "ing") }
            return forms.contains { hay.contains(" \($0) ") }
        }
    }

    private func describe(_ names: [String]) -> String {
        names.map { "`\($0)`" }.joined(separator: " and ")
    }

    static func matchable(_ s: String) -> String {
        Text.collapse(String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }))
    }
}

/// A gate that checks lines one at a time as they stream in from the model.
public struct GateSession: Sendable {
    public let gate: Gate
    public private(set) var result = GateResult()
    private var scratch: Graph
    private let evidence: EvidenceStore
    private var known: Set<String>
    private var appended = 0
    private let parser = Parser(options: .strict)

    public init(gate: Gate, graph: Graph, evidence: EvidenceStore) {
        self.gate = gate
        self.scratch = graph
        self.evidence = evidence
        self.known = Set(graph.rootNames)
    }

    /// The graph as it stands with every kept line applied.
    public var graph: Graph { scratch }

    /// Feeds one raw line. Returns the lines it produced (empty when held back).
    @discardableResult
    public mutating func feed(_ text: String, number: Int = 0) -> [String] {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let options = gate.options
        guard raw.hasPrefix("|") else {
            if raw.hasPrefix("```") { return [] }
            if options.prompt == .dedupe {
                result.lines.append(raw)
                return [raw]
            }
            result.events.append(GateEvent(kind: .dropped, raw: raw, reason: "not a statement"))
            return []
        }

        // 1. Parse (after the workflow's normalisation of `-|`).
        let normalised = raw.replacingOccurrences(of: " -|", with: " - |")
        let statement: Statement
        do {
            switch try parser.parseLine(normalised, number: number) {
            case .statement(let s): statement = s
            case .comment, .scope:
                result.events.append(GateEvent(kind: .dropped, raw: raw, reason: "the model may not change scopes"))
                return []
            }
        } catch let error as NotationError {
            result.events.append(GateEvent(kind: .dropped, raw: raw, reason: error.message))
            result.parseFailures.append((raw, error.description))
            return []
        } catch {
            result.events.append(GateEvent(kind: .dropped, raw: raw, reason: "\(error)"))
            return []
        }

        var reasons: [String] = []
        let emitted: [String]
        switch statement {
        case .edit(let edit):
            guard let lines = gate.gateEdit(edit, known: known, reasons: &reasons) else {
                result.events.append(GateEvent(kind: .dropped, raw: raw, reason: reasons.joined(separator: "; ")))
                return []
            }
            emitted = lines
        case .path(let path):
            guard options.prompt != .dedupe else {
                result.events.append(GateEvent(kind: .dropped, raw: raw, reason: "Dedupe may only propose `old = new` lines"))
                return []
            }
            var trialKnown = known
            guard let lines = gate.gatePath(path, known: &trialKnown, evidence: evidence, reasons: &reasons) else {
                result.events.append(GateEvent(kind: .dropped, raw: raw, reason: reasons.joined(separator: "; ")))
                return []
            }
            known = trialKnown
            emitted = lines
        }

        // 4. Duplicates: a line that adds nothing to the canonical form is dropped.
        var trial = scratch
        let before = Canonical.render(trial)
        do {
            for line in emitted { try trial.apply(try parser.parseLine(line)) }
        } catch {
            result.events.append(GateEvent(kind: .dropped, raw: raw, reason: "gate produced an invalid line: \(error)"))
            return []
        }
        if Canonical.render(trial) == before {
            if options.keepDuplicates {
                result.lines += emitted
                return emitted
            }
            result.events.append(GateEvent(kind: .dropped, raw: raw, reason: "already in the map"))
            return []
        }

        // 6. Budget.
        if let budget = options.budget, appended >= budget {
            result.deferred.append(emitted)
            result.events.append(GateEvent(kind: .deferred, raw: raw, result: emitted, reason: "over the budget of \(budget) lines per call"))
            return []
        }

        scratch = trial
        appended += 1
        result.lines += emitted
        if emitted != [raw] {
            result.events.append(GateEvent(kind: .rewritten, raw: raw, result: emitted, reason: reasons.isEmpty ? "normalised" : reasons.joined(separator: "; ")))
        }
        return emitted
    }
}
