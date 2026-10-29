import XCTest
@testable import Harness

final class CanvasTests: XCTestCase {
    func testLayoutIsDeterministicAndHonoursPins() throws {
        let graph = try Compiler.compile("# a\n| x | y\n| y | z\n# b\n| p | q\n| q @pos 100,-50\n| lonely")
        let one = Layout.compute(graph, iterations: 100)
        let two = Layout.compute(graph, iterations: 100)
        XCTAssertEqual(one, two, "same graph and seed give the same positions")
        XCTAssertEqual(one.positions["q"]?.x, 100)
        XCTAssertEqual(one.positions["q"]?.y, -50)
        XCTAssertTrue(one.positions["q"]!.pinned)
        XCTAssertFalse(one.positions["x"]!.pinned)
        XCTAssertEqual(one.positions.count, 6)

        var other = LayoutOptions()
        other.seed = 2
        XCTAssertNotEqual(Layout.compute(graph, options: other, iterations: 100).positions["x"], one.positions["x"])

        // Linked nodes end up closer than unlinked ones; nodes never overlap exactly.
        func d(_ a: String, _ b: String) -> Double {
            let p = one.positions[a]!, q = one.positions[b]!
            return hypot(p.x - q.x, p.y - q.y)
        }
        XCTAssertLessThan(d("x", "y"), d("x", "lonely"))
        XCTAssertGreaterThan(d("x", "y"), 10)

        // Previous positions seed the next layout so nodes do not jump.
        let more = try Compiler.compile("# a\n| x | y\n| y | z\n# b\n| p | q\n| q @pos 100,-50\n| lonely\n| z | w")
        let next = Layout.compute(more, iterations: 30, previous: one)
        XCTAssertLessThan(hypot(next.positions["x"]!.x - one.positions["x"]!.x, next.positions["x"]!.y - one.positions["x"]!.y), 200)
    }

    func testLargeMapLaysOutInReasonableTime() throws {
        let state = Demo.state(.large)
        XCTAssertGreaterThan(state.graph.nodes.count, 300)
        let start = Date()
        let layout = Layout.compute(state.graph, iterations: 50)
        XCTAssertEqual(layout.positions.count, state.graph.nodes.count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testIconMatching() throws {
        let manifest = try IconManifest(json: Data(#"{"dog": ["dog", "puppy", "hound"], "house": ["house", "home"], "paper": ["paper", "document"]}"#.utf8))
        XCTAssertEqual(manifest.icons(for: "dog house"), ["dog", "house"])
        XCTAssertEqual(manifest.icons(for: "puppies"), ["dog"])
        XCTAssertEqual(manifest.icons(for: "the paper-dog"), ["paper", "dog"])
        XCTAssertEqual(manifest.icons(for: "dog dog"), ["dog"])
        XCTAssertEqual(manifest.icons(for: "zebra"), [])
        let (shown, more) = IconManifest.badge(["a", "b", "c", "d", "e"])
        XCTAssertEqual(shown, ["a", "b", "c"])
        XCTAssertEqual(more, 2)
        XCTAssertEqual(IconManifest.fallbackSymbol(kind: "person"), "person")
        XCTAssertEqual(IconManifest.fallbackSymbol(kind: nil), "circle")
    }

    func testExports() throws {
        let state = Demo.state(.typical)
        let graph = state.graph
        XCTAssertEqual(Export.canonical(graph), state.canonical)

        let md = Export.markdown(graph)
        XCTAssertTrue(md.hasPrefix("# people\n- ana (person)\n"))
        XCTAssertTrue(md.contains("  - → met in lisbon"))
        XCTAssertTrue(md.contains("- journal [user]"))

        let json = try Export.json(graph, layout: Layout.compute(graph, iterations: 10))
        let decoded = try JSONDecoder().decode(Export.JSONGraph.self, from: json)
        XCTAssertEqual(decoded.nodes.count, graph.nodes.count)
        XCTAssertEqual(decoded.edges.count, graph.edges.count)
        XCTAssertNotNil(decoded.nodes.first?.x)
        XCTAssertEqual(decoded.nodes.first { $0.name == "paper" }?.kind, "thing")

        let svg = Export.svg(graph, layout: Layout.compute(graph, iterations: 10))
        XCTAssertTrue(svg.hasPrefix("<svg"))
        XCTAssertTrue(svg.contains(">paper<"))
        XCTAssertTrue(svg.contains("stroke-dasharray=\"2 3\""), "guess edges are dotted")
        XCTAssertTrue(svg.contains("marker-end"))
        XCTAssertEqual(svg.components(separatedBy: "<g ").count - 1, graph.nodes.count)
    }

    func testImportMM() throws {
        XCTAssertEqual(try Import.lines(fromMM: "| a | b\n\ncomment\n| c"), ["| a | b", "comment", "| c"])
        XCTAssertThrowsError(try Import.lines(fromMM: "| a@talk"))
    }

    func testDemoFixturesCompileAndCarryProvenance() {
        for map in Demo.Map.allCases {
            let state = Demo.state(map)
            XCTAssertFalse(state.graph.nodes.isEmpty, map.rawValue)
            XCTAssertTrue(state.graph.nodes.values.allSatisfy { $0.note(kind: "src") != nil }, "\(map): every node has provenance")
            XCTAssertEqual(state.context.paragraphs.count, 1, map.rawValue)
            XCTAssertGreaterThan(state.evidence.count, 0, map.rawValue)
            XCTAssertTrue(state.errors.isEmpty, map.rawValue)
        }
        XCTAssertEqual(Demo.state(.tiny).graph.rootNames, ["ana", "paper", "sam"])
        XCTAssertEqual(Demo.state(.typical).turns.count, 3)
        XCTAssertEqual(Demo.state(.typical).undoable, [1, 2, 3])
        XCTAssertGreaterThan(Demo.state(.large).graph.nodes.count, 300)
        XCTAssertEqual(Outline.build(Demo.state(.typical).graph).map(\.title), ["", "people", "places", "work"])
    }

    func testDemoClientAnswersEveryPrompt() async throws {
        let runner = ModelRunner(client: Demo.client(), settings: ModelSettings(model: "demo"))
        let state = Demo.state(.tiny)
        let expand = try await runner.run(.expand, state: state, item: ModelRunner.neighbourhood(of: "paper", in: state.graph))
        XCTAssertEqual(expand.gate.lines.count, 5)
        XCTAssertEqual(expand.promptTokens, 900)
        let chat = try await runner.run(.chat, state: state, item: "who reviews?")
        XCTAssertTrue(ChatReply.parse(chat.rawOutput).prose.hasPrefix("Ana reviews"))
        XCTAssertEqual(ChatReply.parse(chat.rawOutput).lines.count, 1)
        let clarify = try await runner.run(.clarify, state: state, item: "")
        XCTAssertEqual(ClarifyQuestion.parse(clarify.rawOutput).count, 2)
    }
}
