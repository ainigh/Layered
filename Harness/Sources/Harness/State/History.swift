import Foundation

/// Lines that take graph `from` to graph `to` by appending only (SPEC “Undo”: an undo
/// appends a turn that reverses the previous one, using the snapshot from before it).
public enum Transition {
    public static func lines(from: Graph, to: Graph) -> [String] {
        let target = Canonical.render(to)
        let quick = incremental(from: from, to: to)
        if let check = try? apply(quick, to: from), Canonical.render(check) == target { return quick }
        let full = rebuild(from: from, to: to)
        return full
    }

    static func apply(_ lines: [String], to graph: Graph) throws -> Graph {
        var g = graph
        let parser = Parser()
        for line in lines { try g.apply(try parser.parseLine(line)) }
        return g
    }

    /// Delete what must go, rebuild nodes whose edges or notes must shrink, add the rest.
    static func incremental(from: Graph, to: Graph) -> [String] {
        var lines: [String] = []
        let fromNodes = Set(from.nodes.keys), toNodes = Set(to.nodes.keys)

        var rebuilt = Set<NodeID>()
        for id in fromNodes.intersection(toNodes) {
            let before = from.nodes[id]!, after = to.nodes[id]!
            if !before.notes.allSatisfy({ note in
                if let kind = NoteKind.split(note)?.kind, to.singleValuedNoteKinds.contains(kind) { return after.note(kind: kind) != nil }
                return after.notes.contains(note)
            }) { rebuilt.insert(id); continue }
            for edge in from.edges(touching: id) {
                guard let other = to.edges[edge.key], other.labels.allSatisfy(other.labels.contains),
                      Set(edge.labels).isSubset(of: other.labels), Set(edge.notes).isSubset(of: other.notes),
                      directionSubset(edge, of: other) else { rebuilt.insert(id); break }
            }
        }

        // Comments: delete removed ones (also deletes same-named nodes, which the rebuild re-adds).
        let toComments = to.comments.filter { !$0.isTurnHeader }
        let fromComments = from.comments.filter { !$0.isTurnHeader }
        for comment in fromComments where !toComments.contains(where: { $0.text == comment.text && $0.scope == comment.scope }) {
            lines.append("| \(comment.text) =")
            if fromNodes.contains(NodeID(scope: comment.scope, name: comment.text)) { rebuilt.insert(NodeID(scope: comment.scope, name: comment.text)) }
        }

        for id in fromNodes.subtracting(toNodes).sorted() { lines.append("| \(id.name) =") }
        for id in rebuilt.sorted() { lines.append("| \(id.name) =") }

        for comment in toComments where !fromComments.contains(where: { $0.text == comment.text && $0.scope == comment.scope }) {
            switch comment.attachedTo {
            case .node(let id): lines.append("| \(id.name)")
            case .edge(let key): lines.append("| \(key.lo.name) - | \(key.hi.name)")
            case nil: break
            }
            lines.append(comment.text)
        }

        for id in toNodes.sorted() {
            let node = to.nodes[id]!
            let fresh = !fromNodes.contains(id) || rebuilt.contains(id)
            let notes = fresh ? node.notes : node.notes.filter { !(from.nodes[id]!.notes.contains($0)) }
            if fresh && notes.isEmpty && to.degree(of: id) == 0 { lines.append("| \(id.name)") }
            for note in notes { lines.append("| \(id.name) @\(note)") }
        }
        for edge in to.edges.values.sorted(by: { $0.key < $1.key }) {
            let fresh = !fromNodes.contains(edge.a) || !fromNodes.contains(edge.b) || rebuilt.contains(edge.a) || rebuilt.contains(edge.b)
            if fresh || from.edges[edge.key] == nil || !edgeSubset(from.edges[edge.key]!, of: edge) {
                lines += edgeLines(edge)
            }
        }
        return lines
    }

    static func rebuild(from: Graph, to: Graph) -> [String] {
        var lines: [String] = []
        for comment in from.comments where !comment.isTurnHeader { lines.append("| \(comment.text) =") }
        for id in from.nodes.keys.sorted() { lines.append("| \(id.name) =") }
        lines += Canonical.lines(for: to)
        return lines
    }

    static func directionSubset(_ a: Edge, of b: Edge) -> Bool {
        let aFwd = a.forward ? (a.a, a.b) : nil, aBwd = a.backward ? (a.b, a.a) : nil
        func has(_ d: (NodeID, NodeID)?) -> Bool {
            guard let d else { return true }
            return (b.forward && b.a == d.0 && b.b == d.1) || (b.backward && b.b == d.0 && b.a == d.1)
        }
        return has(aFwd) && has(aBwd)
    }

    static func edgeSubset(_ a: Edge, of b: Edge) -> Bool {
        Set(a.labels).isSubset(of: b.labels) && Set(a.notes).isSubset(of: b.notes) && directionSubset(a, of: b)
    }

    static func edgeLines(_ edge: Edge) -> [String] {
        var sub = Graph()
        sub.nodes[edge.a] = Node(id: edge.a)
        sub.nodes[edge.b] = Node(id: edge.b)
        sub.edges[edge.key] = edge
        return Canonical.lines(for: sub)
    }
}

/// Coverage (SPEC “Coverage”): nodes with no sentence support, sentences with no node.
public struct Coverage: Equatable, Sendable {
    public var unsupportedNodes: [String]
    public var uncoveredSentences: [SentenceID]

