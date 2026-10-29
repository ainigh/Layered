import Foundation

/// Model settings (SPEC “Connection”).
public struct ModelSettings: Equatable, Sendable, Codable {
    public var host: String
    public var model: String?
    public var temperature: Double
    public var contextSize: Int?
    public var useGrammar: Bool

    public init(host: String = "http://localhost:11434", model: String? = nil, temperature: Double = 0, contextSize: Int? = nil, useGrammar: Bool = true) {
        self.host = host
        self.model = model
        self.temperature = temperature
        self.contextSize = contextSize
        self.useGrammar = useGrammar
    }
}

/// What a run produced: the request, the raw output (the audit trail), the gate's verdicts and token use.
public struct ModelRun: Equatable, Sendable {
    public var kind: PromptKind
    public var request: ModelRequest
    public var rawOutput: String
    public var gate: GateResult
    public var promptTokens: Int?
    public var responseTokens: Int?
    public var grammarUsed: Bool
    public var retried: Bool
}

/// Events emitted while a run streams, so the UI can draw lines as they parse.
public enum RunEvent: Equatable, Sendable {
    case chunk(String)
    case kept([String])
    case heldBack(GateEvent)
    case done
}

/// Builds the stateless request for a prompt, streams the reply, feeds lines to the gate
/// as they arrive, and retries failed lines once with the parser's message (workflow step 7).
public struct ModelRunner: Sendable {
    public var client: any ModelClient
    public var settings: ModelSettings
    public var prompts: PromptSet

    public init(client: any ModelClient, settings: ModelSettings, prompts: PromptSet = PromptSet()) {
        self.client = client
        self.settings = settings
        self.prompts = prompts
    }

    /// The prompt text for a kind, without running it (shown in the Prompt panel, used by tests).
    /// The context is the selected items unless `texts` names others.
    public func prompt(_ kind: PromptKind, state: MapState, item: String, contextOnly: Bool = false, texts: [Int]? = nil) -> String {
        prompts.render(kind,
                       map: contextOnly ? "" : state.canonical,
                       context: ContextRenderer.numbered(state.evidence, texts: texts ?? state.modelTexts, replies: state.context.replyTexts),
                       nodes: state.graph.rootNames,
                       item: item)
    }

    public func run(_ kind: PromptKind, state: MapState, item: String, textID: Int? = nil, aliases: [String: [String]] = [:],
                    contextOnly: Bool = false, texts: [Int]? = nil,
                    onEvent: @Sendable (RunEvent) -> Void = { _ in }) async throws -> ModelRun {
        guard let model = settings.model else { throw ModelError.noModel }
        let usesNotation = kind != .clarify && kind != .chat
        let grammar = usesNotation && settings.useGrammar ? Grammar.build(nodes: state.graph.rootNames, allowEdits: kind == .dedupe || kind == .extract, allowComments: kind == .dedupe) : nil
        var request = ModelRequest(model: model, prompt: prompt(kind, state: state, item: item, contextOnly: contextOnly, texts: texts),
                                   grammar: grammar, temperature: settings.temperature, contextSize: settings.contextSize)

        var session = GateSession(gate: Gate(options: GateOptions(prompt: kind, textID: textID, aliases: aliases)), graph: state.graph, evidence: state.proofEvidence)
        var raw = ""
        var promptTokens: Int?
        var responseTokens: Int?
        var grammarUsed = grammar != nil

        func stream(_ req: ModelRequest) async throws {
            var lines = LineAccumulator()
            for try await chunk in client.generate(req) {
                raw += chunk.text
                onEvent(.chunk(chunk.text))
                if usesNotation {
                    for line in lines.feed(chunk.text) { feed(line) }
                }
                if chunk.done {
                    promptTokens = chunk.promptTokens ?? promptTokens
                    responseTokens = chunk.responseTokens ?? responseTokens
                }
            }
            // A stopped stream ends without an error: stop here, so nothing half-read is applied.
            try Task.checkCancellation()
            if usesNotation { for line in lines.flush() { feed(line) } }
        }

        func feed(_ line: String) {
            let before = session.result.events.count
            let kept = session.feed(line)
            if !kept.isEmpty { onEvent(.kept(kept)) }
            for event in session.result.events[before...] { onEvent(.heldBack(event)) }
        }

        do {
            try await stream(request)
        } catch ModelError.grammarRejected {
            request.grammar = nil
            grammarUsed = false
            raw = ""
            try await stream(request)
        }

        // Retry once: send each failing line back with its error, then give up on it.
        var retried = false
        let failures = session.result.parseErrors
        if usesNotation, !failures.isEmpty {
            retried = true
            let repair = failures.map { "\($0.error)\n\($0.line)" }.joined(separator: "\n")
            let repairPrompt = request.prompt + "\n\nThese lines did not parse. Rewrite each one correctly, one per line, nothing else:\n" + repair + "\noutput:\n"
            let repairRequest = ModelRequest(model: model, prompt: repairPrompt, grammar: request.grammar, temperature: request.temperature, contextSize: request.contextSize)
            raw += "\n"
            try? await stream(repairRequest)
            try Task.checkCancellation()
        }

        onEvent(.done)
        var result = session.result
        if retried { result.parseFailures = [] }
        return ModelRun(kind: kind, request: request, rawOutput: raw, gate: result, promptTokens: promptTokens, responseTokens: responseTokens, grammarUsed: grammarUsed, retried: retried)
    }

    // MARK: - Items for each prompt

    /// The one-hop neighbourhood of a node, as canonical lines, for Expand (the `mmq` query).
    public static func neighbourhood(of name: String, in graph: Graph) -> String {
        let id = NodeID(name: name)
        var sub = Graph()
        guard let node = graph.nodes[id] else { return "| \(name)" }
        sub.nodes[id] = node
        for edge in graph.edges(touching: id) {
            for end in [edge.a, edge.b] where sub.nodes[end] == nil { sub.nodes[end] = graph.nodes[end] }
            sub.edges[edge.key] = edge
        }
        return Canonical.render(sub)
    }

    /// Dedupe's input: every root node with its notes and degree.
    public static func nodeList(_ graph: Graph) -> String {
        graph.rootNames.map { name in
            let id = NodeID(name: name)
            let notes = graph.nodes[id]?.notes.joined(separator: ", ") ?? ""
            return "\(name) (\(notes.isEmpty ? "no notes" : notes); degree \(graph.degree(of: id)))"
        }.joined(separator: "\n")
    }
}
