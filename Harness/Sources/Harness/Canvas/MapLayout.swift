import Foundation

/// The mind map's geometry: the graph laid out as left-to-right trees, stacked top to
/// bottom, the way GridClip draws a map. Pure (text is measured by a function the caller
/// passes), so it is tested without a screen.
///
///   [ana] ── plans ──▶ [paper] ── has ──▶ [related work]
///                         └──── cites ──▶ [experiment] ── runs on ──▶ [lab cluster]
///
/// Roots are the nodes nothing points at, the best-connected first; a breadth-first walk
/// along outgoing and undirected edges hangs every other node under the first node that
/// reaches it. Up to three nodes linked to nothing sit at the very top; the trees follow,
/// largest first. Edges the trees do not use (cycles, second parents) are cross-links, drawn
/// dashed. A node with `@pos` keeps that place (its centre) and its edges follow it.
///
/// A node from the context or the user (`src text` or `src user`) is open: its icon above
/// its name, no card, edges meeting the icon. The model's extras (`world`, `guess`,
/// `advice`) are cards, so they can never be mistaken for what the text says.
public struct MapLayout: Equatable, Sendable {
    /// What a piece of text is set in: the node name, a note under it, or an edge label.
    public enum TextRole: Sendable { case name, note, label }
    /// Width of `text` in points when set as `role`.
    public typealias Measure = (String, TextRole) -> Double

    /// Line heights, paddings and gaps, in points. Font sizes live in the app's `Theme`.
    public enum Metrics {
        public static let nameLine = 18.0
        public static let noteLine = 16.0
        public static let labelLine = 15.0
        public static let padX = 12.0
        public static let padY = 7.0
        /// Room for the glyph before the name (the node's icon or kind).
        public static let glyph = 20.0
        /// Room for the provenance badge after the name.
        public static let badge = 18.0
        /// Node text is cut with an ellipsis past this width.
        public static let maxText = 240.0
        /// Vertical space between sibling subtrees, and between trees.
        public static let siblingGap = 12.0
        public static let treeGap = 28.0
        /// How many nodes linked to nothing are drawn first, at the top; the rest come last.
        public static let unlinkedFirst = 3
        /// Horizontal space between depth columns: at least `minColumnGap`, more for labels.
        public static let minColumnGap = 56.0
        public static let maxColumnGap = 260.0
        /// Notes shown under a name; the rest are in the hover card.
        public static let maxNotes = 3
        /// An open node: the icon's line (its symbol is set at twice the name's size), the
        /// box edges meet beside it, the gap above the name, and the padding around it all.
        public static let iconLine = 30.0
        public static let iconBox = 32.0
        /// Several icons for one name are stacked left to right, each over the one after it
        /// and overlapping it by about 40%, so a part of each shows; past `maxIcons`, a “+n”.
        public static let iconStep = 18.0
        public static let maxIcons = 3
        public static let moreIcons = 18.0
        /// A card's small glyphs, stacked the same way.
        public static let glyphStep = 8.0
        public static let iconGap = 2.0
        public static let openPadX = 6.0
        public static let openPadY = 4.0

        /// How wide an open node's stack of `n` icons is.
        public static func iconStack(_ n: Int) -> Double {
            iconBox + Double(max(0, min(n, maxIcons) - 1)) * iconStep + (n > maxIcons ? moreIcons : 0)
        }

        /// The room a card's `n` glyphs take before its name.
        public static func glyphRoom(_ n: Int) -> Double {
            glyph + Double(max(0, min(n, maxIcons) - 1)) * glyphStep
        }
    }

