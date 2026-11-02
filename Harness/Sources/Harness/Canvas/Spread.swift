import Foundation

/// Fill the view: the map's nodes slide, a few points at a time, toward its middle and into
/// whatever room is around them, until the map's shape matches the view's and fitting it
/// zooms in as far as it can. The canvas refits after every few steps, so the map grows on
/// screen while it settles.
///
///   · a step is shorter than any node, so a node never jumps over another;
///   · no step brings two nodes closer than `gap` (nodes already closer are pushed apart first);
///   · no node leaves the box the map fits in the view, so the fitted zoom never drops;
///   · no step makes two links cross, a link run through a node, or a node sit on a link
///     (links drawn exactly as the canvas draws them). The trees' links are always kept
///     clear; a cross-link is when it starts clear (one already tangled across the map is
///     left to cross what it crosses); whatever already crossed at the start may stay so.
///
/// Nodes move by whole points, so the centres it hands the canvas are the ones it checked.
///
/// A node blocked on its way in slides sideways, away from what blocks it, to get around it.
/// It stops when the zoom has not grown for a while, has reached `maxZoom`, or nothing moves.
public struct Spread: Sendable {
    struct Box: Sendable {
        var x, y, w, h: Double
        /// Where links meet the node (see `MapLayout.PlacedNode`).
        var anchorY = 0.0, anchorInset = 0.0
        var cx: Double { x + w / 2 }
        var cy: Double { y + h / 2 }
        var ends: MapLayout.Ends { MapLayout.Ends(x: x, y: y, w: w, h: h, anchorY: anchorY, anchorInset: anchorInset, pinned: true) }
    }

    /// A link as the canvas draws it, flattened, and the box around it.
    struct Line: Sendable {
        var points: [MapLayout.Point] = []
        var x0 = 0.0, y0 = 0.0, x1 = 0.0, y1 = 0.0
    }

    public let names: [String]
    var boxes: [Box]
    public let gap: Double
    let viewWidth: Double, viewHeight: Double
    let maxZoom: Double
    public private(set) var steps = 0
    public private(set) var finished = false
    private var best = 0.0
    /// Which way each node last slid to get around something (+1 or −1).
    private var side: [Double]
    private var sinceBest = 0
    /// Each link's two nodes (its `a` end first, as the layout routes it), the links at each
    /// node, and each link's curve now.
    let links: [(a: Int, b: Int)]
    private let linksAt: [[Int]]
    private(set) var lines: [Line]
    /// Links kept clear: the trees', and cross-links clear of everything at the start.
    var kept: [Bool]
    /// Clashes among kept links at the start, which may stay.
    var allowed = Set<Int>()
    /// Where the nodes and the kept links are, so a check looks only at what is near.
    private var nodeCells = Cells(), lineCells = Cells()

    /// Pieces each curve is flattened into, and how far clear of a node a link must pass.
    static let pieces = 32
    static let clearance = 2.0

    /// Steps without the zoom growing by `progress` before it gives up, and at most this many steps.
    static let patience = 60
    static let progress = 0.001
    static let maxSteps = 4000

    /// `viewWidth` × `viewHeight` is the room the map is fitted into, in screen points.
    public init(layout: MapLayout, viewWidth: Double, viewHeight: Double, gap: Double, maxZoom: Double = .infinity) {
        names = layout.nodes.map(\.id.name)
        // Centres on whole points, as the canvas will place them.
        boxes = layout.nodes.map {
            Box(x: $0.center.x.rounded() - $0.w / 2, y: $0.center.y.rounded() - $0.h / 2, w: $0.w, h: $0.h,
                anchorY: $0.anchorY, anchorInset: $0.anchorInset)
        }
        var links: [(a: Int, b: Int)] = []
        var tree: [Bool] = []
        var linksAt = Array(repeating: [Int](), count: boxes.count)
        for e in layout.edges {
            guard let lo = layout.index[e.key.lo.name], let hi = layout.index[e.key.hi.name], lo != hi else { continue }
            let a = layout.directions[e.key]?.a == e.key.hi.name ? hi : lo
            linksAt[lo].append(links.count); linksAt[hi].append(links.count)
            links.append((a, a == lo ? hi : lo))
            tree.append(e.tree)
        }
        self.links = links
        self.linksAt = linksAt
        lines = []
        kept = tree
        self.gap = max(0, gap)
        self.viewWidth = max(1, viewWidth)
        self.viewHeight = max(1, viewHeight)
        self.maxZoom = maxZoom
        side = boxes.indices.map { $0 % 2 == 0 ? 1 : -1 }
        separate()
        lines = links.indices.map { line($0) }
        for i in boxes.indices { nodeCells.put(i, Self.area(boxes[i])) }
        for e in links.indices where kept[e] { lineCells.put(e, Self.area(lines[e])) }
        // Cross-links clear of the trees, the nodes and each other are kept clear too.
        for e in links.indices where !kept[e] {
            var clear = true
            clashes(ofLink: e) { _ in clear = false; return false }
            if clear { kept[e] = true; lineCells.put(e, Self.area(lines[e])) }
        }
        for e in links.indices where kept[e] { clashes(ofLink: e) { allowed.insert($0); return true } }
        best = zoom
        finished = boxes.count < 2
    }

