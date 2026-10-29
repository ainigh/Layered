import SwiftUI
import Harness
import AVFoundation

struct ContextPanel: View {
    @Bindable var session: MapSession
    @State private var sentenceMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TextEditor(text: $session.contextDraft)
                .font(Theme.body)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s)
                .frame(minHeight: 180, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2).strokeBorder(Color.primary.opacity(0.1)))
                .onChange(of: session.contextDraft) { _, _ in session.saveDraft() }
                .overlay(alignment: .topLeading) {
                    if session.contextDraft.isEmpty {
                        Text("Paste or type text here, or drop an audio file on the map.")
                            .font(Theme.body).foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Space.s + 5).padding(.vertical, Theme.Space.s)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: Theme.Space.s) {
                Picker("Submit", selection: $sentenceMode) {
                    Text("All at once").tag(false)
                    Text("Sentence by sentence").tag(true)
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                Spacer()
                Button("Check coverage") { session.checkCoverage() }.disabled(session.running != nil)
                Button("Submit") { session.submit(sentenceMode: sentenceMode) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.running != nil || session.contextDraft == session.submittedDraft)
            }
            .controlSize(.regular)
            if let walk = session.sentenceWalk {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack {
                        ProgressView(value: walk.progress)
                        Text("\(walk.index + 1) of \(walk.sentences.count)").font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button(walk.paused ? "Resume" : "Pause") {
                            session.sentenceWalk?.paused.toggle()
                            if session.sentenceWalk?.paused == false { Task { await session.walkSentences() } }
                        }.controlSize(.small)
                    }
                    if let s = walk.current { Text(s.sentence).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            if let report = session.verifyReport {
                VerifyList(session: session, report: report)
            }
            let sources = session.state.context.paragraphs.filter { $0.textID != nil }
            if !sources.isEmpty {
                SectionTitle("Sources", count: sources.count)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(sources, id: \.textID) { p in
                            HStack(alignment: .top, spacing: Theme.Space.s) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Text \(p.textID!) · \(p.kind.rawValue)").font(Theme.label)
                                    Text(p.body).font(Theme.caption).lineLimit(2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Menu {
                                    Button("Select its ideas on the map") {
                                        session.selection = Set(session.state.graph.nodes.keys.filter { Coverage.supports(of: $0, in: session.state.graph).contains(p.textID!) }.map(\.name))
                                    }
                                    Button("Forget this text", role: .destructive) { session.dispatch(.forgetText(p.textID!)) }
                                } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }
                            .rowCard()
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

/// A small section heading inside a panel, with an optional count.
struct SectionTitle: View {
    let title: String
    var count: Int?
    init(_ title: String, count: Int? = nil) { self.title = title; self.count = count }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(title).font(Theme.label).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(Theme.caption).foregroundStyle(.tertiary).monospacedDigit() }
        }
        .padding(.top, Theme.Space.xs)
    }
}

extension View {
    /// A list row on a quiet rounded surface, the one row style panels use.
    func rowCard() -> some View {
        padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2))
    }
}