    /// Note kinds the canvas does not print under a name: they are drawn another way
    /// (`kind` as the glyph, `src` as the outline and badge, `pos` as the place) or are
    /// proof (`text`), which the Proof panel shows.
    public static let hiddenNoteKinds: Set<String> = ["src", "kind", "icon", "pos", "text"]

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public struct PlacedNode: Equatable, Sendable {
        public let id: NodeID
        /// The name and notes as shown (cut to `maxText`).
        public let name: String
        public let notes: [String]
        /// Was the name or a note cut, or are notes left out? Then the hover card has it all.
        public let cut: Bool
        /// 0 for a tree's root.
        public let depth: Int
        /// Which first-level branch the node hangs from, 1-based across the whole map, so
        /// each branch can take its own colour; 0 for roots.
        public let branch: Int
        public let glyph: Bool
        /// How many icons it shows (stacked when more than one), at least 1.
        public let icons: Int
        public let badge: Bool
        /// Kept where `@pos` puts it (or about to be: `placing` marks what it moved).
        public internal(set) var pinned: Bool
        /// A card (the model's extras) or open (icon above name).
        public let boxed: Bool
        /// Top-left corner and size.
        public var x: Double
        public var y: Double
        public let w: Double
        public let h: Double

        public var center: Point { Point(x: x + w / 2, y: y + h / 2) }
        /// Where edges meet the node: this far down from its top, and this far in from its
        /// sides (a card's edges meet its sides at mid-height; an open node's meet its icon).
        public var anchorY: Double { boxed ? h / 2 : Metrics.openPadY + Metrics.iconLine / 2 }
        public var anchorInset: Double { boxed ? 0 : max(0, (w - Metrics.iconStack(icons)) / 2) }
        public func contains(_ p: Point) -> Bool { p.x >= x && p.x <= x + w && p.y >= y && p.y <= y + h }
    }

    public struct PlacedEdge: Equatable, Sendable {
        public let key: EdgeKey
        /// Part of a tree (a solid curve) or a cross-link (dashed).
        public let tree: Bool
        /// A tree edge's branch (its child's); 0 for cross-links.
        public let branch: Int
        /// A cubic from `p0` to `p3`, drawn left to right where the nodes allow it.
        public var p0: Point
        public var p1: Point
        public var p2: Point
        public var p3: Point
        public var arrowStart: Bool
        public var arrowEnd: Bool
        /// Where the label sits (its centre), and its two lines (either may be empty).
        public var labelAt: Point
        public let label: String
        public let note: String

        /// The point at `t` along the curve, for hit testing.
        public func point(at t: Double) -> Point {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return Point(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
        }
    }

    /// Nodes in drawing order, and the same by name.
    public private(set) var nodes: [PlacedNode] = []
    public private(set) var index: [String: Int] = [:]
    public private(set) var edges: [PlacedEdge] = []
    /// The box that holds every node and label, in map points.
    public private(set) var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public subscript(name: String) -> PlacedNode? { index[name].map { nodes[$0] } }

    public init() {}

    /// A rough measure for when no renderer is at hand (tests, the harness).
    public static let estimate: Measure = { text, role in Double(text.count) * (role == .name ? 7.2 : 6.4) }

    /// The graph with every `@pos` pin left out: what the map looks like arranged afresh.
    public static func unpinned(_ graph: Graph) -> Graph {
        var out = graph
        for (id, node) in graph.nodes where node.note(kind: "pos") != nil {
            out.nodes[id]?.notes.removeAll { NoteKind.split($0)?.kind == "pos" }
        }
        return out
    }

    /// Does the node get a glyph before its name? By default when it has a kind or an icon.
    public static func defaultGlyph(_ node: Node) -> Bool {
        node.note(kind: "kind") != nil || node.note(kind: "icon") != nil
    }

    /// Is the node drawn as a card? Only the model's extras are; what came from the context
    /// or the user (and a node with no provenance) is open.
    public static func isBoxed(_ node: Node) -> Bool {
        ["world", "guess", "advice"].contains(node.note(kind: "src") ?? "")
    }

    /// Does the node's provenance get a badge after its name?
    public static func hasBadge(_ src: String?) -> Bool {
        ["world", "guess", "advice", "user"].contains(src ?? "")
    }

