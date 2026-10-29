import XCTest
@testable import Harness

/// The tree layout the canvas draws (GridClip's map): roots, branches, columns, cross-links.
final class MapLayoutTests: XCTestCase {
    func testTreesHangFromTheNodesNothingPointsAt() throws {
        let graph = try Compiler.compile("| hub - has | a\n| hub - has | b\n| a - leads to | c\n| c - back to | hub\n| lone")
        let map = MapLayout.compute(graph)

        let cases: [(name: String, depth: Int, branch: Int)] = [
            ("hub", 0, 0), ("a", 1, 1), ("b", 1, 2), ("c", 2, 1), ("lone", 0, 0),
        ]
        for c in cases {
            XCTAssertEqual(map[c.name]?.depth, c.depth, "depth of \(c.name)")
            XCTAssertEqual(map[c.name]?.branch, c.branch, "branch of \(c.name)")
        }
        // Larger trees come first: the lone node goes last.
        XCTAssertEqual(map.nodes.first?.id.name, "hub")
        XCTAssertEqual(map.nodes.last?.id.name, "lone")

        let tree = Dictionary(uniqueKeysWithValues: map.edges.map { ("\($0.key.lo.name)-\($0.key.hi.name)", $0.tree) })
        XCTAssertEqual(tree["a-hub"], true)
        XCTAssertEqual(tree["b-hub"], true)
        XCTAssertEqual(tree["a-c"], true)
        XCTAssertEqual(tree["c-hub"], false, "the edge closing the cycle is a cross-link")
    }

    func testColumnsRunLeftToRightAndSiblingsDoNotOverlap() throws {
        let graph = try Compiler.compile("| root - x | one\n| root - x | two\n| root - x | three\n| two - y | deep")
        let map = MapLayout.compute(graph)
        let root = map["root"]!, one = map["one"]!, two = map["two"]!, three = map["three"]!, deep = map["deep"]!
        XCTAssertLessThan(root.x + root.w, one.x)
        XCTAssertEqual(one.x, two.x)
        XCTAssertLessThan(two.x + two.w, deep.x)
        let column = [one, two, three].sorted { $0.y < $1.y }
        for (upper, lower) in zip(column, column.dropFirst()) {
            XCTAssertGreaterThanOrEqual(lower.y, upper.y + upper.h + MapLayout.Metrics.siblingGap - 0.001)
        }
        // A parent is centred on its children.
        XCTAssertEqual(root.center.y, (column.first!.y + column.last!.y + column.last!.h) / 2, accuracy: 0.5)
    }

    func testArrowsFollowDirectionAndLabelsSitOnTheCurve() throws {
        let graph = try Compiler.compile("| a - plans | b\n| a | d\n| d | a\n| a - | e")
        let map = MapLayout.compute(graph)
        func edge(_ x: String, _ y: String) -> MapLayout.PlacedEdge { map.edges.first { $0.key == EdgeKey(NodeID(name: x), NodeID(name: y)) }! }
        // b, d and e all hang under a, so every curve is drawn from a.
        XCTAssertEqual([edge("a", "b").arrowStart, edge("a", "b").arrowEnd], [false, true])
        XCTAssertEqual([edge("a", "d").arrowStart, edge("a", "d").arrowEnd], [true, true])
        XCTAssertEqual([edge("a", "e").arrowStart, edge("a", "e").arrowEnd], [false, false])
        XCTAssertEqual(edge("a", "b").label, "plans")
        let mid = edge("a", "b").point(at: 0.5)
        XCTAssertEqual(mid.x, edge("a", "b").labelAt.x, accuracy: 1)
        XCTAssertEqual(mid.y, edge("a", "b").labelAt.y, accuracy: 1)
    }

    func testNotesProvenanceGlyphAndCuts() throws {
        let long = String(repeating: "word ", count: 80)
        let graph = try Compiler.compile("| paper @kind thing @src world @date 2026-11-03 @text 1 s1\n| plain\n| \(long)")
        let map = MapLayout.compute(graph)
        let paper = map["paper"]!
        XCTAssertEqual(paper.notes, ["date 2026-11-03"], "src, kind and proof are drawn another way")
        XCTAssertTrue(paper.glyph)
        XCTAssertTrue(paper.badge)
        XCTAssertTrue(map["plain"]!.glyph, "an open node always shows an icon")
        XCTAssertFalse(map["plain"]!.badge)
        let cut = map.nodes.first { $0.id.name.hasPrefix("word") }!
        XCTAssertTrue(cut.cut)
        XCTAssertTrue(cut.name.hasSuffix("…"))
        XCTAssertLessThanOrEqual(MapLayout.estimate(cut.name, .name), MapLayout.Metrics.maxText)
    }

