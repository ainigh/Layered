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
    /// The “what was held back” drawer for the last model turn.
    public var heldBack: [GateEvent] = []
    /// Over-budget model lines the user can apply by hand.
    public var suggestions: [[String]] = []
    /// Lines the reducer could not apply (should not happen for harness-made lines).
    public var errors: [String] = []

    public init() {}

    /// Opens a map: compiles the log from scratch.
    public init(log: String, evidence: EvidenceStore = EvidenceStore()) throws {
        self.evidence = evidence
        let parser = Parser(options: .base)
        for parsed in try parser.parse(log) {
            try graph.apply(parsed)
            self.log.append(parsed.raw)
            if case .comment(let text) = parsed.line, text.hasPrefix("@turn ") {
                let fields = text.split(separator: " ")
                if fields.count >= 2, let n = Int(fields[1]) {
                    turns.append(Turn(number: n, date: Date(timeIntervalSince1970: 0), who: fields.count > 3 ? String(fields[3]) : "", what: fields.dropFirst(4).joined(separator: " "), lines: []))
                }
            } else if !turns.isEmpty {
                turns[turns.count - 1].lines.append(parsed.raw)
            }
        }
    }

    /// The log as it is written to `map.mm`.
    public var logText: String { log.isEmpty ? "" : log.joined(separator: "\n") + "\n" }

    public var canonical: String { Canonical.render(graph) }

    // MARK: - Appending

    /// Appends a turn: the header, then each line, compiling as it goes. Lines that
    /// fail to compile are reported in `errors` and not appended.
    mutating func appendTurn(who: String, what: String, lines: [String], now: Date) {
        guard !lines.isEmpty else { return }
        let parser = Parser(options: .base)
        var turn = Turn(number: turns.count + 1, date: now, who: who, what: what, lines: [])
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
    }
}

/// Every behaviour of the app is `MapState` + `Action` → `MapState`.
public enum Action: Equatable, Sendable {
    /// Record a submitted text in the evidence store (numbering sentences).
    case submitText(String)
    /// Run model output through the gate and append what passes.
    case applyModelOutput(String, prompt: PromptKind, textID: Int?, about: String)
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
}

public func reduce(_ state: MapState, _ action: Action, now: Date) -> MapState {
    var state = state
    switch action {
    case .submitText(let text):
        let (id, _) = state.evidence.appendText(text)
        state.texts[id] = text

    case .applyModelOutput(let output, let prompt, let textID, let about):
        let result = Gate.run(output, graph: state.graph, evidence: state.evidence, options: GateOptions(prompt: prompt, textID: textID))
        state.heldBack = result.events
        state.suggestions = result.deferred
        state.appendTurn(who: "model", what: "\(prompt.rawValue) \(about)", lines: result.lines, now: now)

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
