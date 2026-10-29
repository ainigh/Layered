import SwiftUI
import Harness

/// The right pane's first panel: what the selected node is. Its proof sentences are its
/// description, each with the context item it came from (click to open it over the map)
/// and, for a recording, a button that plays the moment it was said. Then its notes, its
/// links and what can be done with it. Several nodes show the union of their proof.
struct DetailsPanel: View {
    @Bindable var session: MapSession

    var body: some View {
        let names = session.selection.sorted()
        let graph = session.state.graph
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if names.count == 1, let node = graph.node(names[0]) {
                    NodeDetails(session: session, node: node)
                } else if names.count > 1 {
                    HStack { ForEach(names, id: \.self) { NodeChip(name: $0, graph: graph) } }
                    ProofList(session: session, entries: Proof.entries(for: names, in: session.state), empty: "None of these has proof sentences.")
                } else if let key = session.selectedEdge, let edge = graph.edges[key] {
                    EdgeDetails(session: session, edge: edge)
                } else {
                    Text("Click a node to see what it is and where it came from.").font(Theme.body).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NodeDetails: View {
    @Bindable var session: MapSession
    let node: Node

    var body: some View {
        let graph = session.state.graph
        let name = node.id.name
        let kind = node.note(kind: "kind")
        let src = node.note(kind: "src")
        let symbol = session.icons.icons(for: name).first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? IconManifest.fallbackSymbol(kind: kind)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Image(systemName: symbol).font(.system(size: Theme.Map.iconSize)).foregroundStyle(Theme.kind(kind)).frame(width: 36)
                Text(name).font(Theme.title).lineLimit(3).textSelection(.enabled)
            }
            HStack(spacing: Theme.Space.xs) {
                if let kind { Pill(text: kind, tint: Theme.kind(kind)) }
                Pill(text: Provenance.title(src), tint: Provenance.tint(src))
                if node.note(kind: "pos") != nil { Pill(text: "pinned") }
                Pill(text: "\(graph.degree(of: node.id)) links")
            }

            ProofList(session: session, entries: Proof.entries(for: [name], in: session.state), empty: Provenance.noProof(src))

            let notes = MapLayout.shownNotes(node)
            let comments = Outline.comments(attachedTo: name, in: graph)
            if !notes.isEmpty || !comments.isEmpty {
                SectionTitle("Notes")
                ForEach(notes, id: \.self) { Text($0).font(Theme.caption) }
                ForEach(comments, id: \.self) { Text($0).font(Theme.caption).italic().foregroundStyle(.secondary) }
            }

            let edges = graph.edges(touching: node.id).sorted { $0.key < $1.key }
            if !edges.isEmpty {
                SectionTitle("Links", count: edges.count)
                ForEach(edges, id: \.key) { edge in
                    let other = edge.a == node.id ? edge.b.name : edge.a.name
                    let out = edge.a == node.id ? edge.forward : edge.backward
                    Button { session.selection = [other] } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Image(systemName: out ? "arrow.right" : "arrow.left").font(Theme.caption).foregroundStyle(.tertiary)
                            if !edge.labels.isEmpty { Text(edge.labels.joined(separator: ", ")).font(Theme.caption).foregroundStyle(.secondary) }
                            NodeChip(name: other, graph: graph)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button { session.expand(name) } label: { Label("Expand", systemImage: "sparkles") }
                    .disabled(session.running != nil)
                if ["world", "guess", "advice"].contains(src ?? "") {
                    Button { session.dispatch(.confirm(name)) } label: { Label("Confirm", systemImage: "checkmark") }
                        .help("Mark it as yours")
                }
            }
            .controlSize(.small)
        }
    }
}

struct EdgeDetails: View {
    @Bindable var session: MapSession
    let edge: Edge

    var body: some View {
        let graph = session.state.graph
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.xs) {
                NodeChip(name: edge.a.name, graph: graph)
                Text(edge.labels.isEmpty ? "–" : edge.labels.joined(separator: ", ")).font(Theme.body)
                NodeChip(name: edge.b.name, graph: graph)
            }
            Pill(text: Provenance.title(edge.note(kind: "src")), tint: Provenance.tint(edge.note(kind: "src")))
            ProofList(session: session, entries: Proof.entries(forEdge: edge.key, in: session.state), empty: Provenance.noProof(edge.note(kind: "src")))
            let notes = MapLayout.shownEdgeNotes(edge)
            let comments = graph.comments.filter { $0.attachedTo == .edge(edge.key) }.map(\.text)
            if !notes.isEmpty || !comments.isEmpty {
                SectionTitle("Notes")
                ForEach(notes, id: \.self) { Text($0).font(Theme.caption) }
                ForEach(comments, id: \.self) { Text($0).font(Theme.caption).italic().foregroundStyle(.secondary) }
            }
        }
    }
}