    /// Notes printed under a node's name, in order.
    public static func shownNotes(_ node: Node) -> [String] {
        node.notes.filter { NoteKind.split($0).map { !hiddenNoteKinds.contains($0.kind) } ?? !hiddenNoteKinds.contains($0) }
    }

    /// `icons`: how many icons a node's name matches (the app stacks them); 1 when unknown.
    public static func compute(_ graph: Graph, measure: Measure = estimate, glyph: (Node) -> Bool = defaultGlyph,
                               icons: (Node) -> Int = { _ in 1 }) -> MapLayout {
        typealias M = Metrics
        var layout = MapLayout()
        let ids = graph.nodes.keys.filter { $0.scope.isEmpty }
        guard !ids.isEmpty else { return layout }
        let all = graph.edges.values
            .filter { $0.a.scope.isEmpty && $0.b.scope.isEmpty && $0.a != $0.b && graph.nodes[$0.a] != nil && graph.nodes[$0.b] != nil }
            .sorted { $0.key < $1.key }

        // Trees: roots by degree (the hub first), children by name.
        var degree: [NodeID: Int] = [:]
        var out: [NodeID: [(to: NodeID, key: EdgeKey)]] = [:]
        var pointedAt = Set<NodeID>()
        for e in all {
            degree[e.a, default: 0] += 1
            degree[e.b, default: 0] += 1
            if e.forward || e.isUndirected { out[e.a, default: []].append((e.b, e.key)) }
            if e.backward || e.isUndirected { out[e.b, default: []].append((e.a, e.key)) }
            if e.forward { pointedAt.insert(e.b) }
            if e.backward { pointedAt.insert(e.a) }
        }
        for k in out.keys { out[k]!.sort { $0.to < $1.to } }
        let order = ids.sorted { (degree[$0] ?? 0, $1) > (degree[$1] ?? 0, $0) }

        var children: [NodeID: [NodeID]] = [:]
        var depth: [NodeID: Int] = [:]
        var treeEdges = Set<EdgeKey>()
        var roots: [(id: NodeID, size: Int)] = []
        func grow(_ root: NodeID) {
            depth[root] = 0
            var queue = [root], i = 0
            while i < queue.count {
                let parent = queue[i]; i += 1
                for (to, key) in out[parent] ?? [] where depth[to] == nil {
                    depth[to] = depth[parent]! + 1
                    treeEdges.insert(key)
                    children[parent, default: []].append(to)
                    queue.append(to)
                }
            }
            roots.append((root, queue.count))
        }
        for id in order where !pointedAt.contains(id) && depth[id] == nil { grow(id) }
        // What is left sits on cycles nothing outside points into: start at its hub.
        for id in order where depth[id] == nil { grow(id) }
        // Larger trees first, so the map opens on its main structure and strays come last;
        // branches are numbered in that order, top to bottom.
        var sortedRoots = roots.enumerated().sorted { ($0.element.size, $1.offset) > ($1.element.size, $0.offset) }.map(\.element.id)
        // Except the first few nodes linked to nothing at all: they go at the very top, where
        // they are seen (and linked) rather than lost under the map.
        let unlinked = sortedRoots.filter { degree[$0] == nil }.sorted().prefix(Metrics.unlinkedFirst)
        sortedRoots = Array(unlinked) + sortedRoots.filter { !unlinked.contains($0) }
        var branch: [NodeID: Int] = [:]
        var branches = 0
        func paint(_ id: NodeID, _ b: Int) {
            branch[id] = b
            for c in children[id] ?? [] {
                if depth[id] == 0 { branches += 1; paint(c, branches) } else { paint(c, b) }
            }
        }
        for r in sortedRoots { paint(r, 0) }

        // Size every node.
        var sized: [NodeID: PlacedNode] = [:]
        for id in ids {
            let node = graph.nodes[id]!
            let shown = fit(id.name, .name, M.maxText, measure)
            let all = shownNotes(node)
            let notes = all.prefix(M.maxNotes).map { fit($0, .note, M.maxText, measure) }
            let boxed = isBoxed(node)
            // An open node always shows its icon (the kind's glyph when nothing else matches).
            let hasGlyph = !boxed || glyph(node), hasBadge = hasBadge(node.note(kind: "src"))
            let iconCount = hasGlyph ? max(1, icons(node)) : 0
            let pin = node.note(kind: "pos").flatMap(Position.init(noteValue:))
            let w: Double, h: Double
            if boxed {
                let nameW = measure(shown, .name) + (hasGlyph ? M.glyphRoom(iconCount) : 0) + (hasBadge ? M.badge : 0)
                let textW = ([nameW] + notes.map { measure($0, .note) }).max()!
                w = (textW + 2 * M.padX).rounded(.up)
                h = M.nameLine + Double(notes.count) * M.noteLine + 2 * M.padY
            } else {
                let textW = ([M.iconStack(iconCount), measure(shown, .name)] + notes.map { measure($0, .note) }).max()!
                w = (textW + 2 * M.openPadX).rounded(.up)
                h = M.openPadY + M.iconLine + M.iconGap + M.nameLine + Double(notes.count) * M.noteLine + M.openPadY
            }
            sized[id] = PlacedNode(
                id: id, name: shown, notes: notes,
                cut: shown != id.name || notes.count < all.count || zip(notes, all).contains { $0 != $1 },
                depth: depth[id] ?? 0, branch: branch[id] ?? 0, glyph: hasGlyph, icons: max(1, iconCount), badge: hasBadge, pinned: pin != nil, boxed: boxed,
                x: 0, y: 0, w: w, h: h)
        }

        // Columns: as wide as their widest node, apart by enough room for the labels between.
        var columns: [Double] = [], gaps: [Double] = []
        for p in sized.values {
            while columns.count <= p.depth { columns.append(0); gaps.append(0) }
            columns[p.depth] = max(columns[p.depth], p.w)
        }
        for e in all where treeEdges.contains(e.key) {
            let d = min(sized[e.a]!.depth, sized[e.b]!.depth)
            gaps[d] = max(gaps[d], max(measure(label(e), .label), measure(note(e), .label)) + 2 * M.padX)
        }
        var columnX: [Double] = [], x = 0.0
        for d in columns.indices {
            columnX.append(x)
            x += columns[d] + min(M.maxColumnGap, max(M.minColumnGap, gaps[d]))
        }

        // Rows: each subtree is as tall as its children (or itself); a parent is centred on them.
        var span: [NodeID: Double] = [:]
        func measureTree(_ id: NodeID) -> Double {
            let kids = children[id] ?? []
            let total = max(sized[id]!.h, kids.reduce(0) { $0 + measureTree($1) } + M.siblingGap * Double(max(0, kids.count - 1)))
            span[id] = total
            return total
        }
        func assign(_ id: NodeID, _ y: Double) {
            let kids = children[id] ?? []
            sized[id]!.x = columnX[sized[id]!.depth]
            sized[id]!.y = y + (span[id]! - sized[id]!.h) / 2
            let kidsH = kids.reduce(0) { $0 + span[$1]! } + M.siblingGap * Double(max(0, kids.count - 1))
            var cy = y + (span[id]! - kidsH) / 2
            for c in kids { assign(c, cy); cy += span[c]! + M.siblingGap }
        }
        var y = 0.0
        var drawn: [NodeID] = []
        func collect(_ id: NodeID) { drawn.append(id); (children[id] ?? []).forEach(collect) }
        for r in sortedRoots {
            _ = measureTree(r)
            assign(r, y)
            y += span[r]! + M.treeGap
            collect(r)
        }

        // Pins keep their place (the note holds the centre).
        for id in ids {
            if let pos = graph.nodes[id]!.note(kind: "pos").flatMap(Position.init(noteValue:)) {
                sized[id]!.x = (pos.x - sized[id]!.w / 2).rounded()
                sized[id]!.y = (pos.y - sized[id]!.h / 2).rounded()
            }
        }

        layout.nodes = drawn.map { sized[$0]! }
        layout.index = Dictionary(uniqueKeysWithValues: layout.nodes.enumerated().map { ($1.id.name, $0) })
        let maxLabel = M.maxColumnGap - 2 * M.padX
        layout.edges = all.map { e in
            let tree = treeEdges.contains(e.key)
            let a = sized[e.a]!, b = sized[e.b]!
            var placed = PlacedEdge(
                key: e.key, tree: tree, branch: tree ? (a.depth > b.depth ? a.branch : b.branch) : 0,
                p0: Point(x: 0, y: 0), p1: Point(x: 0, y: 0), p2: Point(x: 0, y: 0), p3: Point(x: 0, y: 0),
                arrowStart: false, arrowEnd: false, labelAt: Point(x: 0, y: 0),
                label: fit(label(e), .label, maxLabel, measure), note: fit(note(e), .label, maxLabel, measure))
            route(&placed, e, a, b)
            return placed
        }
        layout.directions = Dictionary(uniqueKeysWithValues: all.map { ($0.key, ($0.a.name, $0.forward, $0.backward)) })
        layout.fitBounds(measure: measure)
        return layout
    }

