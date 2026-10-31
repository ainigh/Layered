import SwiftUI
import Harness
import UniformTypeIdentifiers

/// What opens over the map: a context item, Ask me's questions, or the Add panel (text or audio).
/// The map dims behind it; clicking there, the close button or Esc closes it.
struct MapOverlay: View {
    @Bindable var session: MapSession
    let overlay: Overlay

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { session.overlay = nil }
            VStack(alignment: .leading, spacing: 0) {
                switch overlay {
                case .item(let id):
                    if let item = session.state.context.item(id) {
                        ItemOverlay(session: session, item: item).id(id)
                    }
                case .clarify:
                    ClarifyOverlay(session: session)
                case .text:
                    TextOverlay(session: session)
                case .audio:
                    AudioOverlay(session: session)
                }
            }
            .frame(maxWidth: 680, maxHeight: 620, alignment: .top)
            .background(.background, in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
            .padding(Theme.Space.l)
        }
    }
}

/// An overlay's title row: a tinted symbol, a title and a subtitle, extra controls, close.
struct OverlayHeader<Trailing: View>: View {
    let symbol: String
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String?
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.title)
                if let subtitle { Text(subtitle).font(Theme.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
        }
        .padding(Theme.Space.m)
    }
}

/// One context item over the map. Text you added (or a model reply) can be edited: Save
/// keeps it as a new version, and closing saves too. Text from audio can't be edited, so it
/// stays in step with the recording; each line plays from where it was said, and anything
/// to correct or add becomes a clarification, a new item.
struct ItemOverlay: View {
    @Bindable var session: MapSession
    let item: ContextItem
    @State private var draft = ""
    @State private var clarification = ""
    @State private var speakerNames: [String: String] = [:]
    /// The transcript as one block of text, to select across lines and copy.
    @State private var transcriptAsText = false

