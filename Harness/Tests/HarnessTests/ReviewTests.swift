import XCTest
@testable import Harness

/// The model's additions go on the map at once and are reviewed there.
final class ReviewTests: XCTestCase {
    let text = "I'm Sam. I'm writing a paper, Ana reviews it on Nov 3."

    func seeded() -> MapState {
        var state = reduce(MapState(), .submitText(text), now: fixedDate)
        state = reduce(state, .applyLines(["| sam @src user", "| paper @src user"], what: "seed"), now: fixedDate)
        return state
    }

    func testAppendAllKeepsRepeatsAndIgnoresTheBudget() {
        let state = seeded()
        let ideas = ["apple", "bread", "cheese", "dates", "eggs", "figs", "grapes", "honey", "ice", "jam"]
        let lines = ideas.map { "| \($0) @src world" }.joined(separator: "\n") + "\n| apple @src world"
        let budgeted = Gate.run(lines, graph: state.graph, evidence: state.proofEvidence, options: GateOptions(prompt: .expand))
        XCTAssertEqual(budgeted.deferred.count, 2)
        XCTAssertTrue(budgeted.events.contains { $0.reason == "already in the map" })

        let all = Gate.run(lines, graph: state.graph, evidence: state.proofEvidence, options: .appendAll(prompt: .expand))
        XCTAssertEqual(all.deferred.count, 0)
        XCTAssertEqual(all.lines.count, 11, "every idea, and the repeat too")
        XCTAssertFalse(all.events.contains { $0.kind == .dropped || $0.kind == .deferred })

        let next = reduce(state, .applyModelOutput(lines, prompt: .expand, textID: nil, about: "x", appendAll: true), now: fixedDate)
        XCTAssertNotNil(next.graph.node("jam"))
        XCTAssertTrue(next.suggestions.isEmpty)
    }

    func testMarksWhatATurnAddsAndDeletesItInOneTurn() {
        let before = seeded()
        let after = reduce(before, .applyModelOutput("| ana @src world\n| ana - reviews | paper @src world\n| sam - writes | paper @src guess", prompt: .expand, textID: nil, about: "x", appendAll: true), now: fixedDate)
        var review = Review()
        review.mark(from: before.graph, to: after.graph)
        XCTAssertEqual(review.nodes, ["ana"])
        XCTAssertEqual(review.edges, [EdgeKey(NodeID(name: "paper"), NodeID(name: "sam"))], "a new node's links go with it; a link between nodes already there is its own")
        XCTAssertEqual(review.count, 2)

        let turns = after.turns.count
        let gone = reduce(after, .applyLines(review.deletion(in: after.graph), what: "delete"), now: fixedDate)
        XCTAssertEqual(gone.turns.count, turns + 1)
        XCTAssertNil(gone.graph.node("ana"))
        XCTAssertNil(gone.graph.edge("sam", "paper"))
        XCTAssertNotNil(gone.graph.node("paper"))

        let one = reduce(after, .applyLines(review.deletion(in: after.graph, nodes: [], edges: review.edges), what: "delete"), now: fixedDate)
        XCTAssertNotNil(one.graph.node("ana"), "deleting the link alone keeps the node")
        XCTAssertNil(one.graph.edge("sam", "paper"))

        review.prune(one.graph)
        XCTAssertEqual(review.nodes, ["ana"])
        XCTAssertTrue(review.edges.isEmpty)
        review.accept(node: "ana")
        XCTAssertTrue(review.isEmpty)
    }
}
