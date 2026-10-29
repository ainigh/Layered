import SwiftUI
import Harness

/// What opens over the map: a context item, Ask me's questions, or Check coverage's report.
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
                case .coverage:
                    CoverageOverlay(session: session)
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
                    Text("You asked: \(q)").font(Theme.label).foregroundStyle(.secondary)
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
        }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let t {
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
                            if let sp = seg.speaker { Text(session.state.speakers.name(for: sp) ?? sp).font(Theme.label).foregroundStyle(Theme.origin(.audio).color) }
                            Text(seg.text).font(Theme.body).textSelection(.enabled)
                        }
                        .font(Theme.caption)
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
                            Text(sentence(q.sentence)).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(2)
                            Text(q.question).font(Theme.body)
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

/// Check coverage's report over the map: facts in the selected context the map lacks, each
/// with the lines that would add it.
struct CoverageOverlay: View {
    @Bindable var session: MapSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OverlayHeader(symbol: "text.badge.checkmark", title: "Coverage", subtitle: "What the selected context states that the map lacks.", close: { session.overlay = nil }) {
                Button("Check again") { session.checkCoverage() }.controlSize(.small).disabled(session.running != nil)
            }
            Divider()
            ScrollView {
                if let report = session.verifyReport {
                    VerifyList(session: session, report: report).padding(Theme.Space.m)
                }
            }
        }
    }
}

struct VerifyList: View {
    @Bindable var session: MapSession
    let report: VerifyReport

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(report.proposals.isEmpty ? "Everything in the context is on the map." : "\(report.proposals.count) facts the map lacks").font(Theme.label)
            ForEach(Array(report.proposals.enumerated()), id: \.offset) { _, proposal in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(session.state.evidence.sentences.first { $0.s == proposal.sentence }?.sentence ?? "s\(proposal.sentence)").font(Theme.body)
                        Text(proposal.lines.joined(separator: "\n")).font(Theme.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply") { session.applyProposal(proposal) }.controlSize(.small)
                }
                .rowCard()
            }
            ForEach(report.missingNodes, id: \.self) { name in
                Label("\(name) is marked as from the text but the model cannot find it", systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