    var body: some View {
        let style = Theme.origin(item.origin)
        VStack(alignment: .leading, spacing: 0) {
            OverlayHeader(symbol: style.symbol, tint: style.color, title: "\(style.title) · item \(item.id)", subtitle: subtitle, close: close) {
                if !item.removed {
                    Toggle("In context", isOn: Binding(get: { item.selected }, set: { session.dispatch(.selectContext(item.id, $0)) }))
                        .toggleStyle(.switch).controlSize(.small)
                        .help("The model reads only the items in the context")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let q = item.question {
                    Text("You asked: \(q)").font(Theme.label).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if item.kind == .transcript {
                    transcript
                } else {
                    TextEditor(text: $draft)
                        .font(Theme.body)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Space.xs)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2).strokeBorder(Color.primary.opacity(0.1)))
                        .disabled(item.removed)
                    if item.origin == .model {
                        Text("Written by the model. It is never proof; editing it makes it yours.").font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.Space.m)
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            footer.padding(Theme.Space.m)
        }
        .onAppear { draft = item.body }
        .onChange(of: item.body) { _, body in draft = body }
        .onDisappear(perform: save)
    }

    private var subtitle: String {
        var parts = [item.added.formatted(date: .abbreviated, time: .shortened)]
        if item.revisions.count > 1 { parts.append("version \(item.revisions.count)") }
        if item.removed { parts.append("deleted") } else if item.isOnMap { parts.append("on the map") } else if item.origin != .model { parts.append("not on the map yet") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Button { Clipboard.copy(item.kind == .transcript ? session.copyText(of: item) : draft) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help(item.kind == .transcript ? "Copy the transcript, each line with its time and speaker" : "Copy the text")
            if item.removed {
                Button("Restore") { session.dispatch(.restoreContext(item.id)) }
            } else {
                Button { save(); session.askMe(about: item.id) } label: { Label("Ask me about this", systemImage: "questionmark.bubble") }
                    .disabled(session.running != nil)
                if item.isPending || (draft != item.body && item.origin != .model) {
                    Button { save(); session.submit(only: item.id) } label: { Label("Submit to the map", systemImage: "arrow.up.circle") }
                        .disabled(session.running != nil || !item.selected)
                        .help(item.selected ? "Extract this item now" : "Select it first: only items in the context go on the map")
                }
                Menu {
                    ContextItemMenu(session: session, item: item)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Spacer()
            if item.isEditable, !item.removed {
                Button("Revert") { draft = item.body }.disabled(draft == item.body)
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(draft == item.body)
            }
        }
        .controlSize(.small)
    }

    /// The transcript line by line, each playable from where it was said; its speakers;
    /// a box to add a clarification.
    @ViewBuilder
    private var transcript: some View {
        let t = item.textID.flatMap { session.state.transcripts[$0] }
        let audio = item.textID.flatMap { session.audioURL(for: $0) }
        HStack(spacing: Theme.Space.s) {
            if let audio {
                let playing = AudioPlayer.shared.isPlaying(audio, from: 0)
                Button { if playing { AudioPlayer.shared.stop() } else { AudioPlayer.shared.play(audio) } } label: {
                    Label(playing ? "Stop" : "Play the recording", systemImage: playing ? "stop.fill" : "play.fill")
                }
                .controlSize(.small)
            }
            Text("Text from audio can't be edited, so it stays in step with the recording.").font(Theme.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if t != nil {
                Picker("", selection: $transcriptAsText) {
                    Text("Lines").tag(false)
                    Text("Text").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("Lines: each plays from where it was said. Text: the whole transcript, to select across lines and copy")
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if t != nil, transcriptAsText {
                    Text(session.copyText(of: item)).font(Theme.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let t {
                    ForEach(Array(t.segments.enumerated()), id: \.offset) { _, seg in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            if let audio {
                                let playing = AudioPlayer.shared.isPlaying(audio, from: seg.t0)
                                Button { if playing { AudioPlayer.shared.stop() } else { AudioPlayer.shared.play(audio, from: seg.t0, to: seg.t1) } } label: {
                                    Text(Clock.stamp(seg.t0)).monospacedDigit()
                                }
                                .buttonStyle(.plain).foregroundStyle(playing ? Theme.accent : .secondary)
                                .help("Play from here")
                            } else {
                                Text(Clock.stamp(seg.t0)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if let sp = seg.speaker { Text(session.state.speakers.name(for: sp) ?? sp).font(Theme.label).foregroundStyle(Theme.origin(.audio).color).textSelection(.enabled) }
                            Text(seg.text).font(Theme.body).textSelection(.enabled)
                        }
                        .font(Theme.caption)
                        .contextMenu {
                            Button("Copy line") { Clipboard.copy(seg.text) }
                            Button("Copy the transcript") { Clipboard.copy(session.copyText(of: item)) }
                        }
                    }
                } else {
                    Text(item.body).font(Theme.body).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let t, !t.speakers.isEmpty {
            SpeakerNames(session: session, labels: t.speakers, names: $speakerNames)
        }
        HStack {
            TextField("Clarify: who is speaking, where this was, what a word means…", text: $clarification)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addClarification)
            Button("Add", action: addClarification).disabled(clarification.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }

    private func addClarification() {
        session.dispatch(.answer(nil, clarification))
        clarification = ""
    }

    /// Keeps an edit as a new version of the item (nothing when unchanged).
    private func save() {
        guard item.isEditable, draft != item.body else { return }
        session.dispatch(.reviseContext(item.id, draft))
    }

    private func close() {
        save()
        session.overlay = nil
    }
}

/// Speaker labels to names; each name set is a clarification item (`Speaker 1 is ana`).
struct SpeakerNames: View {
    @Bindable var session: MapSession
    let labels: [String]
    @Binding var names: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionTitle("Speakers")
            ForEach(labels, id: \.self) { label in
                HStack {
                    Text(label).font(Theme.caption).frame(width: 80, alignment: .leading)
                    TextField("name", text: Binding(get: { names[label] ?? session.state.speakers.names[label.lowercased()] ?? "" }, set: { names[label] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button("Set") {
                        if let name = names[label], !name.isEmpty { session.dispatch(.nameSpeaker(label: label, name: name)) }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

/// Ask me's questions over the map, each with the sentence it is about and an answer box.
/// Every answer becomes a clarification item in the context.
struct ClarifyOverlay: View {
    @Bindable var session: MapSession
    @State private var answers: [Int: String] = [:]
    @State private var speakerNames: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OverlayHeader(symbol: "questionmark.bubble", title: "Ask me", subtitle: "Each answer joins the context as a clarification item.", close: { session.overlay = nil }) {
                Toggle("Context only", isOn: $session.clarifyContextOnly).toggleStyle(.switch).controlSize(.small)
                    .help("Ask about the text alone, without the map")
                Button("Ask again") { session.askMe() }.controlSize(.small).disabled(session.running != nil)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if session.clarifyQuestions.isEmpty {
                        Text("No questions left. Ask again after adding more context.").font(Theme.body).foregroundStyle(.secondary)
                    }
                    ForEach(Array(session.clarifyQuestions.enumerated()), id: \.offset) { i, q in
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text("\(q.reason) · s\(q.sentence)").font(Theme.label).foregroundStyle(.secondary)
                            Text(sentence(q.sentence)).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
                            Text(q.question).font(Theme.body).textSelection(.enabled)
                            HStack {
                                TextField("answer", text: Binding(get: { answers[i] ?? "" }, set: { answers[i] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { answer(i, q) }
                                Button("Add") { answer(i, q) }.disabled((answers[i] ?? "").isEmpty)
                            }
                        }
                        .rowCard()
                    }
                    let labels = Set(session.state.evidence.sentences.compactMap(\.speaker)).sorted()
                    if !labels.isEmpty {
                        SpeakerNames(session: session, labels: labels, names: $speakerNames)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sentence(_ n: Int) -> String {
        let texts = Set(session.state.modelTexts ?? [])
        return session.state.evidence.sentences.last { $0.s == n && (texts.isEmpty || texts.contains($0.text)) }?.sentence ?? ""
    }

    private func answer(_ i: Int, _ q: ClarifyQuestion) {
        guard let text = answers[i], !text.isEmpty else { return }
        session.dispatch(.answer(q, text))
        answers = [:]
        session.clarifyQuestions.remove(at: i)
    }
}

/// Add text: paste or type, then add it to Context as an item (and, if you like, send it
/// to the map straight away). The box keeps what was typed until it is added.
struct TextOverlay: View {
    @Bindable var session: MapSession

    var body: some View {
        let empty = session.composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 0) {
            OverlayHeader(symbol: "doc.text", tint: Theme.origin(.you).color, title: "Add text",
                          subtitle: "It joins Context as an item; send it to the map from there, or now.", close: { session.overlay = nil }) { AddTabs(session: session) }
            Divider()
            TextEditor(text: $session.composerDraft)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .frame(minHeight: 240)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2).strokeBorder(Color.primary.opacity(0.1)))
                .overlay(alignment: .topLeading) {
                    if session.composerDraft.isEmpty {
                        Text("Paste or type new context…")
                            .font(Theme.body).foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Space.s + 1).padding(.vertical, Theme.Space.xs)
                            .allowsHitTesting(false)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(spacing: Theme.Space.s) {
                Spacer()
                Button("Add to Context") { add(send: false) }
                    .disabled(empty)
                    .help("Add it as an item; send it to the map from its button in Context")
                Button { add(send: true) } label: { Label("Add and send to the map", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(empty || session.running != nil || session.sentenceWalk != nil)
                    .help("Add it as an item and put it on the map now")
            }
            .controlSize(.small)
            .padding(Theme.Space.m)
        }
    }

    private func add(send: Bool) {
        session.addComposer(send: send)
        session.overlay = nil
    }
}

/// Text or Audio, in the Add panel's header: switches between the two.
struct AddTabs: View {
    @Bindable var session: MapSession

    var body: some View {
        Picker("", selection: Binding(get: { session.overlay == .audio }, set: { session.overlay = $0 ? .audio : .text })) {
            Text("Text").tag(false)
            Text("Audio").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Add audio: drop a recording (or choose one), then watch it go through each step, on
/// this Mac, until it is an item in the context.
struct AudioOverlay: View {
    @Bindable var session: MapSession
    @State private var targeted = false

    static let kinds = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "mp4"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OverlayHeader(symbol: "waveform", tint: Theme.origin(.audio).color, title: "Add audio",
                          subtitle: "Transcribed on this Mac with whisper; nothing leaves it.", close: { session.overlay = nil }) { AddTabs(session: session) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let job = session.audioJob { progress(job) }
                    if session.audioJob?.running != true { dropZone }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.origin(.audio).color)
            Text("Drop a recording here").font(Theme.title)
            Text(Self.kinds.joined(separator: ", ")).font(Theme.caption).foregroundStyle(.secondary)
            Button("Choose a file…", action: choose).controlSize(.regular)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(targeted ? Theme.origin(.audio).color.opacity(0.1) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(targeted ? Theme.origin(.audio).color : Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in start(url) }
            }
            return true
        }
    }

    /// The recording's steps: done, under way (with its progress) or still to come.
    private func progress(_ job: AudioJob) -> some View {
        let steps: [(String, String)] = [
            (downloadTitle(job), "arrow.down.circle"),
            ("Read the audio", "waveform"),
            ("Transcribe", "text.bubble"),
            ("Find who is speaking", "person.2"),
            ("Add it to the context", "doc.text"),
        ]
        let current = job.failedAt ?? job.step.rank
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(job.file.lastPathComponent, systemImage: "doc.richtext").font(Theme.label)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(spacing: Theme.Space.s) {
                    Group {
                        if case .failed = job.step, i == current {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        } else if i < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.origin(.audio).color)
                        } else if i == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    Text(step.0).font(Theme.body).foregroundStyle(i <= current ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                    if i == current, let f = fraction(job) {
                        ProgressView(value: f).frame(width: 120)
                        Text("\(Int(f * 100))%").font(Theme.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                }
            }
            switch job.step {
            case .failed(let message):
                Text(message).font(Theme.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { session.dropAudio(job.file, replacing: job.replacing) }.controlSize(.small)
            case .done(let item):
                HStack {
                    Text("Added to the context as item \(item), selected and ready to submit.").font(Theme.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open it") { session.open(item: item) }.controlSize(.small)
                }
            default:
                Text("You can close this; it carries on, and its progress shows below the map.").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .rowCard()
    }

    private func downloadTitle(_ job: AudioJob) -> String {
        if case .downloading(let name, _) = job.step { return "Download the whisper model \(name) (first time only)" }
        return "Whisper model ready"
    }

    private func fraction(_ job: AudioJob) -> Double? {
        switch job.step {
        case .downloading(_, let f): return f
        case .transcribing(let f): return f
        default: return nil
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Movie]
        panel.prompt = "Transcribe"
        if panel.runModal() == .OK, let url = panel.url { start(url) }
    }

    private func start(_ url: URL) {
        guard Self.kinds.contains(url.pathExtension.lowercased()) else {
            session.audioJob = AudioJob(file: url, step: .failed("\(url.lastPathComponent) is not a recording this can read (\(Self.kinds.joined(separator: ", ")))."), failedAt: 0)
            return
        }
        session.dropAudio(url)
    }
}