    /// Each edge's `a` end and directions, so a moved node can re-route its edges.
    private var directions: [EdgeKey: (a: String, forward: Bool, backward: Bool)] = [:]

    public static func == (l: MapLayout, r: MapLayout) -> Bool {
        l.nodes == r.nodes && l.edges == r.edges
    }

    /// The layout with one node moved by (dx, dy) and its edges re-routed: what the canvas
    /// shows while a node is dragged.
    public func moving(_ name: String, dx: Double, dy: Double) -> MapLayout {
        guard let i = index[name], dx != 0 || dy != 0 else { return self }
        var next = self
        next.nodes[i].x += dx
        next.nodes[i].y += dy
        next.reroute { $0.lo.name == name || $0.hi.name == name }
        next.fitBounds(measure: Self.estimate)
        return next
    }

    /// The layout with nodes moved to these centres (pinned there) and every edge re-routed:
    /// what the canvas shows while Fill the view rearranges the map.
    public func placing(_ centers: [String: Point]) -> MapLayout {
        var next = self
        for (name, c) in centers {
            guard let i = index[name] else { continue }
            next.nodes[i].x = c.x - next.nodes[i].w / 2
            next.nodes[i].y = c.y - next.nodes[i].h / 2
            next.nodes[i].pinned = true
        }
        next.reroute { _ in true }
        next.fitBounds(measure: Self.estimate)
        return next
    }

