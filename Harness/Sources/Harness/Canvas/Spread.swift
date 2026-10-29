import Foundation

/// Fill the view: the map's nodes slide, a few points at a time, toward its middle and into
/// whatever room is around them, until the map's shape matches the view's and fitting it
/// zooms in as far as it can. The canvas refits after every few steps, so the map grows on
/// screen while it settles.
///
///   · a step is shorter than any node, so a node never jumps over another;
///   · no step brings two nodes closer than `gap` (nodes already closer are pushed apart first);
///   · no node leaves the box the map fits in the view, so the fitted zoom never drops.
///
/// A node blocked on its way in slides sideways, away from what blocks it, to get around it.
/// It stops when the zoom has not grown for a while, has reached `maxZoom`, or nothing moves.
public struct Spread: Sendable {
    struct Box: Sendable {
        var x, y, w, h: Double
        var cx: Double { x + w / 2 }
        var cy: Double { y + h / 2 }
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

    /// Steps without the zoom growing by `progress` before it gives up, and at most this many steps.
    static let patience = 60
    static let progress = 0.001
    static let maxSteps = 4000

    /// `viewWidth` × `viewHeight` is the room the map is fitted into, in screen points.
    public init(layout: MapLayout, viewWidth: Double, viewHeight: Double, gap: Double, maxZoom: Double = .infinity) {
        names = layout.nodes.map(\.id.name)
        boxes = layout.nodes.map { Box(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
        self.gap = max(0, gap)
        self.viewWidth = max(1, viewWidth)
        self.viewHeight = max(1, viewHeight)
        self.maxZoom = maxZoom
        side = boxes.indices.map { $0 % 2 == 0 ? 1 : -1 }
        separate()
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
            var blocker: Int?
            var done = false
            for (dx, dy) in [(ux, uy), along] {
                switch attempt(i, dx * length, dy * length, fit: fit, grid: grid) {
                case .moved: done = true
                case .blocked(let j): blocker = blocker ?? j
                case .outside: break
                }
                if done { break }
            }
            // Blocked: slide across, away from what is in the way (the way it went last when
            // that is straight ahead), then the other way.
            if !done, let j = blocker {
                let sx = -along.y, sy = along.x
                let away = sx * (boxes[i].cx - boxes[j].cx) + sy * (boxes[i].cy - boxes[j].cy)
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

    private enum Outcome { case moved, blocked(Int), outside }

    /// Moves node `i` by (dx, dy) when that keeps it in `fit` and no closer than `gap` to any
    /// node it was not already too close to.
    private mutating func attempt(_ i: Int, _ dx: Double, _ dy: Double, fit: (x0: Double, y0: Double, x1: Double, y1: Double), grid: Grid) -> Outcome {
        var next = boxes[i]
        next.x += dx; next.y += dy
        guard next.x >= fit.x0 - 0.5, next.y >= fit.y0 - 0.5, next.x + next.w <= fit.x1 + 0.5, next.y + next.h <= fit.y1 + 0.5 else { return .outside }
        for j in grid.near(next) where j != i {
            let after = overlap(next, boxes[j])
            if after > 0, after > overlap(boxes[i], boxes[j]) { return .blocked(j) }
        }
        boxes[i] = next
        return .moved
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
                        let d = (a.cx < b.cx || (a.cx == b.cx && i < j) ? -1.0 : 1.0) * (ox / 2 + 0.01)
                        boxes[i].x += d; boxes[j].x -= d
                    } else {
                        let d = (a.cy < b.cy || (a.cy == b.cy && i < j) ? -1.0 : 1.0) * (oy / 2 + 0.01)
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
            var out = Set<Int>()
            for key in Self.keys(b, reach) { out.formUnion(cells[key] ?? []) }
            return out.sorted()
        }

        static func keys(_ b: Box, _ reach: Double) -> [Int64] {
            let x0 = Int64(((b.x - reach) / cell).rounded(.down)), x1 = Int64(((b.x + b.w + reach) / cell).rounded(.down))
            let y0 = Int64(((b.y - reach) / cell).rounded(.down)), y1 = Int64(((b.y + b.h + reach) / cell).rounded(.down))
            var keys: [Int64] = []
            for x in x0...x1 { for y in y0...y1 { keys.append(x &* 1_000_003 &+ y) } }
            return keys
        }
    }
}
