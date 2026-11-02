import Foundation

extension MapLayout {
    /// A fresh arrangement shaped to the view, for Fill the view's second button: the same
    /// trees, rearranged in ways that never cross a link, whichever lets the view fill most:
    ///
    ///   · both sides: a root's branches split between its right and its left, the left ones
    ///     mirrored (a root has no link coming in, so either side is free), which halves a
    ///     tall hub;
    ///   · a ring: a root whose branches are all single nodes has them round it on an
    ///     ellipse shaped to the view, the middle ones furthest out, so no link passes
    ///     another node on its way;
    ///   · side by side: the trees, which no tree link joins, packed into columns rather
    ///     than stacked in one.
    ///
    /// Each candidate is checked link by link; one that would tangle the trees more than the
    /// map as drawn is passed over (the map as drawn is always a candidate). Every node is
    /// placed (pinned), as `placing` does, so the spread can start from it.
    public func arranged(toFit viewWidth: Double, _ viewHeight: Double, gap: Double = 24) -> MapLayout {
        guard nodes.count > 1 else { return self }
        // The map as drawn, and what it already has tangled (two links leaving one node side by
        // side can touch): a candidate may have that too, nothing more.
        let plain = placing(Dictionary(uniqueKeysWithValues: nodes.map { ($0.id.name, $0.center) }))
        let already = Spread.tangles(plain)
        func fit(_ l: MapLayout) -> Double { Spread(layout: l, viewWidth: viewWidth, viewHeight: viewHeight, gap: gap).zoom }
        // Each kind of arrangement in the number of columns that fits the view best.
        var options: [[Block]] = [trees(bothSides: false), trees(bothSides: true)]
        for aspect in [0.7, 1.0, 1.4, 2.0] { options.append(trees(bothSides: true, ring: aspect)) }
        var candidates: [MapLayout] = [plain]
        for blocks in options {
            var best: (zoom: Double, centers: [String: Point])?
            for columns in 1...max(1, min(blocks.count, 8)) {
                let packed = Self.pack(blocks, columns: columns)
                let zoom = min(viewWidth / max(1, packed.width), viewHeight / max(1, packed.height))
                if best == nil || zoom > best!.zoom * 1.01 { best = (zoom, packed.centers) }
            }
            let laid = placing(best!.centers)
            if !candidates.contains(laid), Spread.tangles(laid).isSubset(of: already) { candidates.append(laid) }
        }
        // Judged by how far a spread from each gets (a short one), or on a large map by how
        // well it fits as it is. In a near tie (within 2%) the one with fewer links crossing
        // wins, and then the plainer (earlier).
        func score(_ l: MapLayout) -> Double {
            guard nodes.count <= Self.trialNodes else { return fit(l) }
            var spread = Spread(layout: l, viewWidth: viewWidth, viewHeight: viewHeight, gap: gap)
            spread.run(limit: Self.trialSteps)
            return spread.zoom
        }
        var best = (layout: plain, score: score(plain), tangles: already.count)
        for c in candidates.dropFirst() {
            let s = score(c), t = Spread.tangles(c).count
            if s > best.score * 1.02 || (s >= best.score / 1.02 && t < best.tangles) { best = (c, max(s, best.score), t) }
        }
        return best.layout
    }

    /// Maps up to this many nodes pick their arrangement by a trial spread of this many steps.
    static let trialNodes = 150
    static let trialSteps = 150

    /// A tree laid out on its own: each node's centre, relative to the tree's top left corner,
    /// and the tree's size.
    struct Block {
        var centers: [String: Point]
        var width: Double, height: Double
    }

    /// Every tree as a block, in the order the map draws them; `bothSides` splits each root's
    /// branches between its right and its left; `ring` (an ellipse's width over its height)
    /// sets a root's single-node branches round it.
    func trees(bothSides: Bool, ring: Double? = nil) -> [Block] {
        typealias M = Metrics
        // Where each depth's column starts, as drawn.
        var columnX: [Int: Double] = [:]
        for n in nodes { columnX[n.depth] = min(columnX[n.depth] ?? .infinity, n.x) }
        var span: [String: Double] = [:]
        func measure(_ name: String) -> Double {
            let kids = children[name] ?? []
            let total = max(self[name]!.h, kids.reduce(0) { $0 + measure($1) } + M.siblingGap * Double(max(0, kids.count - 1)))
            span[name] = total
            return total
        }
        func height(_ kids: [String]) -> Double {
            kids.reduce(0) { $0 + span[$1]! } + M.siblingGap * Double(max(0, kids.count - 1))
        }
        var blocks: [Block] = []
        for root in nodes where parent[root.id.name] == nil {
            let name = root.id.name
            _ = measure(name)
            let kids = children[name] ?? []
            if let ring, kids.count >= Self.ringFrom, kids.allSatisfy({ (children[$0] ?? []).isEmpty }) {
                blocks.append(ringBlock(root, kids, aspect: ring))
                continue
            }
            // Right: the first branches, left: the rest, splitting the height as evenly as can be.
            var split = kids.count
            if bothSides, kids.count > 1 {
                var bestGap = Double.infinity
                for k in 1..<kids.count {
                    let gap = max(height(Array(kids[..<k])), height(Array(kids[k...])))
                    if gap < bestGap { bestGap = gap; split = k }
                }
            }
            let right = Array(kids[..<split])
            // Clockwise: down the right, then up the left.
            let left = Array(kids[split...].reversed())
            let tall = max(root.h, height(right), height(left))
            var centers: [String: Point] = [:]
            let mid = tall / 2
            // The root's centre line: the left side is the right side mirrored across it.
            let axis = root.x + root.w / 2
            func place(_ name: String, top: Double, side: Double) {
                let n = self[name]!
                let x = n.depth == 0 ? n.x : columnX[n.depth]!
                let cx = side > 0 ? x + n.w / 2 : 2 * axis - (x + n.w / 2)
                centers[name] = Point(x: cx, y: top + span[name]! / 2)
                let kids = children[name] ?? []
                var y = top + (span[name]! - height(kids)) / 2
                for k in kids { place(k, top: y, side: side); y += span[k]! + M.siblingGap }
            }
            centers[name] = Point(x: axis, y: mid)
            for (kids, side) in [(right, 1.0), (left, -1.0)] {
                var y = mid - height(kids) / 2
                for k in kids { place(k, top: y, side: side); y += span[k]! + M.siblingGap }
            }
            // To the block's own top left corner.
            var x0 = Double.infinity, x1 = -Double.infinity, y0 = Double.infinity, y1 = -Double.infinity
            for (n, c) in centers {
                let p = self[n]!
                x0 = min(x0, c.x - p.w / 2); x1 = max(x1, c.x + p.w / 2)
                y0 = min(y0, c.y - p.h / 2); y1 = max(y1, c.y + p.h / 2)
            }
            blocks.append(Block(centers: centers.mapValues { Point(x: $0.x - x0, y: $0.y - y0) }, width: x1 - x0, height: y1 - y0))
        }
        return blocks
    }

