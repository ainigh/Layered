/// Canonical form (§4): one statement per edge, one per node note, the surviving
/// comments, grouped by scope and sorted. Lossless: compiling the canonical form
/// yields the same graph.
public enum Canonical {
    public static func render(_ graph: Graph) -> String {
        lines(for: graph).joined(separator: "\n") + (graph.nodes.isEmpty && graph.comments.isEmpty ? "" : "\n")
    }

    public static func lines(for graph: Graph) -> [String] {
        var out: [String] = []
        let scopes = [""] + graph.scopes.filter { !$0.isEmpty }.sorted()
        for scope in scopes {
            let body = lines(for: graph, scope: scope)
            if scope.isEmpty {
                out += body
            } else if !body.isEmpty || graph.scopes.contains(scope) {
                out.append("| @ \(scope)")
                out += body
            }
        }
        return out
    }

    private static func lines(for graph: Graph, scope: String) -> [String] {
        var out: [String] = []
        for comment in graph.comments where comment.scope == scope && !comment.isTurnHeader {
            out.append(comment.text)
        }

        // (sort key, line); the key keeps node declarations, then notes, then edges, per name.
        var keyed: [(String, Int, String, String)] = []
        for (id, node) in graph.nodes where id.scope == scope {
            if node.notes.isEmpty && graph.degree(of: id) == 0 {
                keyed.append((id.name, 0, "", "| \(id.name)"))
            }
            for note in node.notes {
                keyed.append((id.name, 1, note, "| \(id.name) @\(note)"))
            }
        }
        for edge in graph.edges.values where emittingScope(edge) == scope {
            let (from, to) = emittingOrder(edge)
            keyed.append((from.name, 2, to.description, Render.edge(edge, from: from, to: to, scope: scope)))
            if edge.isTwoWay {
                keyed.append((to.name, 2, from.description, Render.bareEdge(from: to, to: from, scope: scope)))
            }
        }
        keyed.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        out += keyed.map(\.3)
        return out
    }

    /// A cross-scope edge is listed under whichever of its scopes comes later in the
    /// canonical order (root first, then sorted), so both scopes exist when it is read back.
    static func emittingScope(_ edge: Edge) -> String {
        let a = edge.a.scope, b = edge.b.scope
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return max(a, b)
    }

    /// The line that carries labels and notes goes from the smaller node, unless the
    /// edge is one-way the other way.
    static func emittingOrder(_ edge: Edge) -> (NodeID, NodeID) {
        let key = edge.key
        if edge.backward && !edge.forward {
            return (edge.b, edge.a)
        }
        if edge.forward && !edge.backward {
            return (edge.a, edge.b)
        }
        return (key.lo, key.hi)
    }
}

/// Renders statements back to notation text, one line each.
public enum Render {
    public static func name(_ id: NodeID, in scope: String) -> String {
        id.scope == scope ? id.name : "\(id.name)@\(id.scope)"
    }

    static func edge(_ edge: Edge, from: NodeID, to: NodeID, scope: String) -> String {
        var parts = ["|", name(from, in: scope)]
        for label in edge.labels { parts += ["-", label] }
        for note in edge.notes { parts.append("@\(note)") }
        if edge.isUndirected { parts.append("-") }
        parts += ["|", name(to, in: scope)]
        return parts.joined(separator: " ")
    }

    static func bareEdge(from: NodeID, to: NodeID, scope: String) -> String {
        "| \(name(from, in: scope)) | \(name(to, in: scope))"
    }

    /// Renders a parsed path as the GBNF would: one space around each symbol.
    public static func path(_ path: Path) -> String {
        var parts = ["|", path.names[0].rendered]
        for (index, link) in path.links.enumerated() {
            for label in link.labels { parts += ["-", label] }
            for note in link.notes { parts.append("@\(note)") }
            if !link.directed { parts.append("-") }
            parts += ["|", path.names[index + 1].rendered]
        }
        for note in path.notes { parts.append("@\(note)") }
        return parts.joined(separator: " ")
    }

    public static func edit(_ edit: Edit) -> String {
        if let new = edit.new { return "| \(edit.old.rendered) = \(new.rendered)" }
        return "| \(edit.old.rendered) ="
    }

    public static func statement(_ statement: Statement) -> String {
        switch statement {
        case .path(let p): return path(p)
        case .edit(let e): return edit(e)
        }
    }
}