    /// The zoom that fits the nodes in the view.
    public var zoom: Double {
        let b = bounds
        return min(viewWidth / max(1, b.x1 - b.x0), viewHeight / max(1, b.y1 - b.y0))
    }

    /// Each node's centre now.
    public var centers: [String: MapLayout.Point] {
        Dictionary(uniqueKeysWithValues: zip(names, boxes).map { ($0, MapLayout.Point(x: $1.cx.rounded(), y: $1.cy.rounded())) })
    }

    /// Runs until it stops; `limit` caps the steps for this call.
    public mutating func run(limit: Int = .max) {
        var n = 0
        while !finished, n < limit { step(); n += 1 }
    }

    /// One step: every node, the innermost first, moves by at most a few points.
    public mutating func step() {
        guard !finished else { return }
        steps += 1
        let b = bounds
        // The box the map fits in the view: the nodes' box grown to the view's proportions.
        let scale = max((b.x1 - b.x0) / viewWidth, (b.y1 - b.y0) / viewHeight)
        let fw = viewWidth * scale, fh = viewHeight * scale
        let cx = (b.x0 + b.x1) / 2, cy = (b.y0 + b.y1) / 2
        let fit = (x0: cx - fw / 2, y0: cy - fh / 2, x1: cx + fw / 2, y1: cy + fh / 2)
        let shortest = boxes.map { min($0.w, $0.h) }.min() ?? 1
        let length = min(max(2, 0.005 * max(fw, fh)), max(1, shortest / 3), 10)
        let grid = Grid(boxes, reach: gap + 2 * length)

        // How far out a node sits, measured in the view's proportions and squared off,
        // so the map settles into the view's shape rather than a circle.
        func pull(_ i: Int) -> (x: Double, y: Double, far: Double) {
            let nx = (cx - boxes[i].cx) / fw, ny = (cy - boxes[i].cy) / fh
            return (nx * nx * nx / fw, ny * ny * ny / fh, nx * nx * nx * nx + ny * ny * ny * ny)
        }
        let order = boxes.indices.map { ($0, pull($0).far) }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)

        var moved = false
        for i in order {
            let p = pull(i)
            let norm = hypot(p.x, p.y)
            guard norm > 0, hypot(cx - boxes[i].cx, cy - boxes[i].cy) > length else { continue }
            let ux = p.x / norm, uy = p.y / norm
            // Straight in, or along the axis it is furthest out on.
            let along = abs(ux) >= abs(uy) ? (x: ux < 0 ? -1.0 : 1.0, y: 0.0) : (x: 0.0, y: uy < 0 ? -1.0 : 1.0)
            var blocker: MapLayout.Point?
            var done = false
            for (dx, dy) in [(ux, uy), along] {
                switch attempt(i, dx * length, dy * length, fit: fit, grid: grid) {
                case .moved: done = true
                case .blocked(let at): blocker = blocker ?? at
                case .outside: break
                }
                if done { break }
            }
            // Blocked: slide across, away from what is in the way (the way it went last when
            // that is straight ahead), then the other way.
            if !done, let at = blocker {
                let sx = -along.y, sy = along.x
                let away = sx * (boxes[i].cx - at.x) + sy * (boxes[i].cy - at.y)
                if abs(away) > 1 { side[i] = away > 0 ? 1 : -1 }
                for sign in [side[i], -side[i]] {
                    if case .moved = attempt(i, sign * sx * length, sign * sy * length, fit: fit, grid: grid) { side[i] = sign; done = true; break }
                }
            }
            moved = moved || done
        }