struct VerifyList: View {
    @Bindable var session: MapSession
    let report: VerifyReport

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(report.proposals.isEmpty ? "Everything in the text is on the map." : "\(report.proposals.count) facts the map lacks").font(Theme.label)
            ForEach(Array(report.proposals.enumerated()), id: \.offset) { _, proposal in
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(session.state.evidence.sentences.first { $0.s == proposal.sentence }?.sentence ?? "s\(proposal.sentence)").font(Theme.caption)
                        Text(proposal.lines.joined(separator: "\n")).font(Theme.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply") { session.applyProposal(proposal) }.font(Theme.caption)
                }
            }
            ForEach(report.missingNodes, id: \.self) { name in
                Label("\(name) is marked as from the text but the model cannot find it", systemImage: "exclamationmark.triangle").font(Theme.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct ClarifyPanel: View {
    @Bindable var session: MapSession
    @State private var answers: [Int: String] = [:]
    @State private var speakerNames: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Button("Ask me") { session.askMe() }.buttonStyle(.borderedProminent).disabled(session.running != nil)
                Toggle("context only", isOn: $session.clarifyContextOnly).toggleStyle(.switch).controlSize(.small)
            }
            Text("Clarify runs only when you press Ask me.").font(Theme.caption).foregroundStyle(.secondary)
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
                SectionTitle("Speakers")
                ForEach(labels, id: \.self) { label in
                    HStack {
                        Text(label).frame(width: 80, alignment: .leading)
                        TextField("name", text: Binding(get: { speakerNames[label] ?? session.state.speakers.names[label.lowercased()] ?? "" }, set: { speakerNames[label] = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Button("Set") {
                            if let name = speakerNames[label], !name.isEmpty { session.dispatch(.nameSpeaker(label: label, name: name)) }
                        }
                    }
                }
            }
            SectionTitle("Add context by hand")
            AddContextField(session: session)
        }
    }

    private func sentence(_ n: Int) -> String {
        session.state.evidence.sentences.last { $0.s == n }?.sentence ?? ""
    }

    private func answer(_ i: Int, _ q: ClarifyQuestion) {
        guard let text = answers[i], !text.isEmpty else { return }
        session.dispatch(.answer(q, text))
        answers[i] = nil
        session.clarifyQuestions.remove(at: i)
    }
}

struct AddContextField: View {
    @Bindable var session: MapSession
    @State private var text = ""
    var body: some View {
        HStack {
            TextField("who said what, the setting, anything the text assumes", text: $text).textFieldStyle(.roundedBorder).onSubmit(add)
            Button("Add", action: add).disabled(text.isEmpty)
        }
    }
    private func add() {
        session.dispatch(.answer(nil, text))
        text = ""
    }
}

struct ProofPanel: View {
    @Bindable var session: MapSession
    @State private var player: AVAudioPlayer?

    var body: some View {
        let names = session.selection.sorted()
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if names.isEmpty, let key = session.selectedEdge {
                Text("Edge \(key.lo.name) – \(key.hi.name)").font(Theme.label)
                edgeDetail(key)
            } else if names.isEmpty {
                Text("Select a node to see the sentences it came from.").foregroundStyle(.secondary)
            } else {
                HStack { ForEach(names, id: \.self) { NodeChip(name: $0, graph: session.state.graph) } }
                let entries = Proof.entries(for: names, in: session.state)
                if entries.isEmpty {
                    Text(names.count == 1 ? "No proof: this is not a text node." : "No proof sentences.").foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(entries, id: \.sentence.id) { entry in
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                HStack {
                                    Text("text \(entry.sentence.text) · s\(entry.sentence.s)").font(Theme.label).foregroundStyle(.secondary)
                                    if let sp = entry.sentence.speaker { Text(sp).font(Theme.caption).foregroundStyle(.tertiary) }
                                    Spacer()
                                    if let t0 = entry.sentence.t0, let url = session.audioURL(for: entry.sentence.text) {
                                        Button { play(url, from: t0, to: entry.sentence.t1) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain)
                                    }
                                }
                                Text(entry.sentence.sentence).font(Theme.body)
                                    .onTapGesture { session.selection = Set(Proof.nodes(supportedBy: entry.sentence.id, in: session.state.graph)) }
                                HStack { ForEach(entry.nodes, id: \.self) { NodeChip(name: $0, graph: session.state.graph) } }
                            }
                            .rowCard()
                        }
                    }
                }
                if names.count == 1, let node = session.state.graph.node(names[0]) {
                    SectionTitle("Notes")
                    ForEach(node.notes, id: \.self) { Text($0).font(Theme.caption) }
                    ForEach(Outline.comments(attachedTo: names[0], in: session.state.graph), id: \.self) { Text($0).font(Theme.caption).italic() }
                }
            }
        }
    }

    @ViewBuilder
    private func edgeDetail(_ key: EdgeKey) -> some View {
        if let edge = session.state.graph.edges[key] {
            Text(edge.labels.joined(separator: ", ")).font(Theme.body)
            ForEach(edge.notes, id: \.self) { Text($0).font(Theme.caption) }
            ForEach(session.state.graph.comments.filter { $0.attachedTo == .edge(key) }, id: \.text) { Text($0.text).font(Theme.caption).italic() }
        }
    }

    private func play(_ url: URL, from t0: Double, to t1: Double?) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.currentTime = t0
        player?.play()
        let length = max((t1 ?? t0 + 3) - t0, 1.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + length) { [weak player] in player?.stop() }
    }
}