/// Proof sentences as a description: the sentence, then where it came from.
struct ProofList: View {
    @Bindable var session: MapSession
    let entries: [ProofEntry]
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if entries.isEmpty {
                Text(empty).font(Theme.body).foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.sentence.id) { entry in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(entry.sentence.sentence)
                        .font(Theme.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    source(entry.sentence)
                    if entry.nodes.count > 1 {
                        HStack { ForEach(entry.nodes, id: \.self) { NodeChip(name: $0, graph: session.state.graph) } }
                    }
                }
                .padding(.leading, Theme.Space.s)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2) }
            }
        }
    }

    /// The item the sentence came from (opens it), its speaker, and a play button for audio.
    private func source(_ s: Sentence) -> some View {
        let item = session.state.context.item(forText: s.text)
        let style = item.map { Theme.origin($0.origin) }
        let audio = s.t0 != nil ? session.audioURL(for: s.text) : nil
        return HStack(spacing: Theme.Space.xs) {
            if let item, let style {
                Button { session.open(item: item.id) } label: {
                    Label("\(style.title) · item \(item.id)", systemImage: style.symbol)
                }
                .buttonStyle(.plain)
                .foregroundStyle(style.color)
                .help("Open the item over the map")
            } else {
                Text("text \(s.text)")
            }
            Text("s\(s.s)").foregroundStyle(.tertiary)
            if let speaker = s.speaker { Text(session.state.speakers.name(for: speaker) ?? speaker).foregroundStyle(.secondary) }
            if let audio, let t0 = s.t0 {
                let playing = AudioPlayer.shared.isPlaying(audio, from: t0)
                Button { if playing { AudioPlayer.shared.stop() } else { AudioPlayer.shared.play(audio, from: t0, to: s.t1) } } label: {
                    Label(Clock.stamp(t0), systemImage: playing ? "stop.circle" : "play.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("Play the moment it was said")
            }
            Spacer(minLength: 0)
        }
        .font(Theme.caption)
        .labelStyle(StatusLabelStyle())
    }
}

/// `01:23`, as transcripts print times.
enum Clock {
    static func stamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

extension Provenance {
    /// How a node's provenance reads in its details.
    static func title(_ src: String?) -> String {
        switch src {
        case "world": return "world knowledge"
        case "guess": return "a guess"
        case "advice": return "advice"
        case "user": return "yours"
        default: return "from your context"
        }
    }

    static func tint(_ src: String?) -> Color {
        switch src {
        case "world", "guess", "advice": return Theme.Map.cardColours(src).ink
        case "user": return Theme.accent
        default: return Theme.origin(.you).color
        }
    }

    /// What its description says when no sentence supports it.
    static func noProof(_ src: String?) -> String {
        switch src {
        case "world": return "The model added this from general knowledge; nothing in your context says it."
        case "guess": return "The model's guess; nothing in your context says it."
        case "advice": return "The model's advice: something to do, consider or avoid."
        case "user": return "You added or confirmed this."
        default: return "No sentence in your context supports this yet."
        }
    }
}
