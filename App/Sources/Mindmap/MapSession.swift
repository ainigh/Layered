import SwiftUI
import Harness

/// One open map. Holds the harness `MapState`, dispatches actions, persists what each
/// action appended, and runs model requests. Views read it and dispatch; no logic here
/// beyond wiring the harness to storage and the model.
@MainActor
@Observable
final class MapSession {
    enum Mode: Equatable { case demo(Demo.Map), folder(URL) }

    let mode: Mode
    private(set) var state: MapState
    private(set) var storage: any MapStorage
    var settings: Settings
    var prompts: PromptSet
    var ui: UIState
    var layout: Layout
    var icons = IconManifest()

    // Transient UI state (not persisted).
    var selection: Set<String> = []
    var selectedEdge: EdgeKey?
    var highlighted: [String: Date] = [:]
    var running: PromptKind?
    var runningTokens = 0
    var cancelRun: (() -> Void)?
    var lastError: (raw: String, message: String, retry: (() -> Void)?)?
    var pendingWrites: [String] = []
    var clarifyQuestions: [ClarifyQuestion] = []
    var clarifyContextOnly = false
    var chatLog: [(who: String, text: String)] = []
    var dedupeProposals: [DedupeProposal] = []
    var verifyReport: VerifyReport?
    var sentenceWalk: SentenceWalk?
    var transcribing: Double?
    var viewingTurn: Int?
    var contextDraft = ""
    var submittedDraft: String?

    let runnerClient: any ModelClient
    let transcriber: any Transcriber
    let diarizer: any Diarizer
    private var bookmark: Data?

    var coverage: Coverage { Coverage.compute(state) }
    var isDemo: Bool { if case .demo = mode { return true } else { return false } }

    var title: String {
        switch mode {
        case .demo(let map): return "Demo · \(map.rawValue)"
        case .folder(let url): return url.lastPathComponent
        }
    }

    /// The graph the canvas shows: the live one, or a read-only turn from History.
    var displayedGraph: Graph {
        if let t = viewingTurn, let g = state.graph(atTurn: t) { return g }
        return state.graph
    }

    // MARK: - Opening

    static func demo(_ map: Demo.Map) -> MapSession {
        MapSession(mode: .demo(map), state: Demo.state(map), storage: InMemoryStorage(), settings: Settings(), prompts: PromptSet(), ui: UIState(),
                   client: Demo.client(), transcriber: FixtureTranscriber(transcript: Transcript(segments: [])), diarizer: FixtureTranscriber(transcript: Transcript(segments: [])))
    }

