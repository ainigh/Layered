import XCTest
@testable import Harness

/// Fill the view: nodes slide into the room around them so the map fits the view larger.
final class SpreadTests: XCTestCase {
    /// A hub with many children: one tall column, a poor fit for a wide view.
    func tallMap() throws -> MapLayout {
        let lines = (1...14).map { "| hub - has | child \($0)" }.joined(separator: "\n")
        return MapLayout.compute(try Compiler.compile(lines))
    }

    func tooClose(_ spread: Spread) -> [(String, String)] {
        var out: [(String, String)] = []
        for i in spread.boxes.indices {
            for j in spread.boxes.indices where j > i {
                let a = spread.boxes[i], b = spread.boxes[j]
                let ox = min(a.x + a.w, b.x + b.w) - max(a.x, b.x) + spread.gap
                let oy = min(a.y + a.h, b.y + b.h) - max(a.y, b.y) + spread.gap
                if ox > 1e-3, oy > 1e-3 { out.append((spread.names[i], spread.names[j])) }
            }
        }
        return out
    }

    func testTheMapZoomsInFurtherAndKeepsItsGap() throws {
        let map = try tallMap()
        var spread = Spread(layout: map, viewWidth: 1200, viewHeight: 500, gap: 20)
        let before = spread.zoom
        XCTAssertTrue(tooClose(spread).isEmpty, "siblings closer than the gap are pushed apart first")
        var previous = spread.boxes
        while !spread.finished {
            spread.step()
            for (a, b) in zip(previous, spread.boxes) {
                XCTAssertLessThanOrEqual(hypot(b.x - a.x, b.y - a.y), 10.01 * Double(Spread.movesPerStep),
                                         "a node moves a few points at a time, never far enough to jump over one")
            }
            previous = spread.boxes
        }
        XCTAssertGreaterThan(spread.zoom, before * 2.5, "the tall column spreads sideways into the wide view")
        XCTAssertTrue(tooClose(spread).isEmpty)
        XCTAssertLessThan(spread.steps, Spread.maxSteps)

        var again = Spread(layout: map, viewWidth: 1200, viewHeight: 500, gap: 20)
        again.run()
        XCTAssertEqual(again.centers, spread.centers, "the same map spreads the same way every time")
    }

    func testAWiderGapKeepsNodesFurtherApart() throws {
        let map = try tallMap()
        var near = Spread(layout: map, viewWidth: 1200, viewHeight: 500, gap: 8)
        var far = Spread(layout: map, viewWidth: 1200, viewHeight: 500, gap: 60)
        near.run()
        far.run()
        XCTAssertTrue(tooClose(near).isEmpty)
        XCTAssertTrue(tooClose(far).isEmpty)
    }

    func testItStopsAtTheZoomCapAndLeavesAFittingMapAlone() throws {
        let map = try tallMap()
        var capped = Spread(layout: map, viewWidth: 1200, viewHeight: 500, gap: 20, maxZoom: 0.01)
        capped.step()
        XCTAssertTrue(capped.finished)

        let one = MapLayout.compute(try Compiler.compile("| alone"))
        XCTAssertTrue(Spread(layout: one, viewWidth: 800, viewHeight: 600, gap: 20).finished)
    }