    public static func compute(_ state: MapState) -> Coverage {
        var covered = Set<SentenceID>()
        var supported = Set<NodeID>()
        for node in state.graph.nodes.values {
            for note in node.notes { if let id = proof(note) { covered.insert(id); supported.insert(node.id) } }
        }
        for edge in state.graph.edges.values {
            for note in edge.notes { if let id = proof(note) { covered.insert(id); supported.formUnion([edge.a, edge.b]) } }
        }
        return Coverage(
            unsupportedNodes: state.graph.nodes.keys.filter { $0.scope.isEmpty && !supported.contains($0) }.map(\.name).sorted(),
            uncoveredSentences: state.evidence.sentences.map(\.id).filter { !covered.contains($0) })
    }

    static func proof(_ note: String) -> SentenceID? {
        guard let (kind, value) = NoteKind.split(note), kind == "text" else { return nil }
        return SentenceID.parse(noteValue: value)
    }

    /// Text ids that support a node: its own proof notes plus those on its edges.
    public static func supports(of id: NodeID, in graph: Graph) -> Set<Int> {
        var texts = Set<Int>()
        for note in graph.nodes[id]?.notes ?? [] { if let p = proof(note) { texts.insert(p.text) } }
        for edge in graph.edges(touching: id) { for note in edge.notes { if let p = proof(note) { texts.insert(p.text) } } }
        return texts
    }
}

/// The Proof panel's data: the exact sentences behind a selection, each once, with
/// chips for the nodes it supports.
public struct ProofEntry: Equatable, Sendable {
    public var sentence: Sentence
    public var nodes: [String]
}

public enum Proof {
    public static func entries(for names: [String], in state: MapState) -> [ProofEntry] {
        var byID: [SentenceID: Set<String>] = [:]
        for name in names {
            let id = NodeID(name: name)
            for note in state.graph.nodes[id]?.notes ?? [] { if let p = Coverage.proof(note) { byID[p, default: []].insert(name) } }
            for edge in state.graph.edges(touching: id) {
                for note in edge.notes { if let p = Coverage.proof(note) { byID[p, default: []].insert(name) } }
            }
        }
        return byID.keys.sorted().compactMap { id in
            guard let sentence = state.evidence.sentence(id) else { return nil }
            return ProofEntry(sentence: sentence, nodes: byID[id]!.sorted())
        }
    }

    /// Every node a sentence supports (click a sentence → highlight on the canvas).
    public static func nodes(supportedBy id: SentenceID, in graph: Graph) -> [String] {
        var out = Set<String>()
        let note = Sentence(text: id.text, s: id.s, sentence: "").proofNote
        for node in graph.nodes.values where node.notes.contains(note) { out.insert(node.id.name) }
        for edge in graph.edges.values where edge.notes.contains(note) { out.formUnion([edge.a.name, edge.b.name]) }
        return out.sorted()
    }
}

/// Dedupe (SPEC “Duplicates”): the harness's cheap pass, and the model's proposals.
public struct DedupeProposal: Equatable, Sendable, Hashable {
    public enum Source: String, Sendable { case harness, model }
    public var old: String
    public var new: String
    public var reason: String
    public var source: Source
}

public enum Dedupe {
    public static func cheapPass(_ graph: Graph) -> [DedupeProposal] {
        Canonicaliser.likelyDuplicates(in: graph.rootNames).map { a, b, reason in
            // Keep the name with more edges; on a tie, the shorter.
            let da = graph.degree(of: NodeID(name: a)), db = graph.degree(of: NodeID(name: b))
            let keep = da != db ? (da > db ? a : b) : (a.count <= b.count ? a : b)
            let drop = keep == a ? b : a
            return DedupeProposal(old: drop, new: keep, reason: reason, source: .harness)
        }
    }

    /// Pairs `| old = new` lines with the reason comment under each, from gated model output.
    public static func proposals(fromGated lines: [String]) -> [DedupeProposal] {
        var out: [DedupeProposal] = []
        for line in lines {
            if line.hasPrefix("|"), case .statement(.edit(let edit))? = try? Parser(options: .strict).parseLine(line), let new = edit.new {
                out.append(DedupeProposal(old: edit.old.text, new: new.text, reason: "", source: .model))
            } else if !line.hasPrefix("|"), !out.isEmpty, out[out.count - 1].reason.isEmpty {
                out[out.count - 1].reason = line
            }
        }
        return out
    }
}

/// The Outline panel: headings as a tree, nodes under the heading they were declared in,
/// and comments attached to nodes.
public struct OutlineItem: Equatable, Sendable {
    public var title: String
    public var level: Int
    public var nodes: [String]
    public var comments: [String]
}

public enum Outline {
    public static func build(_ graph: Graph) -> [OutlineItem] {
        var items: [OutlineItem] = [OutlineItem(title: "", level: 0, nodes: [], comments: [])]
        var index: [[String]: Int] = [[]: 0]
        for comment in graph.comments where comment.isHeading {
            index[comment.heading] = items.count
            items.append(OutlineItem(title: comment.headingTitle, level: comment.heading.count, nodes: [], comments: []))
        }
        for id in graph.nodes.keys.sorted() where id.scope.isEmpty {
            let heading = graph.nodes[id]!.heading
            items[index[heading] ?? 0].nodes.append(id.name)
        }
        for comment in graph.comments where !comment.isHeading && !comment.isTurnHeader {
            items[index[comment.heading] ?? 0].comments.append(comment.text)
        }
        return items
    }

    public static func comments(attachedTo name: String, in graph: Graph) -> [String] {
        graph.comments.filter { $0.attachedTo == .node(NodeID(name: name)) }.map(\.text)
    }
}
