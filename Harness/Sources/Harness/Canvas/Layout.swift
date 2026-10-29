import Foundation

/// A node's place on the canvas.
public struct Placed: Equatable, Sendable {
    public var name: String
    public var x: Double
    public var y: Double
    public var pinned: Bool
}

/// Deterministic force-directed layout (SPEC “Canvas”): same graph and seed give the
/// same positions. Outline headings act as soft clusters; a node with `@pos` is pinned.
public struct Layout: Equatable, Sendable {
    public var positions: [String: Placed] = [:]
    public var options: LayoutOptions

    public init(options: LayoutOptions = LayoutOptions()) {
        self.options = options
    }

    public static func compute(_ graph: Graph, options: LayoutOptions = LayoutOptions(), iterations: Int = 300, previous: Layout? = nil) -> Layout {
        var layout = Layout(options: options)
        let ids = graph.nodes.keys.filter { $0.scope.isEmpty }.sorted()
        guard !ids.isEmpty else { return layout }
        var rng = SplitMix(seed: options.seed)

        var x = [Double](repeating: 0, count: ids.count), y = x
        var pinned = [Bool](repeating: false, count: ids.count)
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        for (i, id) in ids.enumerated() {
            if let pos = graph.nodes[id]?.note(kind: "pos").flatMap(Position.init(noteValue:)) {
                x[i] = pos.x; y[i] = pos.y; pinned[i] = true
            } else if let p = previous?.positions[id.name] {
                x[i] = p.x; y[i] = p.y
            } else {
                let angle = rng.next() * 2 * .pi
                let radius = options.linkDistance * (0.5 + rng.next()) * sqrt(Double(ids.count))
                x[i] = cos(angle) * radius; y[i] = sin(angle) * radius
            }
        }

        let edges = graph.edges.values.compactMap { e -> (Int, Int)? in
            guard let a = index[e.a], let b = index[e.b], a != b else { return nil }
            return (a, b)
        }
        var clusters: [[String]: [Int]] = [:]
        for (i, id) in ids.enumerated() { clusters[graph.nodes[id]!.heading, default: []].append(i) }

        var temperature = options.linkDistance
        for _ in 0..<iterations {
            var fx = [Double](repeating: 0, count: ids.count), fy = fx
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    var dx = x[i] - x[j], dy = y[i] - y[j]
                    var d2 = dx * dx + dy * dy
                    if d2 < 0.01 { dx = 0.1 * (rng.next() - 0.5); dy = 0.1 * (rng.next() - 0.5); d2 = dx * dx + dy * dy + 0.01 }
                    let f = options.repulsion / d2
                    let d = sqrt(d2)
                    fx[i] += f * dx / d; fy[i] += f * dy / d
                    fx[j] -= f * dx / d; fy[j] -= f * dy / d
                }
            }
            for (a, b) in edges {
                let dx = x[b] - x[a], dy = y[b] - y[a]
                let d = max(sqrt(dx * dx + dy * dy), 0.01)
                let f = (d - options.linkDistance) * 0.1
                fx[a] += f * dx / d; fy[a] += f * dy / d
                fx[b] -= f * dx / d; fy[b] -= f * dy / d
            }
            for (heading, members) in clusters where !heading.isEmpty && members.count > 1 {
                let cx = members.map { x[$0] }.reduce(0, +) / Double(members.count)
                let cy = members.map { y[$0] }.reduce(0, +) / Double(members.count)
                for i in members { fx[i] += (cx - x[i]) * options.headingPull; fy[i] += (cy - y[i]) * options.headingPull }
            }
            for i in 0..<ids.count {
                fx[i] -= x[i] * 0.005; fy[i] -= y[i] * 0.005   // gentle pull to the origin
            }
            for i in 0..<ids.count where !pinned[i] {
                let m = sqrt(fx[i] * fx[i] + fy[i] * fy[i])
                let step = min(m, temperature)
                if m > 0 { x[i] += fx[i] / m * step; y[i] += fy[i] / m * step }
            }
            temperature = max(temperature * 0.97, 1)
        }

        for (i, id) in ids.enumerated() {
            layout.positions[id.name] = Placed(name: id.name, x: (x[i] * 10).rounded() / 10, y: (y[i] * 10).rounded() / 10, pinned: pinned[i])
        }
        return layout
    }

    /// Bounding box of all nodes, with a margin.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return (0, 0, 0, 0) }
        return (minX - 80, minY - 60, maxX + 80, maxY + 60)
    }

    /// Node size from degree, within a small range (SPEC “Node rendering”).
    public static func radius(degree: Int) -> Double {
        22 + min(Double(degree), 8) * 2.5
    }
}

/// A tiny deterministic generator so layouts are reproducible across platforms.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