struct NodeChip: View {
    let name: String
    let graph: Graph
    var body: some View {
        let node = graph.node(name)
        Text(name)
            .font(Theme.caption)
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 2)
            .background(Theme.kind(node?.note(kind: "kind")).opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(Theme.kind(node?.note(kind: "kind")), lineWidth: 1))
    }
}

struct ChatPanel: View {
    @Bindable var session: MapSession
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(session.chatLog.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.who).font(Theme.label).foregroundStyle(.secondary)
                            Text(entry.text).font(Theme.body).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: entry.who == "you" ? .trailing : .leading)
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                TextField("Ask about the map; your message joins the context", text: $message).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Send", action: send).disabled(message.isEmpty || session.running != nil)
            }
        }
    }
    private func send() {
        guard !message.isEmpty else { return }
        session.chat(message)
        message = ""
    }
}

struct OutlinePanel: View {
    @Bindable var session: MapSession
    @State private var confirmed: Set<DedupeProposal> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(Array(Outline.build(session.state.graph).enumerated()), id: \.offset) { _, item in
                        if !item.title.isEmpty {
                            HStack {
                                Button {
                                    if let i = session.ui.collapsedHeadings.firstIndex(of: item.title) { session.ui.collapsedHeadings.remove(at: i) } else { session.ui.collapsedHeadings.append(item.title) }
                                    session.saveUI()
                                } label: { Image(systemName: session.ui.collapsedHeadings.contains(item.title) ? "chevron.right" : "chevron.down") }.buttonStyle(.plain)
                                Text(item.title).font(Theme.label)
                            }
                            .padding(.leading, CGFloat(item.level - 1) * Theme.Space.m)
                        }
                        if !session.ui.collapsedHeadings.contains(item.title) {
                            ForEach(item.comments, id: \.self) { Text($0).font(Theme.caption).italic().foregroundStyle(.secondary).padding(.leading, CGFloat(item.level) * Theme.Space.m) }
                            ForEach(item.nodes, id: \.self) { name in
                                VStack(alignment: .leading, spacing: 1) {
                                    Button { session.selection = [name] } label: {
                                        HStack { NodeChip(name: name, graph: session.state.graph); Spacer() }
                                    }.buttonStyle(.plain)
                                    ForEach(Outline.comments(attachedTo: name, in: session.state.graph), id: \.self) { Text($0).font(Theme.caption).italic().padding(.leading, Theme.Space.m) }
                                }
                                .padding(.leading, CGFloat(item.level) * Theme.Space.m)
                                .draggable(name)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let dragged = items.first, dragged != name, !item.title.isEmpty else { return false }
                                    session.dispatch(.applyLines(["# \(item.title)", "| \(dragged)"], what: "move \(dragged) under \(item.title)"))
                                    return true
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 200)
            Divider()
            Button("Find duplicates") { session.findDuplicates() }.disabled(session.running != nil)
            ForEach(session.dedupeProposals, id: \.self) { p in
                HStack {
                    Toggle(isOn: Binding(get: { confirmed.contains(p) }, set: { if $0 { confirmed.insert(p) } else { confirmed.remove(p) } })) {
                        VStack(alignment: .leading) {
                            Text("\(p.old) → \(p.new)").font(Theme.body)
                            Text("\(p.reason) (\(p.source.rawValue))").font(Theme.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !session.dedupeProposals.isEmpty {
                Button("Merge \(confirmed.count) confirmed") {
                    for p in session.dedupeProposals where confirmed.contains(p) { session.dispatch(.merge(p)) }
                    session.dedupeProposals.removeAll { confirmed.contains($0) }
                    confirmed = []
                }.disabled(confirmed.isEmpty)
            }
        }
    }
}