        let z = zoom
        if z > best * (1 + Self.progress) { best = z; sinceBest = 0 } else { sinceBest += 1 }
        if !moved || sinceBest >= Self.patience || z >= maxZoom || steps >= Self.maxSteps { finished = true }
    }

    // MARK: - Helpers

    private enum Outcome { case moved, blocked(MapLayout.Point), outside }

    /// Moves node `i` by (dx, dy), cut to whole points, when that keeps it in `fit`, no closer
    /// than `gap` to any node it was not already too close to, and tangles none of the links
    /// it keeps clear.
    private mutating func attempt(_ i: Int, _ dx: Double, _ dy: Double, fit: (x0: Double, y0: Double, x1: Double, y1: Double), grid: Grid) -> Outcome {
        let dx = dx.rounded(.towardZero), dy = dy.rounded(.towardZero)
        guard dx != 0 || dy != 0 else { return .outside }
        var next = boxes[i]
        next.x += dx; next.y += dy
        guard next.x >= fit.x0 - 0.5, next.y >= fit.y0 - 0.5, next.x + next.w <= fit.x1 + 0.5, next.y + next.h <= fit.y1 + 0.5 else { return .outside }
        for j in grid.near(next) where j != i {
            let after = overlap(next, boxes[j])
            if after > 0, after > overlap(boxes[i], boxes[j]) { return .blocked(MapLayout.Point(x: boxes[j].cx, y: boxes[j].cy)) }
        }
        let was = boxes[i]
        let wasLines = linksAt[i].map { lines[$0] }
        place(i, next, linksAt[i].map { (e: $0, line: line(moved: i, to: next, $0)) })
        var hit: Int?
        clashes(of: i) { code in
            if allowed.contains(code) { return true }
            hit = code
            return false
        }
        guard let code = hit else { return .moved }
        place(i, was, Array(zip(linksAt[i], wasLines)))
        return .blocked(obstacle(code, moving: i))
    }

    /// Puts node `i` at `box` and its links on these curves, keeping the cells up to date.
    private mutating func place(_ i: Int, _ box: Box, _ curves: [(e: Int, line: Line)]) {
        boxes[i] = box
        nodeCells.put(i, Self.area(box))
        for (e, l) in curves {
            lines[e] = l
            if kept[e] { lineCells.put(e, Self.area(l)) }
        }
    }

    // MARK: - Links

    /// Link `e`'s curve with node `i` at `box`.
    private func line(moved i: Int, to box: Box, _ e: Int) -> Line {
        let a = links[e].a == i ? box : boxes[links[e].a], b = links[e].b == i ? box : boxes[links[e].b]
        return Self.line(a, b)
    }

    /// Link `e`'s curve now.
    private func line(_ e: Int) -> Line { Self.line(boxes[links[e].a], boxes[links[e].b]) }

    /// A link's curve, routed as the canvas routes it between pinned nodes, flattened.
    private static func line(_ from: Box, _ to: Box) -> Line {
        let c = MapLayout.curve(from.ends, to.ends)
        var out = Line(x0: .infinity, y0: .infinity, x1: -.infinity, y1: -.infinity)
        out.points.reserveCapacity(pieces + 1)
        for k in 0...pieces {
            let t = Double(k) / Double(pieces), u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t
            let p = MapLayout.Point(x: a * c.p0.x + b * c.p1.x + cc * c.p2.x + d * c.p3.x,
                                    y: a * c.p0.y + b * c.p1.y + cc * c.p2.y + d * c.p3.y)
            out.points.append(p)
            out.x0 = min(out.x0, p.x); out.x1 = max(out.x1, p.x)
            out.y0 = min(out.y0, p.y); out.y1 = max(out.y1, p.y)
        }
        return out
    }

    /// A clash as one number: two links crossing, or a link within `clearance` of a node
    /// (`through`: running through it). A link near a node at the start may stay near it,
    /// but never comes to run through it.
    private func linkPair(_ e: Int, _ f: Int) -> Int { min(e, f) * links.count + max(e, f) }
    private func linkNode(_ e: Int, _ k: Int, through: Bool) -> Int { links.count * links.count + 2 * (e * boxes.count + k) + (through ? 1 : 0) }

    /// Where the thing node `i` clashed with is, to steer around: the node, or the middle of
    /// the other link.
    private func obstacle(_ code: Int, moving i: Int) -> MapLayout.Point {
        let pairs = links.count * links.count
        if code >= pairs {
            let e = (code - pairs) / 2 / boxes.count, k = (code - pairs) / 2 % boxes.count
            // Node i on someone's link: steer off the link; node i's link through a node: around the node.
            let l = lines[e]
            return k == i ? l.points[l.points.count / 2] : MapLayout.Point(x: boxes[k].cx, y: boxes[k].cy)
        }
        let e = code / links.count, f = code % links.count
        let l = lines[linksAt[i].contains(e) && !linksAt[i].contains(f) ? f : e]
        return l.points[l.points.count / 2]
    }

    /// Calls `visit` with each clash node `i` is part of, until it returns false: its links
    /// crossing a link, its links running through a node, and links running through it.
    /// Only links kept clear count.
    private func clashes(of i: Int, _ visit: (Int) -> Bool) {
        guard !links.isEmpty else { return }
        let mine = linksAt[i]
        for e in mine where kept[e] {
            // Two of node i's links: each pair once.
            guard clashes(ofLink: e, skip: { f in f < e && mine.contains(f) }, visit) else { return }
        }
        let b = boxes[i], c = Self.clearance
        for f in lineCells.near(Self.area(b, grow: c)) where links[f].a != i && links[f].b != i {
            let lf = lines[f]
            guard lf.x0 <= b.x + b.w + c, b.x - c <= lf.x1, lf.y0 <= b.y + b.h + c, b.y - c <= lf.y1 else { continue }
            if Self.runs(lf, through: b, c) {
                guard visit(linkNode(f, i, through: false)) else { return }
                if Self.runs(lf, through: b, 0), !visit(linkNode(f, i, through: true)) { return }
            }
        }
    }

    /// Calls `visit` with each clash link `e` is part of (crossing a kept link, other than
    /// those `skip` names, or running through a node), until it returns false; false then.
    @discardableResult
    private func clashes(ofLink e: Int, skip: (Int) -> Bool = { _ in false }, _ visit: (Int) -> Bool) -> Bool {
        let le = lines[e]
        for f in lineCells.near(Self.area(le)) where f != e && !skip(f) {
            let lf = lines[f]
            guard le.x0 <= lf.x1, lf.x0 <= le.x1, le.y0 <= lf.y1, lf.y0 <= le.y1 else { continue }
            if cross(e, f), !visit(linkPair(e, f)) { return false }
        }
        let c = Self.clearance
        for k in nodeCells.near(Self.area(le, grow: c)) where k != links[e].a && k != links[e].b {
            let b = boxes[k]
            guard le.x0 <= b.x + b.w + c, b.x - c <= le.x1, le.y0 <= b.y + b.h + c, b.y - c <= le.y1 else { continue }
            if Self.runs(le, through: b, c) {
                guard visit(linkNode(e, k, through: false)) else { return false }
                if Self.runs(le, through: b, 0), !visit(linkNode(e, k, through: true)) { return false }
            }
        }
        return true
    }

    /// Do links `e` and `f` cross? Two links from one node meet there; only a crossing away
    /// from that node counts.
    private func cross(_ e: Int, _ f: Int) -> Bool {
        let shared: Int? = [links[e].a, links[e].b].first { $0 == links[f].a || $0 == links[f].b }
        let pe = lines[e].points, pf = lines[f].points, lf = lines[f]
        for s in 1..<pe.count {
            let a0 = pe[s - 1], a1 = pe[s]
            guard max(a0.x, a1.x) >= lf.x0, min(a0.x, a1.x) <= lf.x1, max(a0.y, a1.y) >= lf.y0, min(a0.y, a1.y) <= lf.y1 else { continue }
            for t in 1..<pf.count {
                let b0 = pf[t - 1], b1 = pf[t]
                guard max(a0.x, a1.x) >= min(b0.x, b1.x), max(b0.x, b1.x) >= min(a0.x, a1.x),
                      max(a0.y, a1.y) >= min(b0.y, b1.y), max(b0.y, b1.y) >= min(a0.y, a1.y),
                      let p = Self.meet(a0, a1, b0, b1) else { continue }
                if let k = shared {
                    let n = boxes[k], c = Self.clearance
                    if p.x >= n.x - c, p.x <= n.x + n.w + c, p.y >= n.y - c, p.y <= n.y + n.h + c { continue }
                }
                return true
            }
        }
        return false
    }

    /// Where two segments meet, if they do (a point of the overlap when they lie along each other).
    static func meet(_ a0: MapLayout.Point, _ a1: MapLayout.Point, _ b0: MapLayout.Point, _ b1: MapLayout.Point) -> MapLayout.Point? {
        let rx = a1.x - a0.x, ry = a1.y - a0.y, sx = b1.x - b0.x, sy = b1.y - b0.y
        let qx = b0.x - a0.x, qy = b0.y - a0.y
        let d = rx * sy - ry * sx
        if abs(d) < 1e-12 {
            // Parallel: they meet only when on one line and overlapping.
            guard abs(qx * ry - qy * rx) < 1e-9 else { return nil }
            let rr = rx * rx + ry * ry
            guard rr > 1e-12 else { return hypot(qx, qy) < 1e-9 ? a0 : nil }
            let t0 = (qx * rx + qy * ry) / rr, t1 = t0 + (sx * rx + sy * ry) / rr
            let lo = max(0, min(t0, t1)), hi = min(1, max(t0, t1))
            guard lo <= hi else { return nil }
            return MapLayout.Point(x: a0.x + lo * rx, y: a0.y + lo * ry)
        }
        let t = (qx * sy - qy * sx) / d, u = (qx * ry - qy * rx) / d
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return MapLayout.Point(x: a0.x + t * rx, y: a0.y + t * ry)
    }

    /// Does the line pass within `c` of the box?
    static func runs(_ l: Line, through b: Box, _ c: Double) -> Bool {
        let x0 = b.x - c, y0 = b.y - c, x1 = b.x + b.w + c, y1 = b.y + b.h + c
        for s in 1..<l.points.count {
            let p = l.points[s - 1], q = l.points[s]
            // Clip the segment to the box (Liang–Barsky).
            var lo = 0.0, hi = 1.0
            let dx = q.x - p.x, dy = q.y - p.y
            var inside = true
            for (num, den) in [(p.x - x0, -dx), (x1 - p.x, dx), (p.y - y0, -dy), (y1 - p.y, dy)] {
                if abs(den) < 1e-12 {
                    if num < 0 { inside = false; break }
                } else {
                    let r = num / den
                    if den < 0 { lo = max(lo, r) } else { hi = min(hi, r) }
                    if lo > hi { inside = false; break }
                }
            }
            if inside { return true }
        }
        return false
    }

    /// How far two nodes are inside each other's `gap` (0 when they are far enough apart).
    private func overlap(_ a: Box, _ b: Box) -> Double {
        let ox = min(a.x + a.w, b.x + b.w) - max(a.x, b.x) + gap
        let oy = min(a.y + a.h, b.y + b.h) - max(a.y, b.y) + gap
        return ox > 1e-6 && oy > 1e-6 ? min(ox, oy) : 0
    }

    /// Pushes apart nodes closer than `gap`, each pair along the way that parts it soonest.
    private mutating func separate() {
        for _ in 0..<200 {
            var clean = true
            let grid = Grid(boxes, reach: gap)
            for i in boxes.indices {
                for j in grid.near(boxes[i]) where j > i {
                    let a = boxes[i], b = boxes[j]
                    let ox = min(a.x + a.w, b.x + b.w) - max(a.x, b.x) + gap
                    let oy = min(a.y + a.h, b.y + b.h) - max(a.y, b.y) + gap
                    guard ox > 1e-6, oy > 1e-6 else { continue }
                    clean = false
                    if ox < oy {
                        let d = (a.cx < b.cx || (a.cx == b.cx && i < j) ? -1.0 : 1.0) * (ox / 2 + 0.01).rounded(.up)
                        boxes[i].x += d; boxes[j].x -= d
                    } else {
                        let d = (a.cy < b.cy || (a.cy == b.cy && i < j) ? -1.0 : 1.0) * (oy / 2 + 0.01).rounded(.up)
                        boxes[i].y += d; boxes[j].y -= d
                    }
                }
            }
            if clean { return }
        }
    }

    private var bounds: (x0: Double, y0: Double, x1: Double, y1: Double) {
        var b = (x0: Double.infinity, y0: Double.infinity, x1: -Double.infinity, y1: -Double.infinity)
        for n in boxes { b = (min(b.x0, n.x), min(b.y0, n.y), max(b.x1, n.x + n.w), max(b.y1, n.y + n.h)) }
        return b.x0.isFinite ? b : (0, 0, 0, 0)
    }

    /// Sorted, each once.
    static func ordered(_ ids: [Int]) -> [Int] {
        guard ids.count > 1 else { return ids }
        var out: [Int] = []
        out.reserveCapacity(ids.count)
        for id in ids.sorted() where out.last != id { out.append(id) }
        return out
    }

    /// The cells a box (grown by `grow`) or a curve's box covers.
    private static func area(_ b: Box, grow c: Double = 0) -> [Int64] { Grid.keys(Box(x: b.x - c, y: b.y - c, w: b.w + 2 * c, h: b.h + 2 * c), 0) }
    private static func area(_ l: Line, grow c: Double = 0) -> [Int64] { Grid.keys(Box(x: l.x0 - c, y: l.y0 - c, w: l.x1 - l.x0 + 2 * c, h: l.y1 - l.y0 + 2 * c), 0) }

    /// Which things (nodes, or links) lie in which cells, kept up to date as they move.
    private struct Cells: Sendable {
        var cells: [Int64: [Int]] = [:]
        var at: [Int: [Int64]] = [:]

        /// Puts `id` in these cells (and out of those it was in).
        mutating func put(_ id: Int, _ keys: [Int64]) {
            let old = at[id] ?? []
            guard old != keys else { return }
            for key in old { cells[key]?.removeAll { $0 == id } }
            for key in keys { cells[key, default: []].append(id) }
            at[id] = keys
        }

        /// What lies in any of these cells, in index order (so a spread comes out the same every time).
        func near(_ keys: [Int64]) -> [Int] {
            var out: [Int] = []
            for key in keys { if let ids = cells[key] { out.append(contentsOf: ids) } }
            return Spread.ordered(out)
        }
    }

    /// Which nodes are near which: each node sits in every cell its box, grown by `reach`,
    /// touches, so only those need checking.
    private struct Grid {
        static let cell = 96.0
        var cells: [Int64: [Int]] = [:]
        let reach: Double

        init(_ boxes: [Box], reach: Double) {
            self.reach = reach
            for (i, b) in boxes.enumerated() { for key in Self.keys(b, reach) { cells[key, default: []].append(i) } }
        }

        /// In index order, so a spread comes out the same every time.
        func near(_ b: Box) -> [Int] {
            var out: [Int] = []
            for key in Self.keys(b, reach) { if let ids = cells[key] { out.append(contentsOf: ids) } }
            return Spread.ordered(out)
        }

        static func keys(_ b: Box, _ reach: Double) -> [Int64] {
            let x0 = Int64(((b.x - reach) / cell).rounded(.down)), x1 = Int64(((b.x + b.w + reach) / cell).rounded(.down))
            let y0 = Int64(((b.y - reach) / cell).rounded(.down)), y1 = Int64(((b.y + b.h + reach) / cell).rounded(.down))
            var keys: [Int64] = []
            keys.reserveCapacity(Int((x1 - x0 + 1) * (y1 - y0 + 1)))
            for x in x0...x1 { for y in y0...y1 { keys.append(x &* 1_000_003 &+ y) } }
            return keys
        }
    }
}