    private mutating func reroute(_ touches: (EdgeKey) -> Bool) {
        for (j, e) in edges.enumerated() where touches(e.key) {
            guard let dir = directions[e.key], let a = self[dir.a], let b = self[dir.a == e.key.lo.name ? e.key.hi.name : e.key.lo.name] else { continue }
            var edge = Edge(a: a.id, b: b.id)
            edge.forward = dir.forward
            edge.backward = dir.backward
            Self.route(&edges[j], edge, a, b)
        }
    }

    /// Each node's centre, as the JSON export lists positions.
    public var centers: Layout {
        var out = Layout()
        for n in nodes { out.positions[n.id.name] = Placed(name: n.id.name, x: n.center.x, y: n.center.y, pinned: n.pinned) }
        return out
    }

    /// The centre `@pos` should record for a node moved by (dx, dy).
    public func pinnedCenter(_ name: String, dx: Double, dy: Double) -> Point? {
        self[name].map { Point(x: ($0.center.x + dx).rounded(), y: ($0.center.y + dy).rounded()) }
    }

    // MARK: - Helpers

    private static func label(_ e: Edge) -> String { e.labels.joined(separator: " · ") }
    private static func note(_ e: Edge) -> String { shownEdgeNotes(e).joined(separator: " · ") }

    /// Edge notes printed under its label (provenance and proof are drawn another way).
    public static func shownEdgeNotes(_ e: Edge) -> [String] {
        e.notes.filter { NoteKind.split($0).map { !hiddenNoteKinds.contains($0.kind) } ?? !hiddenNoteKinds.contains($0) }
    }

