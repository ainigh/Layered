import SwiftUI
import Harness

struct PromptPanel: View {
    @Bindable var session: MapSession
    @State private var kind: PromptKind = .extract
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Picker("Prompt", selection: $kind) {
                ForEach(PromptKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .onChange(of: kind, initial: true) { _, k in text = session.prompts.template(for: k); problem = nil }
            TextEditor(text: $text).font(Theme.caption.monospaced()).frame(minHeight: 260, maxHeight: 400)
            if let problem { Text(problem).font(Theme.caption).foregroundStyle(.red) }
            HStack {
                Button("Save") {
                    problem = session.validatePrompt(kind, text)
                    if problem == nil { session.savePrompt(kind, text == PromptSet.defaultTemplate(for: kind) ? nil : text) }
                }
                Button("Reset to default") { text = PromptSet.defaultTemplate(for: kind); session.savePrompt(kind, nil); problem = nil }
                    .disabled(session.prompts.isDefault(kind))
                Spacer()
                Text(session.prompts.isDefault(kind) ? "default" : "edited").font(Theme.caption).foregroundStyle(.secondary)
            }
            if !session.prompts.isDefault(kind) {
                DisclosureGroup("Diff against default") {
                    PromptDiff(a: PromptSet.defaultTemplate(for: kind), b: text)
                }
            }
        }
    }
}

