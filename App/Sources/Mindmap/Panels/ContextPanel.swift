import SwiftUI
import Harness

/// The left pane: the context as a list of items. Each text added, recording transcribed,
/// clarification answered or reply the model wrote is an item that stays (new ones come in
/// from the bar at the bottom of the map). Clicking an item puts it in the current context
/// or takes it out (the model reads only what is selected); its send button puts what is
/// new in it on the map; its open button shows it over the map, where it can be read,
/// edited or listened to.
struct ContextPanel: View {
    @Bindable var session: MapSession
    @State private var showRemoved = false

    var body: some View {
        let items = session.state.context.items
        let shown = items.filter { showRemoved || !$0.removed }
        let removed = items.filter(\.removed).count
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                Text(summary(items)).font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                if removed > 0 {
                    Button(showRemoved ? "Hide deleted" : "\(removed) deleted") { withAnimation(Theme.slide) { showRemoved.toggle() } }
                        .buttonStyle(.plain).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(shown) { item in
                            ContextRow(session: session, item: item).id(item.id)
                        }
                        if let job = session.audioJob, job.running {
                            Button { session.overlay = .audio } label: {
                                HStack(spacing: Theme.Space.s) {
                                    Image(systemName: "waveform").foregroundStyle(Theme.origin(.audio).color)
                                    Text(job.file.lastPathComponent).font(Theme.label).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if let f = job.fraction { ProgressView(value: f).controlSize(.small).frame(width: 60) } else { ProgressView().controlSize(.small) }
                                }
                                .rowCard()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show its progress")
                        }
                        if items.isEmpty, session.audioJob?.running != true {
                            Text("Nothing yet. Add text or a recording from the bar below the map; each one becomes an item here.")
                                .font(Theme.caption).foregroundStyle(.tertiary).padding(.top, Theme.Space.s)
                        }
                    }
                }
                .onChange(of: items.count) { _, _ in
                    if let last = shown.last { withAnimation(Theme.slide) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func summary(_ items: [ContextItem]) -> String {
        let live = items.filter { !$0.removed }
        guard !live.isEmpty else { return "No context yet" }
        let pending = live.filter(\.isPending).count
        var parts = ["\(live.filter(\.selected).count) of \(live.count) selected"]
        if pending > 0 { parts.append("\(pending) not on the map yet") }
        return parts.joined(separator: " · ")
    }
}

/// One item: click to select or deselect it; its buttons send it to the map and open it
/// over the map.
struct ContextRow: View {
    @Bindable var session: MapSession
    let item: ContextItem

    var body: some View {
        let style = Theme.origin(item.origin)
        let audio = item.kind == .transcript ? item.textID.flatMap { session.audioURL(for: $0) } : nil
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(item.selected ? style.color : Color.secondary.opacity(0.6))
                .padding(.top, 1)
                .help(item.selected ? "In the context: the model reads it" : "Not in the context")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: style.symbol).font(Theme.caption).foregroundStyle(style.color)
                    Text(style.title).font(Theme.label).foregroundStyle(item.origin == .model ? style.color : .primary)
                    Text(item.added.formatted(date: .omitted, time: .shortened)).font(Theme.caption).foregroundStyle(.tertiary)
                    if item.edited != nil { Text("edited").font(Theme.caption).foregroundStyle(.tertiary) }
                    if item.isPending { Pill(text: item.lastExtracted == nil ? "not on map" : "changed", tint: Theme.accent) }
                    Spacer(minLength: 0)
                    if item.removed {
                        Button("Restore") { session.dispatch(.restoreContext(item.id)) }.controlSize(.small)
                    } else {
                        if let audio {
                            let playing = AudioPlayer.shared.isPlaying(audio)
                            MapToolButton(symbol: playing ? "stop.fill" : "play.fill", help: playing ? "Stop" : "Listen") {
                                if playing { AudioPlayer.shared.stop() } else { AudioPlayer.shared.play(audio) }
                            }
                        }
                        if item.kind != .model {
                            let busy = session.running != nil || session.sentenceWalk != nil
                            MapToolButton(symbol: item.isOnMap ? "checkmark" : "paperplane.fill",
                                          help: item.isOnMap ? "On the map" : busy ? "The model is busy; send it when it is done" : "Send to the map: what is new in it goes on the map",
                                          pressed: !item.isOnMap && item.selected) { session.send(item: item.id) }
                                .disabled(item.isOnMap || busy)
                        }
                        MapToolButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open over the map") { session.open(item: item.id) }
                        MapToolButton(symbol: "trash", help: "Delete: it leaves the list and the context; its ideas stay on the map. Restore it from the deleted items at the top") {
                            withAnimation(Theme.slide) { session.dispatch(.removeContext(item.id)) }
                        }
                    }
                }
                if let q = item.question {
                    Text("You asked: \(q)").font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(SentenceSplitter.preview(item.body, limit: 20)).font(Theme.caption).foregroundStyle(item.origin == .model ? Color.secondary : Color.primary)
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.origin == .model ? style.color.opacity(0.08) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2))
        .overlay(alignment: .leading) {
            // The model's replies carry a stripe of their colour, so they never pass for yours.
            if item.origin == .model { UnevenRoundedRectangle(topLeadingRadius: Theme.radiusSmall + 2, bottomLeadingRadius: Theme.radiusSmall + 2).fill(style.color).frame(width: 3) }
        }
        .opacity(item.removed ? 0.4 : item.selected ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !item.removed else { return }
            withAnimation(Theme.selection) { session.dispatch(.selectContext(item.id, !item.selected)) }
        }
        .contextMenu { ContextItemMenu(session: session, item: item) }
        .animation(Theme.selection, value: item.selected)
    }
}

/// An item's actions, in its row's menu and its overlay's.
struct ContextItemMenu: View {
    @Bindable var session: MapSession
    let item: ContextItem

    var body: some View {
        if item.removed {
            Button("Restore") { session.dispatch(.restoreContext(item.id)) }
        } else {
            Button("Open") { session.open(item: item.id) }
            Button(item.selected ? "Deselect" : "Select") { session.dispatch(.selectContext(item.id, !item.selected)) }
            if item.kind != .model, !item.isOnMap { Button("Send to the map") { session.send(item: item.id) }.disabled(session.running != nil) }
            Button("Ask me about this") { session.askMe(about: item.id) }.disabled(session.running != nil)
            Divider()
            Button("Select its ideas on the map") { session.overlay = nil; session.selectIdeas(of: item) }
            Button("Forget its ideas") { session.forgetIdeas(of: item) }
            Divider()
            Button("Delete", role: .destructive) { session.dispatch(.removeContext(item.id)) }
        }
    }
}

/// A small capsule label.
struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(Theme.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
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