    /// `text` cut with an ellipsis to fit `max` points.
    static func fit(_ text: String, _ role: TextRole, _ max: Double, _ measure: Measure) -> String {
        if measure(text, role) <= max { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measure(String(chars[0..<mid]) + "…", role) <= max { lo = mid } else { hi = mid - 1 }
        }
        return String(chars[0..<lo]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A cubic from one node's side to the other's, with the label at its middle.
    static func route(_ placed: inout PlacedEdge, _ edge: Edge, _ a: PlacedNode, _ b: PlacedNode) {
        // Left to right where the nodes allow it; top to bottom between two placed nodes
        // stacked one over the other; otherwise bulge out to the right.
        let (s, t) = a.x <= b.x ? (a, b) : (b, a)
        let sy = s.y + s.anchorY, ty = t.y + t.anchorY
        let sRight = s.x + s.w - s.anchorInset, tLeft = t.x + t.anchorInset, tRight = t.x + t.w - t.anchorInset
        let (u, d) = a.y <= b.y ? (a, b) : (b, a)
        let p0: Point, p1: Point, p2: Point, p3: Point
        // The node the curve leaves from.
        var start = s
        if sRight >= tLeft, a.pinned, b.pinned, u.y + u.h + Metrics.siblingGap < d.y {
            start = u
            p0 = Point(x: u.x + u.w / 2, y: u.y + u.h)
            p3 = Point(x: d.x + d.w / 2, y: d.y)
            let dy = (p3.y - p0.y) / 2
            p1 = Point(x: p0.x, y: p0.y + dy)
            p2 = Point(x: p3.x, y: p3.y - dy)
        } else if sRight < tLeft {
            p0 = Point(x: sRight, y: sy)
            p3 = Point(x: tLeft, y: ty)
            let dx = (p3.x - p0.x) / 2
            p1 = Point(x: p0.x + dx, y: sy)
            p2 = Point(x: p3.x - dx, y: ty)
        } else {
            // Overlapping columns: right side to right side, around the outside.
            p0 = Point(x: sRight, y: sy)
            p3 = Point(x: tRight, y: ty)
            let out = max(p0.x, p3.x) + 40 + abs(ty - sy) * 0.15
            p1 = Point(x: out, y: sy)
            p2 = Point(x: out, y: ty)
        }
        placed.p0 = p0; placed.p1 = p1; placed.p2 = p2; placed.p3 = p3
        placed.labelAt = Point(x: ((p0.x + 3 * p1.x + 3 * p2.x + p3.x) / 8).rounded(), y: ((p0.y + 3 * p1.y + 3 * p2.y + p3.y) / 8).rounded())
        let fromA = start.id == a.id
        placed.arrowEnd = fromA ? edge.forward : edge.backward
        placed.arrowStart = fromA ? edge.backward : edge.forward
    }

    private mutating func fitBounds(measure: Measure) {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for n in nodes { x0 = min(x0, n.x); y0 = min(y0, n.y); x1 = max(x1, n.x + n.w); y1 = max(y1, n.y + n.h) }
        for e in edges {
            for p in [e.p1, e.p2] { x1 = max(x1, p.x); x0 = min(x0, p.x) }
            if !e.label.isEmpty || !e.note.isEmpty {
                let half = max(measure(e.label, .label), measure(e.note, .label)) / 2
                x0 = min(x0, e.labelAt.x - half); x1 = max(x1, e.labelAt.x + half)
            }
        }
        if x0.isFinite { (minX, minY, maxX, maxY) = (x0, y0, x1, y1) }
    }
}
