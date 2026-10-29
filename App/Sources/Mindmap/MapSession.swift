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
    /// The live map laid out (`displayedLayout` is what the canvas shows).
    private(set) var layout = MapLayout()
    var icons = IconManifest()

    // Transient UI state (not persisted).
    var selection: Set<String> = []
    var selectedEdge: EdgeKey?
    var highlighted: [String: Date] = [:]
    var running: PromptKind?
    var runningTokens = 0
    /// When the running request started, so the map can say how long it has been going.
    var runningSince: Date?
    var cancelRun: (() -> Void)?
    var lastError: (raw: String, message: String, retry: (() -> Void)?)?
    var pendingWrites: [String] = []
    var clarifyQuestions: [ClarifyQuestion] = []
    var clarifyContextOnly = false
    var dedupeProposals: [DedupeProposal] = []
    var verifyReport: VerifyReport?
    var sentenceWalk: SentenceWalk?
    var sentenceMode = false
    /// The recording being added: its steps and progress, or what went wrong.
    var audioJob: AudioJob?
    /// Recordings this session added, by text id (a demo keeps them where they were dropped).
    private var audioFiles: [Int: URL] = [:]
    var viewingTurn: Int?
    /// What is open over the map: a context item, Ask me's questions, or Check coverage's report.
    var overlay: Overlay?
    /// The Context panel's new-item box, kept as it is typed.
    var composerDraft = "" { didSet { UserDefaults.standard.set(composerDraft, forKey: "draft:\(title)") } }

    /// The recorded answers a demo map gives until the user picks a real model.
    let recorded: any ModelClient
    let transcriber: any Transcriber
    let diarizer: any Diarizer
    private var bookmark: Data?

    var coverage: Coverage { Coverage.compute(state) }

    /// Ollama at the host in Settings, made fresh so a changed host or grammar setting applies.
    var ollama: OllamaClient {
        OllamaClient(host: URL(string: settings.model.host) ?? URL(string: "http://localhost:11434")!, sendGrammar: settings.model.useGrammar)
    }

    /// A demo answers from recordings while its model is "demo"; any other model is Ollama's.
    var usesRecordings: Bool { isDemo && (settings.model.model ?? Self.demoModel) == Self.demoModel }
    static let demoModel = "demo"

    /// Who model requests go to.
    var client: any ModelClient { usesRecordings ? recorded : ollama }

    /// Transcription progress for the status bar, while a recording is being added.
    var transcribing: Double? { audioJob?.running == true ? audioJob?.fraction ?? 0 : nil }
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

    /// The layout the canvas draws: the live map's, or the turn History is showing.
    var displayedLayout: MapLayout {
        viewingTurn == nil ? layout : lay(displayedGraph)
    }

    /// Lays a graph out as GridClip draws maps, measuring text as the canvas sets it.
    func lay(_ graph: Graph) -> MapLayout {
        let icons = self.icons
        return MapLayout.compute(graph, measure: { Theme.Map.measure($0, $1) }, glyph: { MapLayout.defaultGlyph($0) || !icons.icons(for: $0.id.name).isEmpty })
    }

    func relayout() { layout = lay(state.graph) }

    // MARK: - Opening

    static func demo(_ map: Demo.Map) -> MapSession {
        // A demo transcribes for real: dropping a recording is something the user asked for.
        MapSession(mode: .demo(map), state: Demo.state(map), storage: InMemoryStorage(), settings: Settings(), prompts: PromptSet(), ui: UIState(),
                   recorded: Demo.client(), transcriber: WhisperTranscriber(), diarizer: WhisperDiarizer())
    }

    static func open(folder: URL) throws -> MapSession {
        let storage = try FolderStorage(root: folder)
        let loaded = try Persistence.load(storage)
        var settings = loaded.settings
        if settings.model.model == nil { settings.model.model = UserDefaults.standard.string(forKey: "lastModel") }
        let session = MapSession(mode: .folder(folder), state: loaded.state, storage: storage, settings: settings, prompts: loaded.prompts, ui: loaded.ui,
                                 recorded: Demo.client(), transcriber: WhisperTranscriber(), diarizer: WhisperDiarizer())
        session.bookmark = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        if let data = try? storage.readIconManifest(), let manifest = try? IconManifest(json: data) { session.icons = manifest; session.relayout() }
        RecentMaps.add(folder)
        return session
    }

    private init(mode: Mode, state: MapState, storage: any MapStorage, settings: Settings, prompts: PromptSet, ui: UIState,
                 recorded: any ModelClient, transcriber: any Transcriber, diarizer: any Diarizer) {
        self.mode = mode
        self.state = state
        self.storage = storage
        self.settings = settings
        self.prompts = prompts
        self.ui = ui
        self.recorded = recorded
        self.transcriber = transcriber
        self.diarizer = diarizer
        if settings.model.model == nil, case .demo = mode { self.settings.model.model = Self.demoModel }
        composerDraft = UserDefaults.standard.string(forKey: "draft:\(title)") ?? ""
        relayout()
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
        relayout()
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
            relayout()
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

    /// Adds a context item (selected, not yet on the map: Submit sends it).
    func addContext(_ text: String, kind: ContextParagraph.Kind = .typed) {
        dispatch(.submitText(text, kind: kind))
    }

    /// Adds the composer's text as an item and clears the box.
    func addComposer() {
        guard !composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addContext(composerDraft)
        composerDraft = ""
    }

    var pendingItems: [ContextItem] { state.context.pendingItems }

    /// Extracts every selected item that is new or edited since it went on the map; with
    /// `only`, just that item. One sentence at a time walks their sentences in turn.
    func submit(only: Int? = nil) {
        let items = pendingItems.filter { only == nil || $0.id == only }
        guard !items.isEmpty, running == nil, sentenceWalk == nil else { return }
        let requests: [(textID: Int, text: String)] = items.compactMap { item in
            guard let id = item.textID else { return nil }
            let request = Submit.request(for: item)
            // An edit that only removed text has nothing new to extract.
            if request.isEmpty { dispatch(.markExtracted(textID: id)); return nil }
            return (id, request)
        }
        guard !requests.isEmpty else { return }
        if sentenceMode {
            // Only the sentences of what changed (all of them the first time).
            sentenceWalk = SentenceWalk(sentences: requests.flatMap { r in
                let all = state.evidence.sentences(text: r.textID)
                let changed = all.filter { r.text.contains($0.sentence) }
                return changed.isEmpty ? all : changed
            })
            Task { await walkSentences() }
        } else {
            Task {
                for r in requests {
                    if await run(.extract, item: r.text, textID: r.textID, about: "text \(r.textID)") != nil {
                        dispatch(.markExtracted(textID: r.textID))
                    } else { break }
                }
            }
        }
    }

    func walkSentences() async {
        while var walk = sentenceWalk, let sentence = walk.current, !walk.paused {
            guard await run(.extract, item: ContextRenderer.single(sentence), textID: sentence.text, about: "text \(sentence.text) s\(sentence.s)", texts: [sentence.text]) != nil else {
                sentenceWalk?.paused = true
                return
            }
            if let done = walk.advance() { dispatch(.markExtracted(textID: done)) }
            sentenceWalk = walk.isFinished ? nil : walk
        }
    }

    /// Adds a recording: transcribes it on this Mac, finds its speakers, keeps the file in
    /// the folder, and adds the transcript as a context item. Each step shows in `audioJob`.
    func dropAudio(_ url: URL) {
        guard audioJob?.running != true else { return }
        audioJob = AudioJob(file: url, step: .starting)
        Task {
            do {
                var transcript = try await transcriber.transcribe(url, model: settings.whisperModel) { [weak self] step in
                    Task { @MainActor in self?.audioJob?.advance(step) }
                }
                guard !transcript.segments.isEmpty else { throw AudioJob.Problem("No speech was found in \(url.lastPathComponent).") }
                audioJob?.step = .speakers
                transcript = (try? await diarizer.diarize(transcript, audio: url)) ?? transcript
                audioJob?.step = .adding
                // The id the transcript gets is the one the recording is kept under.
                let id = state.evidence.nextTextID
                audioFiles[id] = try storage.storeAudio(id: id, from: url)
                dispatch(.submitTranscript(transcript))
                audioJob?.step = .done(item: state.context.item(forText: id)?.id ?? 0)
            } catch {
                audioJob?.failedAt = audioJob?.step.rank
                audioJob?.step = .failed((error as? AudioJob.Problem)?.message ?? (error as? ModelError).map { "\($0)" } ?? error.localizedDescription)
            }
        }
    }

    /// Opens an item over the map.
    func open(item id: Int) { overlay = .item(id) }

    /// Selects the nodes an item's texts support.
    func selectIdeas(of item: ContextItem) {
        let texts = Set(item.textIDs)
        selection = Set(state.graph.nodes.keys.filter { !Coverage.supports(of: $0, in: state.graph).isDisjoint(with: texts) }.map(\.name))
    }

    /// Forgets the ideas whose only support is this item (each of its versions).
    func forgetIdeas(of item: ContextItem) {
        for id in item.textIDs { dispatch(.forgetText(id)) }
    }

    func audioURL(for textID: Int) -> URL? {
        if let url = audioFiles[textID] { return url }
        guard case .folder(let root) = mode else { return nil }
        let dir = root.appendingPathComponent("audio")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix("\(textID).") && !$0.lastPathComponent.contains("transcript") }
    }

    // MARK: - Model

    private var runner: ModelRunner {
        ModelRunner(client: client, settings: settings.model, prompts: prompts)
    }

    @discardableResult
    func run(_ kind: PromptKind, item: String, textID: Int? = nil, about: String, contextOnly: Bool = false, texts: [Int]? = nil) async -> ModelRun? {
        running = kind
        runningTokens = 0
        runningSince = Date()
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
        defer { running = nil; runningSince = nil; cancelRun = nil }
        do {
            let run = try await task.value
            switch kind {
            case .extract, .expand, .verify:
                dispatch(.applyRun(run, about: about))
            case .chat:
                // The map takes the lines; prose becomes a model item, opened over the map.
                let reply = ChatReply.parse(run.rawOutput)
                if !reply.lines.isEmpty {
                    dispatch(.applyModelOutput(reply.lines.joined(separator: "\n"), prompt: .chat, textID: textID, about: about))
                }
                if !reply.prose.isEmpty {
                    dispatch(.addReply(reply.prose, question: item))
                    if let id = state.context.items.last?.id { overlay = .item(id) }
                }
            case .clarify:
                clarifyQuestions = ClarifyQuestion.parse(run.rawOutput)
                overlay = .clarify
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

    /// Asks the model, reading the selected context. Lines it writes go on the map; prose it
    /// writes becomes a model item, shown over the map.
    func ask(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { await run(.chat, item: text, about: "ask " + String(Harness.Text.collapse(text).prefix(60))) }
    }

    /// Clarify: questions about the selected context, or about one item only.
    func askMe(about item: Int? = nil) {
        let texts = item.flatMap { state.context.item($0)?.textID }.map { [$0] }
        Task { await run(.clarify, item: "", about: "clarify", contextOnly: clarifyContextOnly || texts != nil, texts: texts) }
    }

    func findDuplicates() {
        dedupeProposals = Dedupe.cheapPass(state.graph)
        Task { await run(.dedupe, item: ModelRunner.nodeList(state.graph), about: "dedupe") }
    }

    func checkCoverage() {
        Task {
            if let run = await runVerify() {
                verifyReport = VerifyReport.parse(run.rawOutput)
                overlay = .coverage
            }
        }
    }

    private func runVerify() async -> ModelRun? {
        running = .verify
        runningSince = Date()
        let task = Task { [runner, state] in try await runner.run(.verify, state: state, item: "", aliases: state.aliases) }
        cancelRun = { task.cancel() }
        defer { running = nil; runningSince = nil; cancelRun = nil }
        return try? await task.value
    }

    /// Stops the request the model is working on: what it sent so far is dropped, and a
    /// sentence walk pauses where it was.
    func stop() {
        cancelRun?()
        cancelRun = nil
        sentenceWalk?.paused = true
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
        case .json: return ((try? Export.json(state.graph, layout: layout.centers)) ?? Data(), "json")
        case .svg: return (Data(Export.svg(state.graph, layout: layout).utf8), "svg")
        }
    }

    enum ExportFormat: String, CaseIterable { case mm = "Canonical .mm", markdown = "Markdown outline", json = "JSON graph", svg = "SVG" }

    func importMM(_ text: String) {
        if let lines = try? Import.lines(fromMM: text) { dispatch(.applyLines(lines, what: "import")) }
    }
}

/// What can open over the map. Opening one closes the side panes until it closes.
enum Overlay: Equatable {
    case item(Int)
    case clarify
    case coverage
    /// Add audio: a drop zone, then the recording's steps as it is transcribed.
    case audio
}

/// A recording being added, step by step.
struct AudioJob: Equatable {
    enum Step: Equatable {
        case starting
        /// The first time: the whisper model is downloaded (fraction nil while its size is unknown).
        case downloading(String, Double?)
        case decoding
        case transcribing(Double)
        case speakers
        case adding
        case done(item: Int)
        case failed(String)

        /// Its place in the list of steps the panel shows.
        var rank: Int {
            switch self {
            case .starting, .downloading: return 0
            case .decoding: return 1
            case .transcribing: return 2
            case .speakers: return 3
            case .adding: return 4
            case .done: return 5
            case .failed: return -1
            }
        }
    }

    struct Problem: Error { let message: String; init(_ message: String) { self.message = message } }

    let file: URL
    var step: Step
    /// The step that failed, to mark it in the panel.
    var failedAt: Int?

    var running: Bool {
        switch step { case .done, .failed: return false; default: return true }
    }

    /// Overall progress, for the status bar.
    var fraction: Double? {
        switch step {
        case .downloading(_, let f): return f.map { $0 * 0.3 }
        case .transcribing(let f): return 0.35 + f * 0.6
        case .speakers, .adding: return 0.97
        default: return nil
        }
    }

    /// A transcriber's step, unless the job has moved past it (progress can arrive late).
    mutating func advance(_ t: TranscriptionStep) {
        let next: Step
        switch t {
        case .downloadingModel(let name, let f): next = .downloading(name, f)
        case .decoding: next = .decoding
        case .transcribing(let f): next = .transcribing(f)
        }
        guard running, next.rank >= step.rank else { return }
        step = next
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
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
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