    /// A root needs this many single-node branches before they go round it in a ring.
    static let ringFrom = 5

    /// A root with its branches round it, clockwise from the top, on an ellipse `aspect`
    /// times as wide as it is tall, just big enough that neighbours keep apart and every
    /// branch keeps a column's room from the root.
    func ringBlock(_ root: PlacedNode, _ kids: [String], aspect: Double) -> Block {
        typealias M = Metrics
        let n = kids.count
        let boxes = kids.map { self[$0]! }
        // Clockwise from just right of the top, so the first branch sits where it did.
        let turn: Double = 2 * Double.pi / Double(n)
        let angles: [Double] = (0..<n).map { k in (Double(k) + 0.5) * turn - Double.pi / 2 }
        // The smallest ellipse on which no two neighbours come within a gap of each other.
        let room = M.minColumnGap
        let tallest: Double = boxes.map(\.h).max() ?? 0, widest: Double = boxes.map(\.w).max() ?? 0
        let above: Double = root.h / 2 + room + tallest / 2, beside: Double = root.w / 2 + room + widest / 2
        var ry = max(above, beside / aspect)
        func at(_ k: Int, _ ry: Double) -> Point { Point(x: aspect * ry * cos(angles[k]), y: ry * sin(angles[k])) }
        func clear(_ ry: Double) -> Bool {
            for k in 0..<n {
                let j = (k + 1) % n
                guard j != k else { continue }
                let a = at(k, ry), b = at(j, ry)
                let dx: Double = abs(a.x - b.x) - (boxes[k].w + boxes[j].w) / 2
                let dy: Double = abs(a.y - b.y) - (boxes[k].h + boxes[j].h) / 2
                if max(dx, dy) < M.siblingGap * 2 { return false }
            }
            return true
        }
        while !clear(ry) { ry *= 1.05 }
        var centers: [String: Point] = [root.id.name: Point(x: 0, y: 0)]
        for k in 0..<n { centers[kids[k]] = at(k, ry) }
        var x0 = Double.infinity, x1 = -Double.infinity, y0 = Double.infinity, y1 = -Double.infinity
        for (name, c) in centers {
            let p = self[name]!
            x0 = min(x0, c.x - p.w / 2); x1 = max(x1, c.x + p.w / 2)
            y0 = min(y0, c.y - p.h / 2); y1 = max(y1, c.y + p.h / 2)
        }
        return Block(centers: centers.mapValues { Point(x: $0.x - x0, y: $0.y - y0) }, width: x1 - x0, height: y1 - y0)
    }

    /// The blocks in `columns` columns, each in turn going to the shortest column so far
    /// (the leftmost of equals), each column as wide as its widest block.
    static func pack(_ blocks: [Block], columns: Int) -> (centers: [String: Point], width: Double, height: Double) {
        let gap = Metrics.treeGap
        var heights = Array(repeating: 0.0, count: columns), widths = Array(repeating: 0.0, count: columns)
        var placed: [(block: Int, column: Int, y: Double)] = []
        for (i, b) in blocks.enumerated() {
            let c = heights.indices.min { (heights[$0], $0) < (heights[$1], $1) }!
            placed.append((i, c, heights[c] == 0 ? 0 : heights[c] + gap))
            heights[c] = (heights[c] == 0 ? 0 : heights[c] + gap) + b.height
            widths[c] = max(widths[c], b.width)
        }
        var lefts: [Double] = [], x = 0.0
        for w in widths { lefts.append(x); x += w + (w > 0 ? 2 * gap : 0) }
        var centers: [String: Point] = [:]
        for p in placed {
            for (n, c) in blocks[p.block].centers { centers[n] = Point(x: (lefts[p.column] + c.x).rounded(), y: (p.y + c.y).rounded()) }
        }
        let used = widths.filter { $0 > 0 }
        return (centers, used.reduce(0, +) + 2 * gap * Double(max(0, used.count - 1)), heights.max() ?? 0)
    }
}
