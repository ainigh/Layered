import Foundation

/// Exports (SPEC “Storage”): canonical `.mm`, Markdown outline, JSON graph, SVG.
public enum Export {
    public static func canonical(_ graph: Graph) -> String { Canonical.render(graph) }

    /// Headings, nodes as bullets, edges as sub-bullets.
    public static func markdown(_ graph: Graph) -> String {
        var out: [String] = []
        for item in Outline.build(graph) {
            if !item.title.isEmpty { out.append(String(repeating: "#", count: item.level) + " " + item.title) }
            for comment in item.comments { out.append(comment) }
            for name in item.nodes {
                let id = NodeID(name: name)
                let node = graph.nodes[id]!
                var line = "- \(name)"
                if let kind = node.note(kind: "kind") { line += " (\(kind))" }
                if let src = node.note(kind: "src"), src != "text" { line += " [\(src)]" }
                out.append(line)
                for comment in Outline.comments(attachedTo: name, in: graph) { out.append("  - _\(comment)_") }
                for edge in graph.edges(touching: id) where edge.a == id || edge.isUndirected && edge.key.lo == id {
                    let other = edge.a == id ? edge.b : edge.a
                    let arrow = edge.isUndirected ? "—" : (edge.isTwoWay ? "⇄" : "→")
                    let label = edge.labels.isEmpty ? "" : " " + edge.labels.joined(separator: ", ")
                    out.append("  - \(arrow)\(label) \(other.name)")
                }
            }
            if !item.nodes.isEmpty || !item.title.isEmpty { out.append("") }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public struct JSONGraph: Codable, Equatable {
        public struct JNode: Codable, Equatable {
            public var name: String
            public var kind: String?
            public var src: String?
            public var notes: [String]
            public var heading: [String]
            public var x: Double?
            public var y: Double?
        }
        public struct JEdge: Codable, Equatable {
            public var from: String
            public var to: String
            public var directed: Bool
            public var twoWay: Bool
            public var labels: [String]
            public var notes: [String]
        }
        public var nodes: [JNode]
        public var edges: [JEdge]
        public var comments: [String]
    }

    public static func json(_ graph: Graph, layout: Layout? = nil) throws -> Data {
        let nodes = graph.nodes.keys.sorted().filter { $0.scope.isEmpty }.map { id -> JSONGraph.JNode in
            let n = graph.nodes[id]!
            let p = layout?.positions[id.name]
            return .init(name: id.name, kind: n.note(kind: "kind"), src: n.note(kind: "src"), notes: n.notes, heading: n.heading, x: p?.x, y: p?.y)
        }
        let edges = graph.edges.values.sorted { $0.key < $1.key }.map { e -> JSONGraph.JEdge in
            let (from, to) = Canonical.emittingOrder(e)
            return .init(from: from.name, to: to.name, directed: !e.isUndirected, twoWay: e.isTwoWay, labels: e.labels, notes: e.notes)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(JSONGraph(nodes: nodes, edges: edges, comments: graph.comments.filter { !$0.isTurnHeader }.map(\.text)))
    }

    /// A plain SVG of the current layout with the provenance styles (SPEC “Node rendering”).
    public static func svg(_ graph: Graph, layout: Layout) -> String {
        let b = layout.bounds
        let w = max(b.maxX - b.minX, 200), h = max(b.maxY - b.minY, 200)
        var out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(fmt(b.minX)) \(fmt(b.minY)) \(fmt(w)) \(fmt(h))\" font-family=\"-apple-system, Helvetica, sans-serif\" font-size=\"12\">"]
        out.append("<rect x=\"\(fmt(b.minX))\" y=\"\(fmt(b.minY))\" width=\"\(fmt(w))\" height=\"\(fmt(h))\" fill=\"white\"/>")
        out.append("<defs><marker id=\"arrow\" viewBox=\"0 0 10 10\" refX=\"10\" refY=\"5\" markerWidth=\"8\" markerHeight=\"8\" orient=\"auto-start-reverse\"><path d=\"M 0 0 L 10 5 L 0 10 z\" fill=\"#666\"/></marker></defs>")
        for edge in graph.edges.values.sorted(by: { $0.key < $1.key }) {
            let (from, to) = Canonical.emittingOrder(edge)
            guard let p = layout.positions[from.name], let q = layout.positions[to.name] else { continue }
            let (x1, y1, x2, y2) = trim(p, q, graph)
            var attrs = "stroke=\"#666\" stroke-width=\"1.5\" fill=\"none\""
            if !edge.isUndirected { attrs += " marker-end=\"url(#arrow)\"" }
            if edge.isTwoWay { attrs += " marker-start=\"url(#arrow)\"" }
            if edge.note(kind: "src") == "guess" { attrs += " stroke-dasharray=\"2 3\"" } else if edge.note(kind: "src") == "world" { attrs += " stroke-dasharray=\"6 4\"" }
            out.append("<line x1=\"\(fmt(x1))\" y1=\"\(fmt(y1))\" x2=\"\(fmt(x2))\" y2=\"\(fmt(y2))\" \(attrs)/>")
            if !edge.labels.isEmpty {
                out.append("<text x=\"\(fmt((x1 + x2) / 2))\" y=\"\(fmt((y1 + y2) / 2 - 4))\" text-anchor=\"middle\" fill=\"#444\" font-size=\"10\">\(escape(edge.labels.joined(separator: ", ")))</text>")
            }
        }
        for id in graph.nodes.keys.sorted() where id.scope.isEmpty {
            guard let p = layout.positions[id.name], let node = graph.nodes[id] else { continue }
            let r = Layout.radius(degree: graph.degree(of: id))
            let src = node.note(kind: "src") ?? "text"
            let (dash, fill, opacity) = style(src)
            let colour = kindColour(node.note(kind: "kind"))
            let stroke = src == "advice" ? "stroke=\"\(colour)\" stroke-width=\"3\"" : "stroke=\"\(colour)\" stroke-width=\"1.5\""
            out.append("<g opacity=\"\(opacity)\">")
            out.append(shape(node.note(kind: "kind"), x: p.x, y: p.y, r: r, extra: "fill=\"\(fill)\" \(stroke)\(dash)"))
            if src == "advice" { out.append(shape(node.note(kind: "kind"), x: p.x, y: p.y, r: r - 4, extra: "fill=\"none\" stroke=\"\(colour)\" stroke-width=\"1\"")) }
            out.append("<text x=\"\(fmt(p.x))\" y=\"\(fmt(p.y + 4))\" text-anchor=\"middle\" fill=\"#111\">\(escape(id.name))</text>")
            out.append("</g>")
        }
        out.append("</svg>")
        return out.joined(separator: "\n") + "\n"
    }

    static func style(_ src: String) -> (String, String, String) {
        switch src {
        case "world": return (" stroke-dasharray=\"6 4\"", "#f3f3f3", "0.9")
        case "guess": return (" stroke-dasharray=\"2 3\"", "#f8f8f8", "0.7")
        case "advice": return ("", "#fff4e0", "1")
        default: return ("", "#ffffff", "1")
        }
    }

    public static func kindColour(_ kind: String?) -> String {
        switch kind {
        case "person": return "#3b7dd8"
        case "place": return "#2a9d8f"
        case "thing": return "#6c5ce7"
        case "action": return "#e07a1f"
        case "event": return "#d63a6a"
        case "idea": return "#c9a227"
        default: return "#555555"
        }
    }

    static func shape(_ kind: String?, x: Double, y: Double, r: Double, extra: String) -> String {
        switch kind {
        case "person": return "<rect x=\"\(fmt(x - r * 1.4))\" y=\"\(fmt(y - r * 0.8))\" width=\"\(fmt(r * 2.8))\" height=\"\(fmt(r * 1.6))\" rx=\"\(fmt(r * 0.8))\" \(extra)/>"
        case "place": return "<polygon points=\"\(polygon(x, y, r * 1.4, 6))\" \(extra)/>"
        case "thing": return "<rect x=\"\(fmt(x - r * 1.4))\" y=\"\(fmt(y - r * 0.8))\" width=\"\(fmt(r * 2.8))\" height=\"\(fmt(r * 1.6))\" rx=\"4\" \(extra)/>"
        case "action": return "<rect x=\"\(fmt(x - r * 1.4))\" y=\"\(fmt(y - r * 0.6))\" width=\"\(fmt(r * 2.8))\" height=\"\(fmt(r * 1.2))\" rx=\"\(fmt(r * 0.6))\" \(extra)/>"
        case "event": return "<polygon points=\"\(polygon(x, y, r * 1.5, 4))\" \(extra)/>"
        case "idea": return "<ellipse cx=\"\(fmt(x))\" cy=\"\(fmt(y))\" rx=\"\(fmt(r * 1.5))\" ry=\"\(fmt(r))\" \(extra)/>"
        default: return "<circle cx=\"\(fmt(x))\" cy=\"\(fmt(y))\" r=\"\(fmt(r))\" \(extra)/>"
        }
    }

    static func polygon(_ x: Double, _ y: Double, _ r: Double, _ n: Int) -> String {
        (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
            return "\(fmt(x + cos(a) * r)),\(fmt(y + sin(a) * r))"
        }.joined(separator: " ")
    }

    static func trim(_ p: Placed, _ q: Placed, _ graph: Graph) -> (Double, Double, Double, Double) {
        let rp = Layout.radius(degree: graph.degree(of: NodeID(name: p.name))) * 1.2
        let rq = Layout.radius(degree: graph.degree(of: NodeID(name: q.name))) * 1.2
        let dx = q.x - p.x, dy = q.y - p.y
        let d = max(sqrt(dx * dx + dy * dy), 1)
        return (p.x + dx / d * rp, p.y + dy / d * rp, q.x - dx / d * rq, q.y - dy / d * rq)
    }

    static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Import (SPEC): a `.mm` file is appended as one turn; a plain text file goes to the context.
public enum Import {
    public static func lines(fromMM text: String) throws -> [String] {
        try Parser(options: .strict).parse(text).map(\.raw)
    }
}
