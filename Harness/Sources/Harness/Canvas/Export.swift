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

    /// The map as the canvas draws it (GridClip's style): left-to-right trees of cards,
    /// first-level branches in their own colour, cross-links dashed, provenance on the
    /// outlines (world dashed, guess dotted and faded, advice warm with a double border).
    public static func svg(_ graph: Graph, layout: MapLayout, palette: MapPalette = .light) -> String {
        typealias M = MapLayout.Metrics
        let pad = 24.0
        let x0 = layout.minX - pad, y0 = layout.minY - pad
        let w = max(layout.width + 2 * pad, 200), h = max(layout.height + 2 * pad, 120)
        var out = ["<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(fmt(x0)) \(fmt(y0)) \(fmt(w)) \(fmt(h))\" font-family=\"-apple-system, BlinkMacSystemFont, Helvetica, sans-serif\">"]
        out.append("<rect x=\"\(fmt(x0))\" y=\"\(fmt(y0))\" width=\"\(fmt(w))\" height=\"\(fmt(h))\" fill=\"\(palette.background)\"/>")
        out.append("<defs><marker id=\"arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\" markerUnits=\"userSpaceOnUse\"><path d=\"M0 1L10 5L0 9z\" fill=\"context-stroke\"/></marker></defs>")

        for e in layout.edges {
            let ink = palette.hue(e.branch)?.ink ?? palette.textTertiary
            var attrs = "fill=\"none\" stroke=\"\(ink)\" stroke-width=\"\(e.tree ? 2 : 1.5)\""
            switch (e.tree, graph.edges[e.key]?.note(kind: "src")) {
            case (_, "guess"): attrs += " stroke-dasharray=\"2 3\" opacity=\"0.7\""
            case (_, "world"): attrs += " stroke-dasharray=\"6 4\""
            case (false, _): attrs += " stroke-dasharray=\"5 4\""
            default: break
            }
            if e.arrowEnd { attrs += " marker-end=\"url(#arrow)\"" }
            if e.arrowStart { attrs += " marker-start=\"url(#arrow)\"" }
            out.append("<path d=\"M\(fmt(e.p0.x)) \(fmt(e.p0.y))C\(fmt(e.p1.x)) \(fmt(e.p1.y)) \(fmt(e.p2.x)) \(fmt(e.p2.y)) \(fmt(e.p3.x)) \(fmt(e.p3.y))\" \(attrs)/>")
        }

        for n in layout.nodes {
            guard let node = graph.nodes[n.id] else { continue }
            let src = node.note(kind: "src") ?? "text"
            let isRoot = n.depth == 0
            let weight = isRoot ? "600" : "500"
            out.append("<g class=\"node\" transform=\"translate(\(fmt(n.x)) \(fmt(n.y)))\"\(src == "guess" ? " opacity=\"0.75\"" : "")>")
            if n.boxed {
                // The model's extras: a card in its provenance's colours.
                let (fill, ink) = src == "world" ? (palette.world, palette.worldInk) : src == "advice" ? (palette.advice, palette.adviceInk) : (palette.guess, palette.guessInk)
                var stroke = "stroke=\"\(ink)\" stroke-width=\"1.5\""
                if src == "world" { stroke += " stroke-dasharray=\"5 4\"" } else if src == "guess" { stroke += " stroke-dasharray=\"2 3\"" }
                out.append("<rect width=\"\(fmt(n.w))\" height=\"\(fmt(n.h))\" rx=\"8\" fill=\"\(fill)\" \(stroke)/>")
                if src == "advice" {
                    out.append("<rect x=\"3\" y=\"3\" width=\"\(fmt(n.w - 6))\" height=\"\(fmt(n.h - 6))\" rx=\"5\" fill=\"none\" stroke=\"\(ink)\" stroke-width=\"1\"/>")
                }
                var textX = M.padX
                let nameY = M.padY + M.nameLine / 2
                if n.glyph {
                    out.append("<circle cx=\"\(fmt(textX + 5))\" cy=\"\(fmt(nameY))\" r=\"4.5\" fill=\"\(kindColour(node.note(kind: "kind")))\"/>")
                    textX += M.glyph
                }
                out.append("<text x=\"\(fmt(textX))\" y=\"\(fmt(nameY))\" dominant-baseline=\"central\" font-size=\"13\" font-weight=\"\(weight)\" fill=\"\(palette.textPrimary)\">\(escape(n.name))</text>")
                if n.badge {
                    let mark = ["world": "◎", "guess": "?", "advice": "✦"][src] ?? ""
                    out.append("<text x=\"\(fmt(n.w - M.padX - M.badge / 2 + 3))\" y=\"\(fmt(nameY))\" dominant-baseline=\"central\" text-anchor=\"middle\" font-size=\"11\" fill=\"\(ink)\">\(mark)</text>")
                }
                for (i, note) in n.notes.enumerated() {
                    let y = M.padY + M.nameLine + Double(i) * M.noteLine + M.noteLine / 2
                    out.append("<text x=\"\(fmt(M.padX))\" y=\"\(fmt(y))\" dominant-baseline=\"central\" font-size=\"11.5\" font-weight=\"500\" fill=\"\(palette.textSecondary)\">\(escape(note))</text>")
                }
            } else {
                // From the context or the user: the icon (here the kind's dot) above the name, no card.
                let cx = n.w / 2
                let iconY = M.openPadY + M.iconLine / 2
                out.append("<circle cx=\"\(fmt(cx))\" cy=\"\(fmt(iconY))\" r=\"10\" fill=\"\(kindColour(node.note(kind: "kind")))\"/>")
                if n.badge { out.append("<text x=\"\(fmt(cx + 15))\" y=\"\(fmt(iconY - 9))\" dominant-baseline=\"central\" text-anchor=\"middle\" font-size=\"10\" fill=\"\(palette.textTertiary)\">✎</text>") }
                let nameY = M.openPadY + M.iconLine + M.iconGap + M.nameLine / 2
                out.append("<text x=\"\(fmt(cx))\" y=\"\(fmt(nameY))\" dominant-baseline=\"central\" text-anchor=\"middle\" font-size=\"13\" font-weight=\"\(weight)\" fill=\"\(palette.textPrimary)\">\(escape(n.name))</text>")
                for (i, note) in n.notes.enumerated() {
                    let y = nameY + M.nameLine / 2 + Double(i) * M.noteLine + M.noteLine / 2
                    out.append("<text x=\"\(fmt(cx))\" y=\"\(fmt(y))\" dominant-baseline=\"central\" text-anchor=\"middle\" font-size=\"11.5\" font-weight=\"500\" fill=\"\(palette.textSecondary)\">\(escape(note))</text>")
                }
            }
            out.append("</g>")
        }

        // Labels last, with a halo of the background, so curves never run through them.
        for e in layout.edges {
            let lines = [e.label, e.note].filter { !$0.isEmpty }
            for (i, line) in lines.enumerated() {
                let y = e.labelAt.y + (Double(i) - Double(lines.count - 1) / 2) * M.labelLine
                let colour = i == 0 && !e.label.isEmpty ? palette.textSecondary : palette.textTertiary
                let style = e.tree ? "" : " font-style=\"italic\""
                out.append("<text x=\"\(fmt(e.labelAt.x))\" y=\"\(fmt(y))\" dominant-baseline=\"central\" text-anchor=\"middle\" font-size=\"10.5\" font-weight=\"500\"\(style) fill=\"\(colour)\" paint-order=\"stroke\" stroke=\"\(palette.background)\" stroke-width=\"4\" stroke-linejoin=\"round\">\(escape(line))</text>")
            }
        }
        out.append("</svg>")
        return out.joined(separator: "\n") + "\n"
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