/// A line diff good enough to see what changed in a prompt.
struct PromptDiff: View {
    let a: String
    let b: String
    var body: some View {
        let al = a.components(separatedBy: "\n"), bl = b.components(separatedBy: "\n")
        let removed = al.filter { !bl.contains($0) }, added = bl.filter { !al.contains($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(removed, id: \.self) { Text("- \($0)").font(Theme.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
                ForEach(added, id: \.self) { Text("+ \($0)").font(Theme.caption.monospaced()).foregroundStyle(.green).textSelection(.enabled) }
            }
        }.frame(maxHeight: 160)
    }
}

struct SettingsPanel: View {
    @Bindable var session: MapSession
    @State private var models: [ModelInfo] = []
    @State private var connection: String?
    @State private var reachable = true
    @State private var memory = Int64(ProcessInfo.processInfo.physicalMemory)

    var body: some View {
        Form {
            Section("Ollama") {
                TextField("Host", text: $session.settings.model.host).onSubmit { save(); Task { await loadModels() } }
                HStack {
                    Picker("Model", selection: Binding(get: { session.settings.model.model ?? "" }, set: { session.settings.model.model = $0.isEmpty ? nil : $0; save() })) {
                        Text("none").tag("")
                        if session.offersRecordings { Text("demo (recorded answers)").tag(MapSession.demoModel) }
                        ForEach(models, id: \.name) { m in
                            Text("\(m.name)\(m.parameterSize.map { " · \($0)" } ?? "")\(m.fits(inMemory: memory) ? "" : " (does not fit)")").tag(m.name)
                        }
                        // A model picked before but not installed now still shows, so the picker has a match.
                        if let current = session.settings.model.model, current != MapSession.demoModel, !models.contains(where: { $0.name == current }) {
                            Text("\(current) (not installed)").tag(current)
                        }
                    }
                    Button("Refresh") { Task { await loadModels() } }
                }
                if let connection {
                    Text(connection).font(Theme.caption).foregroundStyle(reachable ? Color.secondary : Color.orange)
                }
                if !reachable {
                    Button("Start Ollama") {
                        AppModel.shared.startOllama(host: session.ollama.host)
                        Task { try? await Task.sleep(for: .seconds(2)); await loadModels() }
                    }
                }
                if session.usesRecordings {
                    Text("This demo answers from recordings. Pick an installed model to use Ollama instead.").font(Theme.caption).foregroundStyle(.secondary)
                }
                Slider(value: $session.settings.model.temperature, in: 0...1, step: 0.05) { Text("Temperature \(session.settings.model.temperature, specifier: "%.2f")") }
                    .onChange(of: session.settings.model.temperature) { _, _ in save() }
                TextField("Context size", value: $session.settings.model.contextSize, format: .number).onSubmit(save)
                Toggle("Send GBNF grammar (falls back if rejected)", isOn: $session.settings.model.useGrammar).onChange(of: session.settings.model.useGrammar) { _, _ in save() }
                Button("Test connection") { Task { await loadModels() } }
            }
            Section("Transcription") {
                TextField("whisper model", text: $session.settings.whisperModel).onSubmit(save)
                Text("Downloaded on first use to ~/Library/Application Support/Mindmap/whisper").font(Theme.caption).foregroundStyle(.secondary)
            }
            Section("Folder") {
                Text(session.title)
                if case .folder(let url) = session.mode { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Text("Icons: a node's name is matched against \(session.icons.library.count) words for SF Symbols (built in, and the symbols' own names and search tags on this Mac). A manifest.json in icons/ adds your own words: \(session.icons.entries.count) loaded.").font(Theme.caption)
            }
            Section("Appearance") {
                ThemePicker()
                TextField("Global capture shortcut", text: $session.settings.globalShortcut).onSubmit(save)
                Toggle("Optimize every n turns", isOn: Binding(get: { session.settings.optimizeEveryTurns != nil }, set: { session.settings.optimizeEveryTurns = $0 ? 50 : nil; save() }))
                if session.settings.optimizeEveryTurns != nil {
                    Stepper("Every \(session.settings.optimizeEveryTurns ?? 50) turns", value: Binding(get: { session.settings.optimizeEveryTurns ?? 50 }, set: { session.settings.optimizeEveryTurns = $0; save() }), in: 5...500, step: 5)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await loadModels() }
    }

    private func save() { session.saveSettings() }

    /// Asks Ollama (always Ollama, even in a demo) what is installed.
    private func loadModels() async {
        let host = session.settings.model.host
        do {
            models = try await session.ollama.models()
            reachable = true
            connection = models.isEmpty ? "Connected, but no models are installed: run `ollama pull <model>`." : "Connected to \(host) · \(models.count) models"
        } catch {
            models = []
            reachable = false
            connection = "Ollama is not answering at \(host). Is it running?"
            return
        }
        if session.settings.model.model == nil, let best = ModelInfo.defaultModel(from: models, memory: memory) {
            session.settings.model.model = best.name
            save()
        }
    }
}

struct HistoryPanel: View {
    @Bindable var session: MapSession

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Button { session.dispatch(.undo) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(session.state.undoable.isEmpty)
                Button { session.dispatch(.redo) } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(session.state.redoable.isEmpty)
                Spacer()
                Button("Optimize") { session.optimize() }.disabled(session.isDemo)
            }
            let log = session.state.logSize, canon = session.state.canonicalSize
            Text("log \(log.lines) lines · \(log.bytes / 1024) KB → canonical \(canon.lines) lines · \(canon.bytes / 1024) KB").font(Theme.caption).foregroundStyle(.secondary)
            if session.state.turns.count > 1 {
                Slider(value: Binding(get: { Double(session.viewingTurn ?? session.state.turns.last!.number) },
                                      set: { session.viewingTurn = Int($0.rounded()) == session.state.turns.last!.number ? nil : Int($0.rounded()) }),
                       in: Double(session.state.turns.first!.number)...Double(session.state.turns.last!.number), step: 1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(session.state.turns.reversed(), id: \.number) { turn in
                        HStack(alignment: .top) {
                            Text("\(turn.number)").font(Theme.label).frame(width: 32, alignment: .trailing)
                            VStack(alignment: .leading) {
                                Text("\(turn.who) · \(turn.what)").font(Theme.body)
                                Text("\(turn.lines.count) lines · \(turn.date.formatted(date: .omitted, time: .shortened))").font(Theme.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("View") { session.viewingTurn = turn.number }.font(Theme.caption)
                            if !session.isDemo { Button("Branch from here") { session.branch(atTurn: turn.number) }.font(Theme.caption) }
                        }
                        .padding(Theme.Space.xs)
                        .background(session.viewingTurn == turn.number ? Theme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 360)
        }
    }
}

/// The model in use, in the toolbar: what Ollama has installed (and a demo's recordings),
/// picked without opening Settings.
struct ModelPicker: View {
    @Bindable var session: MapSession
    let openSettings: () -> Void
    @State private var models: [ModelInfo] = []
    @State private var reachable = true
    private let memory = Int64(ProcessInfo.processInfo.physicalMemory)

    var body: some View {
        Menu {
            if session.offersRecordings {
                pick(MapSession.demoModel, title: "demo (recorded answers)")
            }
            if !reachable {
                Text("Ollama is not answering at \(session.settings.model.host)")
                Button("Start Ollama") {
                    AppModel.shared.startOllama(host: session.ollama.host)
                    Task { try? await Task.sleep(for: .seconds(2)); await load() }
                }
            } else if models.isEmpty {
                Text("No models installed: run `ollama pull <model>`")
            }
            ForEach(models, id: \.name) { m in
                pick(m.name, title: "\(m.name)\(m.parameterSize.map { " · \($0)" } ?? "")\(m.fits(inMemory: memory) ? "" : " (does not fit)")")
            }
            Divider()
            Button("Refresh list") { Task { await load() } }
            Button("Model settings…", action: openSettings)
        } label: {
            Label(session.settings.model.model ?? "Pick a model", systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("The model the map asks")
        .task(id: session.settings.model.host) { await load() }
    }

    private func pick(_ name: String, title: String) -> some View {
        Button {
            session.settings.model.model = name
            session.saveSettings()
        } label: {
            if session.settings.model.model == name { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func load() async {
        do {
            models = try await session.ollama.models()
            reachable = true
        } catch {
            models = []
            reachable = false
        }
    }
}

/// The app's appearance, the same choice as the status bar's toggle.
struct ThemePicker: View {
    @AppStorage(Appearance.key) private var appearance: Appearance = .system

    var body: some View {
        Picker("Theme", selection: $appearance) {
            ForEach(Appearance.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: appearance) { _, chosen in chosen.apply() }
    }
}