    func testPinsKeepTheirPlaceAndMovingReroutes() throws {
        let graph = try Compiler.compile("| a - to | b\n| b @pos 500,-200")
        let map = MapLayout.compute(graph)
        XCTAssertTrue(map["b"]!.pinned)
        XCTAssertEqual(map["b"]!.center.x, 500, accuracy: 0.6)
        XCTAssertEqual(map["b"]!.center.y, -200, accuracy: 0.6)

        let moved = map.moving("a", dx: 0, dy: 300)
        XCTAssertEqual(moved["a"]!.y, map["a"]!.y + 300)
        XCTAssertEqual(moved.edges[0].p0.y, map.edges[0].p0.y + 300, "the curve leaves from where a is now")
        XCTAssertEqual(map.pinnedCenter("a", dx: 10, dy: 20)?.x, (map["a"]!.center.x + 10).rounded())
        XCTAssertEqual(map.centers.positions["b"]?.pinned, true)
        XCTAssertEqual(map.centers.positions["a"]?.x, map["a"]!.center.x)
    }

    func testUnpinnedArrangesAfresh() throws {
        let graph = try Compiler.compile("| a - to | b\n| b @pos 500,-200 @kind thing")
        let fresh = MapLayout.compute(MapLayout.unpinned(graph))
        XCTAssertFalse(fresh["b"]!.pinned)
        XCTAssertEqual(fresh, MapLayout.compute(try Compiler.compile("| a - to | b\n| b @kind thing")))
        XCTAssertEqual(MapLayout.unpinned(graph).node("b")?.note(kind: "kind"), "thing", "other notes stay")
    }

    func testDeterministicAndCoversEveryNode() {
        let state = Demo.state(.large)
        let start = Date()
        let one = MapLayout.compute(state.graph)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(one, MapLayout.compute(state.graph))
        XCTAssertEqual(one.nodes.count, state.graph.nodes.keys.filter { $0.scope.isEmpty }.count)
        XCTAssertEqual(Set(one.nodes.map(\.id.name)).count, one.nodes.count)
        for n in one.nodes {
            XCTAssertGreaterThanOrEqual(n.x, one.minX)
            XCTAssertLessThanOrEqual(n.y + n.h, one.maxY)
        }
        XCTAssertEqual(MapLayout.compute(Graph()).nodes.count, 0)
    }

    func testOnlyTheModelsExtrasAreCards() throws {
        let cases: [(src: String?, boxed: Bool, badge: Bool)] = [
            (nil, false, false), ("text", false, false), ("user", false, true),
            ("world", true, true), ("guess", true, true), ("advice", true, true),
        ]
        for c in cases {
            let line = "| a @kind thing" + (c.src.map { " @src \($0)" } ?? "") + " @date 2026-11-03"
            let a = MapLayout.compute(try Compiler.compile(line))["a"]!
            XCTAssertEqual(a.boxed, c.boxed, "\(c.src ?? "none")")
            XCTAssertEqual(a.badge, c.badge, "\(c.src ?? "none")")
            XCTAssertEqual(a.notes, ["date 2026-11-03"])
            if c.boxed {
                XCTAssertEqual(a.h, MapLayout.Metrics.nameLine + MapLayout.Metrics.noteLine + 2 * MapLayout.Metrics.padY)
            } else {
                typealias M = MapLayout.Metrics
                XCTAssertEqual(a.h, M.openPadY + M.iconLine + M.iconGap + M.nameLine + M.noteLine + M.openPadY, "icon above the name, then the note")
                XCTAssertGreaterThanOrEqual(a.w, M.iconBox + 2 * M.openPadX)
            }
        }
    }

    func testEdgesMeetAnOpenNodesIcon() throws {
        let graph = try Compiler.compile("| anastasia rodriguez - writes | b @src world\n| anastasia rodriguez @src text")
        let map = MapLayout.compute(graph)
        let a = map["anastasia rodriguez"]!, b = map["b"]!
        let e = map.edges[0]
        XCTAssertFalse(a.boxed)
        XCTAssertTrue(b.boxed)
        XCTAssertEqual(e.p0.y, a.y + MapLayout.Metrics.openPadY + MapLayout.Metrics.iconLine / 2, "level with the icon")
        XCTAssertEqual(e.p0.x, a.center.x + MapLayout.Metrics.iconBox / 2, accuracy: 0.5, "beside the icon, not the long name")
        XCTAssertEqual(e.p3.x, b.x)
        XCTAssertEqual(e.p3.y, b.center.y)
    }
}
