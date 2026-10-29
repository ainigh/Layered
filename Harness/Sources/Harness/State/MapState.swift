import Foundation

/// A turn: a `@turn` header comment plus the lines appended in it (SPEC “Editing, history”).
public struct Turn: Equatable, Sendable {
    public var number: Int
    public var date: Date
    public var who: String
    public var what: String
    public var lines: [String]

    public var header: String {
        "@turn \(number) \(Turn.format(date)) \(who) \(what)"
    }

    /// `undo 12` / `redo 12` turns reverse or restore another turn.
    public var undoes: Int? { Turn.reference("undo", in: what) }
    public var redoes: Int? { Turn.reference("redo", in: what) }

    static func reference(_ verb: String, in what: String) -> Int? {
        let parts = what.split(separator: " ")
        guard parts.count == 2, parts[0] == verb else { return nil }
        return Int(parts[1])
    }

    /// Parses a header comment back into a turn.
    public static func parse(header: String) -> Turn? {
        let fields = header.split(separator: " ", maxSplits: 4).map(String.init)
        guard fields.count >= 2, fields[0] == "@turn", let n = Int(fields[1]) else { return nil }
        let date = fields.count > 2 ? ISO8601DateFormatter().date(from: fields[2]) ?? Date(timeIntervalSince1970: 0) : Date(timeIntervalSince1970: 0)
        return Turn(number: n, date: date, who: fields.count > 3 ? fields[3] : "", what: fields.count > 4 ? fields[4] : "", lines: [])
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// The whole state of one map. Views render it; actions reduce it. The log is
/// append-only: `log` has no setter and only ever grows.
public struct MapState: Equatable, Sendable {
    public private(set) var log: [String] = []
    public private(set) var graph = Graph()
    public var evidence = EvidenceStore()
    public private(set) var turns: [Turn] = []
    /// Texts submitted so far, by id: the verbatim source (`texts/n.txt`).
    public var texts: [Int: String] = [:]
    /// The append-only context (`context.md`).
    public var context = ContextDocument()
    /// Transcripts by text id, kept verbatim.
    public var transcripts: [Int: Transcript] = [:]
    /// The “what was held back” drawer for the last model turn.
    public var heldBack: [GateEvent] = []
    /// Over-budget model lines the user can apply by hand.
    public var suggestions: [[String]] = []
    /// Lines the reducer could not apply (should not happen for harness-made lines).
    public var errors: [String] = []
    /// The last model run: raw output, token use, whether the grammar was used.
    public var lastRun: ModelRun?
    /// Canonical form after each turn; `snapshots[0]` is the empty map.
    public private(set) var snapshots: [Int: String] = [0: ""]
    /// Turn numbers that can be undone (latest last) and redone.
    public private(set) var undoable: [Int] = []
    public private(set) var redoable: [Int] = []
    /// Turn numbers already in the log before an Optimize in this session, so numbering continues.
    private var turnBase = 0

    public init() {}

    /// Opens a map: compiles the log from scratch.
    public init(log: String, evidence: EvidenceStore = EvidenceStore()) throws {
        self.evidence = evidence
        let parser = Parser(options: .base)
        var graphBefore = graph
        for parsed in try parser.parse(log) {
            try graph.apply(parsed)
            self.log.append(parsed.raw)
            if case .comment(let text) = parsed.line, let turn = Turn.parse(header: text) {
                if let last = turns.last { snapshots[last.number] = Canonical.render(graphBefore) }
                turns.append(turn)
                recordStacks(turn)
            } else if !turns.isEmpty {
                turns[turns.count - 1].lines.append(parsed.raw)
            }
            graphBefore = graph
        }
        if let last = turns.last { snapshots[last.number] = Canonical.render(graph) }
        if turns.isEmpty, !log.isEmpty { snapshots[0] = Canonical.render(graph) }
        turnBase = turns.last?.number ?? 0
    }

    private mutating func recordStacks(_ turn: Turn) {
        if let n = turn.undoes {
            undoable.removeAll { $0 == n }
            redoable.append(n)
        } else if let n = turn.redoes {
            redoable.removeAll { $0 == n }
            undoable.append(n)
        } else {
            undoable.append(turn.number)
            redoable = []
        }
    }

    /// The map as it stood after a turn (read-only view for the History panel).
    public func graph(atTurn n: Int) -> Graph? {
        guard let snapshot = snapshots[n] else { return nil }
        return try? Compiler.compile(snapshot)
    }

    /// Size of the log and of its canonical form, for the History panel.
    public var logSize: (lines: Int, bytes: Int) { (log.count, logText.utf8.count) }
    public var canonicalSize: (lines: Int, bytes: Int) { let c = canonical; return (c.split(separator: "\n").count, c.utf8.count) }

    /// Optimize (SPEC): the canonical form becomes the log. Turns and snapshots stay in
    /// memory so undo keeps working in this session; the caller archives the old log.
    public func optimized() -> MapState {
        var next = self
        next.log = Canonical.lines(for: graph)
        next.turnBase = turns.last?.number ?? 0
        next.turns = []
        return next
    }

    /// Branch from a turn: the state as it was after turn `n`. Later turns go to the archive.
    public func branched(atTurn n: Int) -> (state: MapState, archived: [String])? {
        guard let cut = log.firstIndex(where: { Turn.parse(header: $0)?.number == n + 1 }) ?? (turns.last?.number == n ? log.count : nil) else { return nil }
        var next = (try? MapState(log: Array(log[..<cut]).joined(separator: "\n"), evidence: evidence)) ?? MapState()
        next.evidence = evidence
        next.texts = texts
        next.context = context
        next.transcripts = transcripts
        return (next, Array(log[cut...]))
    }

    /// The log as it is written to `map.mm`.
    public var logText: String { log.isEmpty ? "" : log.joined(separator: "\n") + "\n" }

    public var canonical: String { Canonical.render(graph) }

    /// Speaker labels → names, from clarification answers.
    public var speakers: SpeakerMap { SpeakerMap(context: context) }

    /// Aliases for the gate's proof check.
    public var aliases: [String: [String]] { speakers.aliases }

    /// The texts a model request reads: the selected context items. `nil` (every text) for
    /// a state with no context, as tests and imported evidence have.
    public var modelTexts: [Int]? {
        context.paragraphs.isEmpty ? nil : context.selectedTexts
    }

    /// The evidence the gate may cite as proof: everything but the model's own replies, so
    /// a reply the user selected can inform a request but never make a line `src text`.
    public var proofEvidence: EvidenceStore {
        let replies = context.replyTexts
        guard !replies.isEmpty else { return evidence }
        var store = EvidenceStore()
        for s in evidence.sentences where !replies.contains(s.text) { store.append(s) }
        return store
    }

    // MARK: - Appending

    /// Appends a turn: the header, then each line, compiling as it goes. Lines that
    /// fail to compile are reported in `errors` and not appended.
    mutating func appendTurn(who: String, what: String, lines: [String], now: Date) {
        guard !lines.isEmpty else { return }
        let parser = Parser(options: .base)
        var turn = Turn(number: max(turnBase, turns.last?.number ?? 0) + 1, date: now, who: who, what: what, lines: [])
        var applied: [String] = []
        var scratch = graph
        for line in lines {
            do {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                try scratch.apply(try parser.parseLine(trimmed))
                applied.append(trimmed)
            } catch {
                errors.append("\(error): \(line)")
            }
        }
        guard !applied.isEmpty else { return }
        // Replay on the real graph so the header comment is in the right place.
        try? graph.apply(.comment(turn.header))
        for line in applied { try? graph.apply(try parser.parseLine(line)) }
        turn.lines = applied
        log.append(turn.header)
        log += applied
        turns.append(turn)
        snapshots[turn.number] = canonical
        recordStacks(turn)
    }

    /// A new context item: its text in the evidence store under a new text id, then in the context.
    mutating func addItem(_ text: String, kind: ContextParagraph.Kind, question: String? = nil, now: Date) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let (id, _) = evidence.appendText(body)
        texts[id] = body
        context.append(ContextParagraph(kind: kind, item: context.nextItemID, textID: id, question: question.flatMap { $0.isEmpty ? nil : $0 }, date: now, body: body))
    }

    /// An undo or redo that would change nothing still moves the turn between the stacks.
    mutating func skipUndo(_ n: Int) { undoable.removeAll { $0 == n }; redoable.append(n) }
    mutating func skipRedo(_ n: Int) { redoable.removeAll { $0 == n }; undoable.append(n) }

    func snapshotGraph(_ n: Int) -> Graph? {
        snapshots[n].flatMap { try? Compiler.compile($0) }
    }
}

/// Every behaviour of the app is `MapState` + `Action` → `MapState`.
public enum Action: Equatable, Sendable {
    /// Add a context item: the text joins the context (selected) and the evidence store under
    /// a new text id. Nothing reaches the map until Submit extracts it.
    case submitText(String, kind: ContextParagraph.Kind = .pasted)
    /// A transcript lands in the context as an item, with timestamps and speakers, and in the evidence store with times.
    case submitTranscript(Transcript)
    /// The prose of a model reply becomes an item of its own, marked as the model's and not
    /// selected until the user selects it.
    case addReply(String, question: String)
    /// Edit an item: its new text is a new revision (a new text id); the old one stays on
    /// disk and in the evidence store. Text from audio cannot be edited. Editing a model
    /// reply makes it the user's.
    case reviseContext(Int, String)
    /// Put an item in the current context, or take it out.
    case selectContext(Int, Bool)
    /// Delete an item from the list. It stays in `context.md` and can be restored; its ideas stay on the map.
    case removeContext(Int)
    case restoreContext(Int)
    /// A text went through Extract: its item is on the map.
    case markExtracted(textID: Int)
    /// Answer a Clarify question: appended to the context as a `[clarification]` paragraph.
    case answer(ClarifyQuestion?, String)
    /// Map a speaker label to a name: `Speaker 1 is Ana`, appended as a clarification.
    case nameSpeaker(label: String, name: String)
    /// Run model output through the gate and append what passes.
    case applyModelOutput(String, prompt: PromptKind, textID: Int?, about: String)
    /// Append what a finished `ModelRun` produced (the gate already ran while streaming).
    case applyRun(ModelRun, about: String)
    /// Append lines the user chose (a suggestion, an applied Verify proposal, an imported `.mm`).
    case applyLines([String], what: String)
    case rename(String, to: String)
    case delete(String)
    /// `world`/`guess`/`advice` → `user`.
    case confirm(String)
    case comment(on: String, String)
    case addEdge(from: String, label: String?, to: String)
    case pin(String, x: Double, y: Double)
    case release(String)
    /// Reverse the latest turn by appending its inverse (never by deleting).
    case undo
    case redo
    /// Confirm a Dedupe proposal: `old = new`.
    case merge(DedupeProposal)
    /// Forget source n: delete nodes whose only support was text n.
    case forgetText(Int)
}

public func reduce(_ state: MapState, _ action: Action, now: Date) -> MapState {
    var state = state
    switch action {
    case .submitText(let text, let kind):
        state.addItem(text, kind: kind, now: now)

    case .submitTranscript(let transcript):
        let id = state.evidence.nextTextID
        let sentences = transcript.sentences(textID: id)
        guard !sentences.isEmpty else { break }
        for s in sentences { state.evidence.append(s) }
        state.texts[id] = transcript.rendered
        state.transcripts[id] = transcript
        state.context.append(ContextParagraph(kind: .transcript, item: state.context.nextItemID, textID: id, date: now, body: transcript.rendered))

    case .addReply(let text, let question):
        state.addItem(text, kind: .model, question: Text.collapse(question), now: now)

    case .reviseContext(let n, let text):
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = state.context.item(n), item.isEditable, !item.removed, !body.isEmpty, body != item.body else { break }
        let (id, _) = state.evidence.appendText(body)
        state.texts[id] = body
        let kind: ContextParagraph.Kind = item.kind == .model ? .typed : item.kind
        state.context.append(ContextParagraph(kind: kind, item: n, textID: id, question: item.question, date: now, body: body))
        if item.kind == .model, !item.selected { state.context.append(ContextParagraph(kind: kind, item: n, event: .selected, date: now, body: "")) }

    case .selectContext(let n, let on):
        guard let item = state.context.item(n), item.selected != on else { break }
        state.context.append(ContextParagraph(kind: item.kind, item: n, event: on ? .selected : .deselected, date: now, body: ""))

    case .removeContext(let n):
        guard let item = state.context.item(n), !item.removed else { break }
        state.context.append(ContextParagraph(kind: item.kind, item: n, event: .removed, date: now, body: ""))

    case .restoreContext(let n):
        guard let item = state.context.item(n), item.removed else { break }
        state.context.append(ContextParagraph(kind: item.kind, item: n, event: .restored, date: now, body: ""))

    case .markExtracted(let textID):
        guard let item = state.context.item(forText: textID), !item.extracted.contains(textID) else { break }
        state.context.append(ContextParagraph(kind: item.kind, item: item.id, textID: textID, event: .extracted, date: now, body: ""))

    case .answer(let question, let answer):
        let body = Text.collapse(answer)
        guard !body.isEmpty else { break }
        let full = question.map { "\(body) (s\($0.sentence): \($0.question))" } ?? body
        state.addItem(full, kind: .clarification, now: now)

    case .nameSpeaker(let label, let name):
        let canon = Canonicaliser.canonical(name)
        guard !canon.isEmpty, Int(label.lowercased().replacingOccurrences(of: "speaker ", with: "")) != nil else { break }
        state.addItem(SpeakerMap.clarification(label: label, name: canon), kind: .clarification, now: now)

    case .applyModelOutput(let output, let prompt, let textID, let about):
        let result = Gate.run(output, graph: state.graph, evidence: state.proofEvidence, options: GateOptions(prompt: prompt, textID: textID, aliases: state.aliases))
        state.heldBack = result.events
        state.suggestions = result.deferred
        state.appendTurn(who: "model", what: "\(prompt.rawValue) \(about)", lines: result.lines, now: now)

    case .applyRun(let run, let about):
        state.heldBack = run.gate.events
        state.suggestions = run.gate.deferred
        state.lastRun = run
        state.appendTurn(who: "model", what: "\(run.kind.rawValue) \(about)", lines: run.gate.lines, now: now)

    case .applyLines(let lines, let what):
        state.appendTurn(who: "user", what: what, lines: lines, now: now)

    case .rename(let old, let new):
        let target = Canonicaliser.canonical(new)
        guard !target.isEmpty, target != old else { break }
        state.appendTurn(who: "user", what: "rename \(old)", lines: [Render.edit(Edit(old: Name(old), new: Name(target)))], now: now)

    case .delete(let name):
        state.appendTurn(who: "user", what: "delete \(name)", lines: [Render.edit(Edit(old: Name(name), new: nil))], now: now)

    case .confirm(let name):
        guard state.graph.node(name) != nil else { break }
        state.appendTurn(who: "user", what: "confirm \(name)", lines: ["| \(name) @src user"], now: now)

    case .comment(let name, let text):
        guard state.graph.node(name) != nil, !Text.collapse(text).isEmpty else { break }
        // A comment cannot start with `|` (that would make it a statement).
        let body = Text.collapse(Text.collapse(text).drop { $0 == "|" })
        guard !body.isEmpty else { break }
        state.appendTurn(who: "user", what: "comment \(name)", lines: ["| \(name)", body], now: now)

    case .addEdge(let from, let label, let to):
        let a = Canonicaliser.canonical(from), b = Canonicaliser.canonical(to)
        guard !a.isEmpty, !b.isEmpty else { break }
        var lines: [String] = []
        for name in [a, b] where state.graph.node(name) == nil { lines.append("| \(name) @src user") }
        let labels = [label.map(Text.collapse) ?? ""].filter { !$0.isEmpty }
        let link = Link(labels: labels, notes: ["src user"], directed: true)
        lines.append(Render.path(Path(names: [Name(a), Name(b)], links: [link])))
        state.appendTurn(who: "user", what: "link \(a) \(b)", lines: lines, now: now)

    case .pin(let name, let x, let y):
        guard state.graph.node(name) != nil else { break }
        state.appendTurn(who: "user", what: "move \(name)", lines: ["| \(name) @pos \(Position(x: x, y: y).noteValue)"], now: now)

    case .release(let name):
        guard state.graph.node(name)?.note(kind: "pos") != nil else { break }
        state.appendTurn(who: "user", what: "release \(name)", lines: ["| \(name) @pos auto"], now: now)

    case .undo:
        guard let n = state.undoable.last, let target = state.snapshotGraph(n - 1) else { break }
        let lines = Transition.lines(from: state.graph, to: target)
        guard !lines.isEmpty else { state.skipUndo(n); break }
        state.appendTurn(who: "user", what: "undo \(n)", lines: lines, now: now)

    case .redo:
        guard let n = state.redoable.last, let target = state.snapshotGraph(n) else { break }
        let lines = Transition.lines(from: state.graph, to: target)
        guard !lines.isEmpty else { state.skipRedo(n); break }
        state.appendTurn(who: "user", what: "redo \(n)", lines: lines, now: now)

    case .merge(let proposal):
        guard state.graph.node(proposal.old) != nil, proposal.old != proposal.new else { break }
        var lines = [Render.edit(Edit(old: Name(proposal.old), new: Name(proposal.new)))]
        if !proposal.reason.isEmpty { lines.append(proposal.reason) }
        state.appendTurn(who: "user", what: "merge \(proposal.old)", lines: lines, now: now)

    case .forgetText(let n):
        let doomed = state.graph.nodes.keys.filter { $0.scope.isEmpty && Coverage.supports(of: $0, in: state.graph) == [n] }.sorted()
        guard !doomed.isEmpty else { break }
        state.appendTurn(who: "user", what: "forget text \(n)", lines: doomed.map { "| \($0.name) =" }, now: now)
    }
    return state
}

/// A pinned canvas position. Written as `@pos 120,-340`: the comma keeps a negative
/// coordinate from reading as an active `-` symbol (notation §2).
public struct Position: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init?(noteValue: String) {
        let parts = noteValue.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0].trimmingCharacters(in: .whitespaces)), let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        self.init(x: x, y: y)
    }

    public var noteValue: String { "\(Position.plain(x)),\(Position.plain(y))" }

    static func plain(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