    func testPlacingPinsAndReroutesAndArrangeIsOneUndo() throws {
        let map = try tallMap()
        var spread = Spread(layout: map, viewWidth: 1200, viewHeight: 500, gap: 20)
        spread.run()
        let placed = map.placing(spread.centers)
        XCTAssertTrue(placed.nodes.allSatisfy(\.pinned))
        for e in placed.edges {
            let a = placed[e.key.lo.name]!, b = placed[e.key.hi.name]!
            let ends = [e.p0, e.p3]
            XCTAssertTrue(ends.contains { abs($0.x - a.center.x) <= a.w / 2 + 0.5 && abs($0.y - a.center.y) <= a.h / 2 + 0.5 }, "the curve meets \(a.id.name)")
            XCTAssertTrue(ends.contains { abs($0.x - b.center.x) <= b.w / 2 + 0.5 && abs($0.y - b.center.y) <= b.h / 2 + 0.5 }, "the curve meets \(b.id.name)")
        }

        let lines = (1...14).map { "| hub - has | child \($0)" }
        var state = reduce(MapState(), .applyLines(lines, what: "seed"), now: fixedDate)
        let turns = state.turns.count
        state = reduce(state, .arrange(spread.centers.mapValues { Position(x: $0.x, y: $0.y) }), now: fixedDate)
        XCTAssertEqual(state.turns.count, turns + 1, "every node moves in one turn")
        XCTAssertEqual(state.graph.node("hub")?.note(kind: "pos"), Position(x: spread.centers["hub"]!.x, y: spread.centers["hub"]!.y).noteValue)
        state = reduce(state, .undo, now: fixedDate)
        XCTAssertNil(state.graph.node("hub")?.note(kind: "pos"))
        XCTAssertNil(state.graph.node("child 7")?.note(kind: "pos"))
    }

    // MARK: - No crossings