    static func open(folder: URL) throws -> MapSession {
        let storage = try FolderStorage(root: folder)
        let loaded = try Persistence.load(storage)
        var settings = loaded.settings
        if settings.model.model == nil { settings.model.model = UserDefaults.standard.string(forKey: "lastModel") }
        let client = OllamaClient(host: URL(string: settings.model.host) ?? URL(string: "http://localhost:11434")!, sendGrammar: settings.model.useGrammar)
        let session = MapSession(mode: .folder(folder), state: loaded.state, storage: storage, settings: settings, prompts: loaded.prompts, ui: loaded.ui,
                                 client: client, transcriber: WhisperTranscriber(), diarizer: WhisperDiarizer())
        session.bookmark = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValues: nil, relativeTo: nil)
        if let data = try? storage.readIconManifest(), let manifest = try? IconManifest(json: data) { session.icons = manifest }
        RecentMaps.add(folder)
        return session
    }

    private init(mode: Mode, state: MapState, storage: any MapStorage, settings: Settings, prompts: PromptSet, ui: UIState,
                 client: any ModelClient, transcriber: any Transcriber, diarizer: any Diarizer) {
        self.mode = mode
        self.state = state
        self.storage = storage
        self.settings = settings
        self.prompts = prompts
        self.ui = ui
        self.runnerClient = client
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.layout = Layout.compute(state.graph, options: settings.layout)
        if settings.model.model == nil, case .demo = mode { self.settings.model.model = "demo" }
    }

    // MARK: - Dispatch

    func dispatch(_ action: Action) {
        let before = state
        var next = reduce(state, action, now: Date())
        if next == before { return }
        let added = Set(next.graph.nodes.keys.map(\.name)).subtracting(before.graph.nodes.keys.map(\.name))
        let changedEdges = Set(next.graph.edges.keys).subtracting(before.graph.edges.keys)
        for name in added { highlighted[name] = Date() }
        for key in changedEdges { highlighted[key.lo.name] = Date(); highlighted[key.hi.name] = Date() }
        next.errors.forEach { try? storage.appendErrorLog($0) }
        state = next
        pendingWrites = Persistence.sync(before: before, after: next, storage: storage)
        layout = Layout.compute(state.graph, options: settings.layout, iterations: 120, previous: layout)
        viewingTurn = nil
        if Persistence.optimizeDue(state, settings: settings) { optimize() }
    }

    func retryPendingWrites() {
        guard !pendingWrites.isEmpty else { return }
        pendingWrites = Persistence.sync(before: MapState(), after: state, storage: storage)
    }

    func optimize() {
        do {
            state = try Persistence.optimize(state, storage: storage, now: Date())
        } catch {
            try? storage.appendErrorLog("optimize: \(error)")
        }
    }

    func branch(atTurn n: Int) {
        if let next = try? Persistence.branch(state, atTurn: n, storage: storage, now: Date()) {
            state = next
            viewingTurn = nil
            layout = Layout.compute(state.graph, options: settings.layout, iterations: 120, previous: layout)
        }
    }

    func saveSettings() {
        try? storage.writeSettings(settings)
        if let m = settings.model.model { UserDefaults.standard.set(m, forKey: "lastModel") }
    }

    func saveUI() { try? storage.writeUIState(ui) }

    func savePrompt(_ kind: PromptKind, _ text: String?) {
        prompts.overrides[kind] = text
        try? storage.writePrompt(kind, text)
    }

    // MARK: - Context

    /// Saves the context draft as it is typed (nothing is sent until Submit).
    func saveDraft() {
        UserDefaults.standard.set(contextDraft, forKey: "draft:\(title)")
    }

    func submit(sentenceMode: Bool) {
        let changed = Submit.changedParagraphs(previous: submittedDraft, current: contextDraft)
        guard !changed.isEmpty else { return }
        submittedDraft = contextDraft
        for paragraph in changed {
            dispatch(.submitText(paragraph))
            let id = state.evidence.nextTextID - 1
            if sentenceMode {
                sentenceWalk = SentenceWalk(textID: id, sentences: state.evidence.sentences(text: id))
                Task { await walkSentences() }
            } else {
                Task { await run(.extract, item: paragraph, textID: id, about: "text \(id)") }
            }
        }
    }

    func walkSentences() async {
        while var walk = sentenceWalk, let sentence = walk.current, !walk.paused {
            await run(.extract, item: ContextRenderer.single(sentence), textID: walk.textID, about: "text \(walk.textID) s\(sentence.s)", texts: [walk.textID])
            walk.advance()
            sentenceWalk = walk.isFinished ? nil : walk
        }
    }

    func dropAudio(_ url: URL) {
        Task {
            transcribing = 0
            defer { transcribing = nil }
            do {
                let id = state.evidence.nextTextID
                let stored = try storage.storeAudio(id: id, from: url)
                var transcript = try await transcriber.transcribe(stored, model: settings.whisperModel) { [weak self] p in
                    Task { @MainActor in self?.transcribing = p }
                }
                transcript = (try? await diarizer.diarize(transcript, audio: stored)) ?? transcript
                dispatch(.submitTranscript(transcript))
                contextDraft += (contextDraft.isEmpty ? "" : "\n\n") + transcript.rendered
                submittedDraft = contextDraft
            } catch {
                lastError = (url.lastPathComponent, "\(error)", nil)
            }
        }
    }

    func audioURL(for textID: Int) -> URL? {
        guard case .folder(let root) = mode else { return nil }
        let dir = root.appendingPathComponent("audio")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix("\(textID).") && !$0.lastPathComponent.contains("transcript") }
    }

    // MARK: - Model

    private var runner: ModelRunner {
        ModelRunner(client: runnerClient, settings: settings.model, prompts: prompts)
    }

    @discardableResult
    func run(_ kind: PromptKind, item: String, textID: Int? = nil, about: String, contextOnly: Bool = false, texts: [Int]? = nil) async -> ModelRun? {
        running = kind
        runningTokens = 0
        lastError = nil
        let task = Task { [runner, state] in
            try await runner.run(kind, state: state, item: item, textID: textID, aliases: state.aliases, contextOnly: contextOnly, texts: texts) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    if case .chunk(let text) = event { self.runningTokens += max(1, text.count / 4) }
                }
            }
        }
        cancelRun = { task.cancel() }
        defer { running = nil; cancelRun = nil }
        do {
            let run = try await task.value
            switch kind {
            case .extract, .expand, .verify:
                dispatch(.applyRun(run, about: about))
            case .chat:
                let reply = ChatReply.parse(run.rawOutput)
                chatLog.append(("model", reply.prose))
                if !reply.lines.isEmpty {
                    dispatch(.applyModelOutput(reply.lines.joined(separator: "\n"), prompt: .chat, textID: textID, about: about))
                }
            case .clarify:
                clarifyQuestions = ClarifyQuestion.parse(run.rawOutput)
            case .dedupe:
                dedupeProposals = Dedupe.cheapPass(state.graph) + Dedupe.proposals(fromGated: run.gate.lines)
            }
            return run
        } catch {
            if !(error is CancellationError) {
                let raw = (error as? ModelError).map { "\($0)" } ?? error.localizedDescription
                lastError = (raw, "Model request failed", { [weak self] in Task { await self?.run(kind, item: item, textID: textID, about: about, contextOnly: contextOnly, texts: texts) } })
            }
            return nil
        }
    }

    func expand(_ name: String) {
        Task { await run(.expand, item: ModelRunner.neighbourhood(of: name, in: state.graph), about: name) }
    }

    func chat(_ message: String) {
        chatLog.append(("you", message))
        dispatch(.submitText(message, kind: .chat))
        let id = state.evidence.nextTextID - 1
        Task {
            await run(.extract, item: message, textID: id, about: "text \(id)")
            await run(.chat, item: message, textID: id, about: "chat")
        }
    }

    func askMe() {
        Task { await run(.clarify, item: "", about: "clarify", contextOnly: clarifyContextOnly) }
    }

    func findDuplicates() {
        dedupeProposals = Dedupe.cheapPass(state.graph)
        Task { await run(.dedupe, item: ModelRunner.nodeList(state.graph), about: "dedupe") }
    }

    func checkCoverage() {
        Task {
            if let run = await runVerify() { verifyReport = VerifyReport.parse(run.rawOutput) }
        }
    }

    private func runVerify() async -> ModelRun? {
        running = .verify
        defer { running = nil }
        return try? await runner.run(.verify, state: state, item: "", aliases: state.aliases)
    }

    func applyProposal(_ proposal: VerifyReport.Proposal) {
        let textID = state.evidence.sentences.last?.text
        dispatch(.applyModelOutput(proposal.lines.joined(separator: "\n"), prompt: .verify, textID: textID, about: "s\(proposal.sentence)"))
        verifyReport?.proposals.removeAll { $0 == proposal }
    }

    /// Validates an edited prompt by running the example through the fixture client and checking the output parses.
    func validatePrompt(_ kind: PromptKind, _ text: String) -> String? {
        let filled = PromptSet(overrides: [kind: text]).render(kind, map: "", context: "s1: I'm Sam.", nodes: ["sam"], item: "I'm Sam.")
        for placeholder in ["{map}", "{context}", "{nodes}", "{item}"] where text.contains(placeholder) == false && kind != .dedupe {
            if placeholder == "{item}" || placeholder == "{context}" { return "the prompt no longer contains \(placeholder); the model would not see the input" }
        }
        return filled.isEmpty ? "empty prompt" : nil
    }

    // MARK: - Export

    func export(_ format: ExportFormat) -> (data: Data, ext: String) {
        switch format {
        case .mm: return (Data(Export.canonical(state.graph).utf8), "mm")
        case .markdown: return (Data(Export.markdown(state.graph).utf8), "md")
        case .json: return ((try? Export.json(state.graph, layout: layout)) ?? Data(), "json")
        case .svg: return (Data(Export.svg(state.graph, layout: layout).utf8), "svg")
        }
    }

    enum ExportFormat: String, CaseIterable { case mm = "Canonical .mm", markdown = "Markdown outline", json = "JSON graph", svg = "SVG" }

    func importMM(_ text: String) {
        if let lines = try? Import.lines(fromMM: text) { dispatch(.applyLines(lines, what: "import")) }
    }
}

/// Recent folders for the menu bar menu.
enum RecentMaps {
    static let key = "recentMaps"
    static func all() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }
    static func add(_ url: URL) {
        var list = all().filter { $0 != url }
        list.insert(url, at: 0)
        UserDefaults.standard.set(list.prefix(8).map(\.path), forKey: key)
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValues: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "bookmark:\(url.path)")
        }
    }
    static func resolve(_ url: URL) -> URL {
        guard let data = UserDefaults.standard.data(forKey: "bookmark:\(url.path)") else { return url }
        var stale = false
        if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
            _ = resolved.startAccessingSecurityScopedResource()
            return resolved
        }
        return url
    }
}
