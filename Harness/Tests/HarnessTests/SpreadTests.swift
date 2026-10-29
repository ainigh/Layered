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
                XCTAssertLessThanOrEqual(hypot(b.x - a.x, b.y - a.y), 10.01, "a step never jumps over a node")
            }
            previous = spread.boxes
        }
        XCTAssertGreaterThan(spread.zoom, before * 3, "the tall column spreads sideways into the wide view")
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
        XCTAssertTrue(tooClose(far).isEmpty)
        XCTAssertGreaterThan(near.zoom, far.zoom)
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
}