    /// What the canvas would draw crossing, worked out from the layout itself: two links
    /// crossing away from a node they share, and a link through a node it doesn't join
    /// (more than a hair inside it). Only the links in `links` (by their two ends), if given.
    func clashes(_ layout: MapLayout, links: Set<[String]>? = nil) -> Set<String> {
        typealias P = MapLayout.Point
        let edges = layout.edges.filter { links?.contains([$0.key.lo.name, $0.key.hi.name].sorted()) ?? true }
        // Links meet or not as flattened the way the spread flattens them (two links leaving
        // one node side by side can come within a hair of each other); nodes are checked finer.
        let lines = edges.map { e in (0...Spread.pieces).map { e.point(at: Double($0) / Double(Spread.pieces)) } }
        let fine = edges.map { e in (0...64).map { e.point(at: Double($0) / 64) } }
        let around = lines.map { l in (l.map(\.x).min()!, l.map(\.y).min()!, l.map(\.x).max()!, l.map(\.y).max()!) }
        func box(_ name: String, grow c: Double) -> (Double, Double, Double, Double) {
            let n = layout[name]!
            return (n.x - c, n.y - c, n.x + n.w + c, n.y + n.h + c)
        }
        func inside(_ p: P, _ b: (Double, Double, Double, Double)) -> Bool { p.x > b.0 && p.x < b.2 && p.y > b.1 && p.y < b.3 }
        func meets(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double)) -> Bool {
            a.0 <= b.2 && b.0 <= a.2 && a.1 <= b.3 && b.1 <= a.3
        }
        var out = Set<String>()
        for (i, e) in edges.enumerated() {
            let ends = [e.key.lo.name, e.key.hi.name]
            for n in layout.nodes where !ends.contains(n.id.name) {
                let b = box(n.id.name, grow: -0.5)
                // Strictly inside the node, sampled finely along the curve.
                if meets(around[i], b), fine[i].contains(where: { inside($0, b) }) { out.insert("\(ends) through \(n.id.name)") }
            }
            for (j, f) in edges.enumerated() where j > i && meets(around[i], around[j]) {
                let shared = ends.first { $0 == f.key.lo.name || $0 == f.key.hi.name }
                outer: for s in 1..<lines[i].count {
                    let a0 = lines[i][s - 1], a1 = lines[i][s]
                    guard meets((min(a0.x, a1.x), min(a0.y, a1.y), max(a0.x, a1.x), max(a0.y, a1.y)), around[j]) else { continue }
                    for t in 1..<lines[j].count {
                        guard let p = Spread.meet(a0, a1, lines[j][t - 1], lines[j][t]) else { continue }
                        if let k = shared, inside(p, box(k, grow: Spread.clearance + 0.5)) { continue }
                        out.insert("\(ends) crosses \([f.key.lo.name, f.key.hi.name])")
                        break outer
                    }
                }
            }
        }
        return out
    }

    /// The links a spread keeps clear, by their two ends.
    func kept(_ spread: Spread) -> Set<[String]> {
        Set(spread.links.indices.filter { spread.kept[$0] }.map { [spread.names[spread.links[$0].a], spread.names[spread.links[$0].b]].sorted() })
    }

    /// Runs a spread (for at most `frames` frames of four steps), checking every frame as the
    /// canvas shows it: no link it keeps clear crosses anything it did not already.
    func assertNoNewClashes(_ map: MapLayout, view: (Double, Double) = (1200, 500), gap: Double = 20, frames: Int = .max,
                            file: StaticString = #filePath, line: UInt = #line) -> Spread {
        var spread = Spread(layout: map, viewWidth: view.0, viewHeight: view.1, gap: gap)
        let keep = kept(spread)
        let trees = Set(map.edges.filter(\.tree).map { [$0.key.lo.name, $0.key.hi.name].sorted() })
        XCTAssertTrue(trees.isSubset(of: keep), "every tree link is kept clear", file: file, line: line)
        let start = clashes(map.placing(spread.centers), links: keep)
        var shown = 0
        while !spread.finished, shown < frames {
            spread.run(limit: 4)
            let now = clashes(map.placing(spread.centers), links: keep).subtracting(start)
            XCTAssertTrue(now.isEmpty, "step \(spread.steps): \(now.sorted())", file: file, line: line)
            if !now.isEmpty { break }
            shown += 1
        }
        XCTAssertGreaterThan(shown, 1, file: file, line: line)
        return spread
    }

    func testNoStepCrossesLinksOrRunsALinkThroughANode() throws {
        let map = try tallMap()
        XCTAssertTrue(clashes(map.placing(Spread(layout: map, viewWidth: 1200, viewHeight: 500, gap: 20).centers)).isEmpty,
                      "it starts with nothing crossing")
        let spread = assertNoNewClashes(map)
        XCTAssertGreaterThan(spread.zoom, Spread(layout: map, viewWidth: 1200, viewHeight: 500, gap: 20).zoom * 2, "and still fills the view")
        _ = assertNoNewClashes(map, view: (500, 1200))
    }

    func testTheDemoMapsSpreadWithoutCrossings() throws {
        for which in [Demo.Map.tiny, .typical] {
            let map = MapLayout.compute(MapLayout.unpinned(Demo.state(which).graph))
            for view in [(1200.0, 700.0), (700.0, 1100.0)] {
                let before = Spread(layout: map, viewWidth: view.0, viewHeight: view.1, gap: 24).zoom
                let spread = assertNoNewClashes(map, view: view, gap: 24)
                XCTAssertGreaterThan(spread.zoom, before * 1.1, "\(which)")
            }
        }
    }

    /// The large demo's cross-links already cross all over it; its trees still never tangle
    /// (the first 50 frames, checked one by one), and it still fills the view.
    func testTheLargeDemoKeepsItsTreesClear() throws {
        let map = MapLayout.compute(MapLayout.unpinned(Demo.state(.large).graph))
        let before = Spread(layout: map, viewWidth: 1200, viewHeight: 700, gap: 24).zoom
        let spread = assertNoNewClashes(map, view: (1200, 700), gap: 24, frames: 50)
        XCTAssertGreaterThan(spread.zoom, before * 1.5)
    }

    func testCrossLinksAndManyTreesSpreadWithoutCrossings() throws {
        var lines: [String] = []
        for t in 1...4 {
            lines.append("| root \(t) - has | a\(t)")
            lines.append("| root \(t) - has | b\(t)")
            for k in 1...4 { lines.append("| a\(t) - has | a\(t) leaf \(k)") }
            for k in 1...3 { lines.append("| b\(t) - has | b\(t) leaf \(k)") }
        }
        lines.append("| a1 leaf 2 - see also | b3 leaf 1")
        lines.append("| b2 - see also | a4")
        let map = MapLayout.compute(try Compiler.compile(lines.joined(separator: "\n")))
        _ = assertNoNewClashes(map, view: (1400, 600))
        _ = assertNoNewClashes(map, view: (600, 1200))
    }

    // MARK: - Arranged to fit

    func hub() throws -> MapLayout {
        MapLayout.compute(try Compiler.compile((1...14).map { "| hub - has | child \($0)" }.joined(separator: "\n")))
    }

    func testArrangingToFitTanglesNothingAndKeepsEveryNode() throws {
        let typical = MapLayout.compute(MapLayout.unpinned(Demo.state(.typical).graph))
        let forest = MapLayout.compute(try Compiler.compile((1...5).flatMap { t in (1...3).map { "| root \(t) - has | leaf \(t).\($0)" } }.joined(separator: "\n")))
        for map in [try hub(), typical, forest] {
            let trees = Set(map.edges.filter(\.tree).map { [$0.key.lo.name, $0.key.hi.name].sorted() })
            let before = clashes(map.placing(Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id.name, $0.center) })), links: trees)
            for view in [(1200.0, 700.0), (700.0, 1100.0)] {
                let arranged = map.arranged(toFit: view.0, view.1)
                XCTAssertEqual(Set(arranged.nodes.map(\.id.name)), Set(map.nodes.map(\.id.name)))
                XCTAssertTrue(arranged.nodes.allSatisfy(\.pinned))
                XCTAssertTrue(clashes(arranged, links: trees).isSubset(of: before), "\(clashes(arranged, links: trees).subtracting(before).sorted())")
                for (i, a) in arranged.nodes.enumerated() {
                    for b in arranged.nodes[(i + 1)...] {
                        let apart = max(max(a.x, b.x) - min(a.x + a.w, b.x + b.w), max(a.y, b.y) - min(a.y + a.h, b.y + b.h))
                        XCTAssertGreaterThan(apart, 0, "\(a.id.name) and \(b.id.name) overlap")
                    }
                }
            }
        }
    }

    func testAHubGoesRoundItsRootAndFillsMore() throws {
        let map = try hub()
        for view in [(1200.0, 700.0), (700.0, 1100.0)] {
            let arranged = map.arranged(toFit: view.0, view.1)
            let root = arranged["hub"]!
            XCTAssertTrue(arranged.nodes.contains { $0.center.x < root.center.x - root.w }, "branches on its left too")
            var plain = Spread(layout: map, viewWidth: view.0, viewHeight: view.1, gap: 24)
            var shaped = Spread(layout: arranged, viewWidth: view.0, viewHeight: view.1, gap: 24)
            plain.run()
            shaped.run()
            XCTAssertGreaterThan(shaped.zoom, plain.zoom * 1.3, "\(view)")
        }
        XCTAssertEqual(map.arranged(toFit: 1200, 700), map.arranged(toFit: 1200, 700), "the same every time")
    }

    func testTreesGoSideBySideInAWideView() throws {
        let forest = MapLayout.compute(try Compiler.compile((1...5).flatMap { t in (1...3).map { "| root \(t) - has | leaf \(t).\($0)" } }.joined(separator: "\n")))
        let arranged = forest.arranged(toFit: 1400, 500)
        let roots = (1...5).map { arranged["root \($0)"]!.center.x }
        XCTAssertGreaterThan(Set(roots).count, 1, "the trees no longer stand in one column")
        XCTAssertGreaterThan(arranged.width / arranged.height, forest.width / forest.height)
    }

    func testSpreadingFromTheArrangementNeverTangles() throws {
        let typical = MapLayout.compute(MapLayout.unpinned(Demo.state(.typical).graph))
        for map in [try hub(), typical] {
            for view in [(1200.0, 700.0), (700.0, 1100.0)] {
                _ = assertNoNewClashes(map.arranged(toFit: view.0, view.1), view: view, gap: 24)
            }
        }
    }
}

