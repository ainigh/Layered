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
    /// Recording from the microphone, plain or live.
    var recording: Recording?
    @ObservationIgnored private var recorder: LiveRecorder?
    /// The live map's own Extract is running (so Stop now can cancel it).
    @ObservationIgnored private var liveExtracting = false
    /// How loud the microphone is now, 0 to 1 (read on a timer, not observed).
    var recordingLevel: Float { recorder?.level ?? 0 }
    /// Recordings this session added, by text id (a demo keeps them where they were dropped).
    private var audioFiles: [Int: URL] = [:]
    /// The recording being added; the next one waits for it.
    @ObservationIgnored private var audioQueue: Task<Void, Never>?
    var viewingTurn: Int?
    /// What is open over the map: a context item, Ask me's questions, or Check coverage's report.
    var overlay: Overlay?
    /// What the model added that the user has not accepted or deleted yet: flagged on the map
    /// with ✓ and ✕. Kept per map between launches.
    var review = Review() { didSet { if review != oldValue { saveReview() } } }
    /// A word from the last model turn, shown on the map rather than over it: a reply to
    /// open, or what Check coverage found.
    var notice: Notice?
    /// Bumped to open the selection's details on the right (selecting alone does not).
    var detailsRequests = 0
    /// Bumped to open the context on the left, where a new item just went.
    var contextRequests = 0
    /// The Add text box, kept as it is typed.
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
    var usesRecordings: Bool { (settings.model.model ?? (isDemo ? Self.demoModel : nil)) == Self.demoModel }
    static let demoModel = Workspace.demoModel
    /// A demo, or a project made from one: its recordings can be picked as the model.
    var offersRecordings: Bool {
        if case .folder(let url) = mode { return Workspace.isDemo(url) || settings.model.model == Self.demoModel }
        return true
    }

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

    /// The live map arranged afresh, its pins ignored (where Fill the view starts).
    func autoArranged() -> MapLayout { lay(MapLayout.unpinned(state.graph)) }

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
        loadReview()
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
        // What a model turn adds goes on the map at once; the user accepts or deletes it there.
        switch action {
        case .applyRun, .applyModelOutput: review.mark(from: before.graph, to: next.graph)
        default: break
        }
        review.prune(next.graph)
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

    /// Adds the Add text box's text as an item and clears the box; with `send`, puts it on
    /// the map too.
    func addComposer(send: Bool = false) {
        guard !composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        addContext(composerDraft)
        composerDraft = ""
        contextRequests += 1
        if send, let id = state.context.items.last?.id { submit(only: id) }
    }

    /// One item's send button: selects it if it isn't, and puts what is new in it on the map.
    func send(item id: Int) {
        guard let item = state.context.item(id), !item.removed, item.kind != .model else { return }
        if !item.selected { dispatch(.selectContext(id, true)) }
        submit(only: id)
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
    /// `replacing`: the texts of a live map's pieces, which the whole recording, transcribed
    /// in one go, takes the place of in the context.
    func dropAudio(_ url: URL, replacing pieces: [Int] = []) {
        guard audioJob?.running != true else { return }
        addAudio(url, replacing: pieces)
    }

    /// Queues a recording behind the one being added, if any: a recording that stops while
    /// a dropped file is transcribed waits for it.
    private func addAudio(_ url: URL, replacing pieces: [Int] = []) {
        let previous = audioQueue
        audioQueue = Task {
            await previous?.value
            await transcribeAudio(url, replacing: pieces)
        }
    }

    private func transcribeAudio(_ url: URL, replacing pieces: [Int]) async {
        audioJob = AudioJob(file: url, step: .starting, replacing: pieces)
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
            audioFiles[id] = try keepAudio(url, as: id)
            dispatch(.submitTranscript(transcript))
            let item = state.context.item(forText: id)?.id ?? 0
            audioJob?.step = .done(item: item)
            if !pieces.isEmpty, item != 0 { replaceLivePieces(pieces, with: item) }
        } catch {
            audioJob?.failedAt = audioJob?.step.rank
            let message = (error as? AudioJob.Problem)?.message ?? (error as? ModelError).map { "\($0)" } ?? error.localizedDescription
            audioJob?.step = .failed(message)
            if isRecording(url) {
                notice = Notice(text: "The recording is kept in the project's audio folder, but it could not be transcribed: " + message
                                + (pieces.isEmpty ? "" : " What the live map heard stays in Context."))
            }
        }
    }

    /// Where a recording is written as it comes: the project's audio folder, where dropped
    /// recordings are kept too (a demo's goes to the temporary folder, for the session).
    private var recordingsFolder: URL {
        guard case .folder(let root) = mode else { return FileManager.default.temporaryDirectory }
        return root.appendingPathComponent("audio")
    }

    /// A recording made here, still under its own name in the project's audio folder.
    private func isRecording(_ url: URL) -> Bool {
        guard case .folder = mode else { return false }
        return url.lastPathComponent.hasPrefix(LiveRecorder.prefix)
            && url.deletingLastPathComponent().standardizedFileURL.path == recordingsFolder.standardizedFileURL.path
    }

    /// Keeps a recording under its text id. One made here is already in the project's audio
    /// folder, so it is renamed rather than copied (the live pieces' hard links still find it).
    private func keepAudio(_ url: URL, as id: Int) throws -> URL {
        if isRecording(url) {
            let target = recordingsFolder.appendingPathComponent("\(id).\(url.pathExtension)")
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        }
        return try storage.storeAudio(id: id, from: url)
    }

    /// The whole recording is in Context: the live pieces, transcribed ten seconds at a time
    /// (words cut at the edges, little to go on), leave the context the model reads, so their
    /// slips go no further. Their ideas stay on the map with their proof, and they can be
    /// selected again.
    private func replaceLivePieces(_ pieces: [Int], with item: Int) {
        var replaced = 0
        for text in pieces {
            guard let piece = state.context.item(forText: text), piece.selected, !piece.removed else { continue }
            dispatch(.selectContext(piece.id, false))
            replaced += 1
        }
        let what = replaced == 1 ? "its live piece" : "its \(replaced) live pieces"
        notice = Notice(text: "The live map's recording, transcribed in one go, is in Context as item \(item)"
                        + (replaced > 0 ? " in place of \(what); their ideas stay on the map." : "."), item: item)
    }

    // MARK: - Recording

    /// Seconds of speech a live map gathers before it transcribes them and puts them on the map.
    static let liveChunk = 10

    /// Records the microphone. Plain: when it stops, the recording is transcribed and added
    /// as a dropped file is. Live: every few seconds what was said is transcribed, added as
    /// an item and put on the map, while the recording goes on.
    func startRecording(live: Bool) {
        guard recording == nil, live || audioJob?.running != true else { return }
        recording = Recording(live: live, started: Date(), status: "Waiting for the microphone…")
        Task {
            guard await LiveRecorder.permission() else {
                recording = nil
                lastError = ("Turn it on in System Settings › Privacy & Security › Microphone.", "Mindmap can't use the microphone", nil)
                return
            }
            let recorder = LiveRecorder(in: recordingsFolder)
            do {
                try recorder.start(keepSamples: live)
            } catch {
                recording = nil
                lastError = ((error as? AudioJob.Problem)?.message ?? error.localizedDescription, "Recording could not start", nil)
                return
            }
            self.recorder = recorder
            recording?.started = Date()
            recording?.status = live ? "Getting whisper ready…" : nil
            if live { await transcribeLive(recorder) }
        }
    }

    /// Stops the recording. A plain one is then transcribed; a live one finishes what it heard.
    /// Pressed again while a live one finishes, it stops now: whatever it was doing (a model
    /// download, a piece being transcribed, the model) is let go, what is not on the map yet
    /// stays in the recording, and the recording is kept as it is.
    func stopRecording() {
        guard let recorder, let rec = recording, !rec.cancelled else { return }
        if rec.stopping {
            guard rec.live else { return }
            recording?.cancelled = true
            if liveExtracting { cancelRun?() }
            // The live loop sees this recording is over when its current step returns, and leaves.
            finishLive(recorder)
            return
        }
        recorder.stop()
        recording?.stopping = true
        guard !rec.live else { return }
        recording = nil
        self.recorder = nil
        addAudio(recorder.url)
    }

    /// The live loop: waits for enough speech, cuts it at a quiet moment, transcribes it,
    /// adds it as an item and puts it on the map; again until the recording stops and
    /// everything it heard is in. While the model works the recording goes on, so the next
    /// piece is simply longer.
    private func transcribeLive(_ recorder: LiveRecorder) async {
        let rate = LiveRecorder.rate
        var cursor = 0
        // Still this recording's loop, and not stopped now? After every wait it checks.
        let mine = recording?.id
        func going() -> Bool { recording?.id == mine && recording?.cancelled != true }
        do {
            let model = settings.whisperModel
            let modelURL = try await WhisperModels.ensure(model) { [weak self] f in
                Task { @MainActor in self?.recording?.status = "Downloading the whisper model \(model)" + (f.map { " · \(Int($0 * 100))%" } ?? "…") }
            }
            guard going() else { return }
            recording?.status = "Getting whisper ready…"
            let whisper = try await Task.detached(priority: .userInitiated) { try WhisperSession(modelURL: modelURL) }.value
            guard going() else { return }
            recording?.status = "Listening…"
            while going() {
                let stopped = recorder.stopped
                let available = recorder.sampleCount
                if !stopped, available - cursor < Self.liveChunk * rate {
                    try await Task.sleep(for: .milliseconds(400))
                    continue
                }
                let end = stopped ? available : recorder.quietCut(from: cursor, to: available)
                let samples = recorder.samples(cursor..<end)
                let offset = Double(cursor) / Double(rate)
                cursor = end
                recorder.discard(upTo: cursor)
                // Silence makes whisper invent words; skip it.
                if samples.count >= rate / 2, LiveRecorder.rms(samples) > 0.004 {
                    recording?.status = "Transcribing…"
                    let heard = try await Task.detached(priority: .userInitiated) { try whisper.transcribe(samples) }.value
                    guard going() else { return }
                    let transcript = Self.placed(heard, at: offset)
                    if !transcript.segments.isEmpty { await addLive(transcript, going: going) }
                    guard going() else { return }
                }
                if stopped, cursor >= recorder.sampleCount { break }
                recording?.status = recorder.stopped ? "Transcribing the last words…" : "Listening…"
            }
        } catch {
            guard going() else { return }
            recorder.stop()
            recording?.problem = (error as? ModelError).map { "\($0)" } ?? error.localizedDescription
        }
        if going() { finishLive(recorder) }
    }

    /// A piece of a live recording, timed from the recording's start, without what whisper
    /// writes for no speech (`[BLANK_AUDIO]`, `(music)`).
    nonisolated static func placed(_ piece: Transcript, at offset: Double) -> Transcript {
        var t = piece
        t.segments = piece.segments.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let bracketed = (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
            guard !text.isEmpty, !bracketed else { return nil }
            return Transcript.Segment(t0: seg.t0 + offset, t1: seg.t1 + offset, text: text, speaker: seg.speaker)
        }
        return t
    }

    /// What a live recording heard becomes an item, and goes on the map once the model is free.
    private func addLive(_ transcript: Transcript, going: () -> Bool) async {
        let id = state.evidence.nextTextID
        dispatch(.submitTranscript(transcript))
        guard state.context.item(forText: id) != nil else { return }
        recording?.texts.append(id)
        recording?.heard.append(contentsOf: transcript.segments.map(\.text))
        // The model takes one request at a time: wait for the one under way (a paused
        // sentence walk is not one), unless the user stops the live map now.
        while running != nil || sentenceWalk?.paused == false {
            guard going() else { return }
            recording?.status = "Waiting for the model…"
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Read again: the user may have deselected or deleted it meanwhile.
        guard going(), let item = state.context.item(forText: id), item.isPending else { return }
        let request = Submit.request(for: item)
        guard !request.isEmpty else { return }
        recording?.status = "Putting it on the map…"
        liveExtracting = true
        let done = await run(.extract, item: request, textID: id, about: "text \(id)") != nil
        liveExtracting = false
        if done { dispatch(.markExtracted(textID: id)) }
    }

    /// The live recording is over: its file, already in the project's audio folder, is kept
    /// under every item it became (each plays from its own moment), the map says how it went,
    /// and the whole recording is transcribed again in one go and added as a dropped one is,
    /// in place of the pieces.
    private func finishLive(_ recorder: LiveRecorder) {
        let ids = recording?.texts ?? []
        for id in ids {
            let link = recordingsFolder.appendingPathComponent("\(id).\(recorder.url.pathExtension)")
            // A hard link in the project's audio folder: found again next launch, no extra space.
            if isRecording(recorder.url), (try? FileManager.default.linkItem(at: recorder.url, to: link)) != nil {
                audioFiles[id] = link
            } else {
                audioFiles[id] = (try? storage.storeAudio(id: id, from: recorder.url)) ?? recorder.url
            }
        }
        let problem = recording?.problem
        let cut = recording?.cancelled == true
        recording = nil
        self.recorder = nil
        let said: String
        if let problem {
            said = "The live map stopped: " + problem
        } else if cut {
            said = "The live map stopped. What it heard is in Context; anything not on the map yet waits for its send button."
        } else if ids.isEmpty {
            said = "The live map heard no speech."
        } else {
            said = ids.count == 1 ? "The live map added the recording as an item and put it on the map."
                : "The live map added the recording as \(ids.count) items and put them on the map."
        }
        notice = Notice(text: said + " The whole recording is kept and now transcribed in one go for Context.")
        addAudio(recorder.url, replacing: ids)
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
        ModelRunner(client: client, settings: settings.model, prompts: prompts, appendAll: true)
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
                    dispatch(.applyModelOutput(reply.lines.joined(separator: "\n"), prompt: .chat, textID: textID, about: about, appendAll: true))
                }
                if !reply.prose.isEmpty {
                    dispatch(.addReply(reply.prose, question: item))
                    // The reply joins the context; the map only says so, so work goes on there.
                    if let id = state.context.items.last?.id { notice = Notice(text: "The model replied: " + String(Harness.Text.collapse(reply.prose).prefix(120)), item: id) }
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
                // What the map lacks goes straight on it, for review there.
                var report = VerifyReport.parse(run.rawOutput)
                let lines = report.proposals.flatMap(\.lines)
                if !lines.isEmpty {
                    dispatch(.applyModelOutput(lines.joined(separator: "\n"), prompt: .verify, textID: state.evidence.sentences.last?.text, about: "coverage", appendAll: true))
                }
                let found = report.proposals.count
                report.proposals = []
                verifyReport = report
                notice = Notice(text: found == 0 ? "Check coverage: everything in the context is on the map." : "Check coverage put \(found) facts on the map for review.",
                                report: !report.missingNodes.isEmpty)
            }
        }
    }

    private func runVerify() async -> ModelRun? {
        running = .verify
        runningSince = Date()
        lastError = nil
        let task = Task { [runner, state] in try await runner.run(.verify, state: state, item: "", aliases: state.aliases) }
        cancelRun = { task.cancel() }
        defer { running = nil; runningSince = nil; cancelRun = nil }
        do {
            return try await task.value
        } catch {
            if !(error is CancellationError) {
                let raw = (error as? ModelError).map { "\($0)" } ?? error.localizedDescription
                lastError = (raw, "Check coverage failed", { [weak self] in self?.checkCoverage() })
            }
            return nil
        }
    }

    // MARK: - Review

    func accept(node name: String) { review.accept(node: name) }
    func accept(edge key: EdgeKey) { review.accept(edge: key) }
    func acceptAll() { review.acceptAll() }

    func reject(node name: String) {
        dispatch(.delete(name))
        selection.remove(name)
    }

    func reject(edge key: EdgeKey) {
        dispatch(.applyLines(review.deletion(in: state.graph, nodes: [], edges: [key]), what: "delete link \(key.lo.name) \(key.hi.name)"))
        if selectedEdge == key { selectedEdge = nil }
    }

    /// Everything waiting for review off the map, in one turn (one undo brings it back).
    func rejectAll() {
        let n = review.count
        dispatch(.applyLines(review.deletion(in: state.graph), what: "delete \(n) suggestions"))
        selection.subtract(review.nodes)
        review.acceptAll()
    }

    private var reviewKey: String { "review:\(title)" }

    private func saveReview() {
        let value: [String: [String]] = ["nodes": review.nodes.sorted(), "edges": review.edges.sorted().map { $0.lo.name + "\u{1}" + $0.hi.name }]
        UserDefaults.standard.set(value, forKey: reviewKey)
    }

    private func loadReview() {
        guard let value = UserDefaults.standard.dictionary(forKey: reviewKey) as? [String: [String]] else { return }
        let edges = (value["edges"] ?? []).compactMap { s -> EdgeKey? in
            let parts = s.components(separatedBy: "\u{1}")
            return parts.count == 2 ? EdgeKey(NodeID(name: parts[0]), NodeID(name: parts[1])) : nil
        }
        var loaded = Review(nodes: Set(value["nodes"] ?? []), edges: Set(edges))
        loaded.prune(state.graph)
        review = loaded
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
        dispatch(.applyModelOutput(proposal.lines.joined(separator: "\n"), prompt: .verify, textID: textID, about: "s\(proposal.sentence)", appendAll: true))
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
/// A word from the model's last turn, on the map instead of over it.
struct Notice: Equatable {
    var text: String
    /// The context item it is about (a reply), to open.
    var item: Int?
    /// Check coverage's report has more to show.
    var report = false
}

enum Overlay: Equatable {
    case item(Int)
    case clarify
    case coverage
    /// Add text: a box to paste or type a new item into.
    case text
    /// Add audio: a drop zone, then the recording's steps as it is transcribed.
    case audio
}

/// A recording from the microphone under way.
struct Recording: Equatable {
    /// Which recording it is, so a live loop still running for one that ended leaves it alone.
    let id = UUID()
    /// Live: transcribed as it goes, each piece added and put on the map. Otherwise
    /// transcribed when it stops, as a dropped file is.
    let live: Bool
    var started: Date
    /// What it is doing now, when there is something to say.
    var status: String?
    /// What a live recording has heard so far, and the texts it became.
    var heard: [String] = []
    var texts: [Int] = []
    var stopping = false
    /// Stop now was pressed while it finished: what is left is dropped.
    var cancelled = false
    var problem: String?
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
    /// The live pieces this recording takes the place of in the context, once it is in.
    var replacing: [Int] = []
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

/// Where the maps folder is kept between launches (a bookmark, as `RecentMaps` keeps maps),
/// and which project was open last.
enum WorkspaceStore {
    static let path = "workspace"
    static let bookmark = "workspaceBookmark"
    static let lastProject = "lastProject"

    static func load() -> URL? {
        if let data = UserDefaults.standard.data(forKey: bookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        return UserDefaults.standard.string(forKey: path).map { URL(fileURLWithPath: $0) }
    }

    static func save(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: path)
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmark)
        }
        UserDefaults.standard.removeObject(forKey: lastProject)
    }
}
