import XCTest
@testable import Harness

final class MapStateTests: XCTestCase {
    func testOpeningALogCompilesItAndCountsTurns() throws {
        let log = """
        @turn 1 2026-10-28T14:02:33Z model extract text 1
        | sam - writes @src text @text 1 s2 | paper
        @turn 2 2026-10-28T14:03:00Z user delete sam
        | sam =
        """
        let state = try MapState(log: log)
        XCTAssertEqual(state.turns.count, 2)
        XCTAssertEqual(state.turns[1].who, "user")
        XCTAssertEqual(state.turns[1].what, "delete sam")
        XCTAssertEqual(state.turns[1].lines, ["| sam ="])
        XCTAssertEqual(state.canonical, "| paper\n")
        XCTAssertEqual(state.logText, log + "\n")
    }

    func testEveryActionAppendsAndNeverRewrites() throws {
        var state = MapState()
        state = reduce(state, .submitText("I'm Sam. I'm writing a paper, Ana reviews it on Nov 3."), now: fixedDate)
        XCTAssertEqual(state.evidence.count, 2)
        XCTAssertEqual(state.texts[1]?.hasPrefix("I'm Sam"), true)
        XCTAssertTrue(state.log.isEmpty, "submitting text writes evidence, not map lines")

        let actions: [Action] = [
            .applyModelOutput("| sam @kind person @s 1\n| sam - writes | paper @s 2\n| ana - reviews | paper @s 2\n| ana @src world", prompt: .extract, textID: 1, about: "text 1"),
            .rename("paper", to: "The Thesis"),
            .pin("thesis", x: 120, y: -340.5),
            .pin("thesis", x: 10, y: 20),
            .comment(on: "ana", "second author"),
            .confirm("ana"),
            .addEdge(from: "sam", label: "thanks", to: "Ana"),
            .delete("sam"),
            .release("thesis"),
            .applyLines(["| ana - leads | lab @src user"], what: "suggestion"),
        ]
        var previous = state.log
        for action in actions {
            state = reduce(state, action, now: fixedDate)
            XCTAssertEqual(Array(state.log.prefix(previous.count)), previous, "\(action) rewrote the log")
            XCTAssertGreaterThan(state.log.count, previous.count, "\(action) appended nothing")
            previous = state.log
            XCTAssertEqual(try Compiler.compile(state.logText).nodes, state.graph.nodes, "replaying the log gives the live graph")
        }

        XCTAssertEqual(state.turns.count, actions.count)
        XCTAssertEqual(state.turns[0].header, "@turn 1 2026-10-28T14:02:33Z model extract text 1")
        XCTAssertEqual(state.turns[0].lines, [
            "| sam @kind person @src text @text 1 s1",
            "| paper @src text @text 1 s2",
            "| sam - writes @src text @text 1 s2 | paper",
            "| ana @src text @text 1 s2",
            "| ana - reviews @src text @text 1 s2 | paper",
        ])
        XCTAssertEqual(state.heldBack.filter { $0.kind == .dropped }.map(\.reason), ["Extract may only write `@src text`, not `@src world`"])

        XCTAssertEqual(state.turns[1].lines, ["| paper = thesis"])
        XCTAssertEqual(state.turns[2].lines, ["| thesis @pos 120,-340.5"])
        XCTAssertEqual(state.turns[3].lines, ["| thesis @pos 10,20"])
        XCTAssertEqual(state.turns[4].lines, ["| ana", "second author"])
        XCTAssertEqual(state.turns[6].lines, ["| sam - thanks @src user | ana"])
        XCTAssertEqual(state.turns[8].lines, ["| thesis @pos auto"])

        XCTAssertNil(state.graph.node("sam"))
        XCTAssertNil(state.graph.node("paper"))
        XCTAssertEqual(state.graph.node("thesis")?.note(kind: "pos"), "auto")
        XCTAssertEqual(state.graph.node("ana")?.note(kind: "src"), "user")
        XCTAssertEqual(state.graph.comments.last { $0.text == "second author" }?.attachedTo, .node(n("ana")))
        XCTAssertNotNil(state.graph.edge("ana", "lab"))
    }

    func testNoOpActionsAppendNothing() {
        var state = MapState()
        for action in [Action.confirm("ghost"), .pin("ghost", x: 0, y: 0), .release("ghost"), .comment(on: "ghost", "x"), .rename("a", to: "a"), .applyLines([], what: "nothing")] {
            state = reduce(state, action, now: fixedDate)
        }
        XCTAssertTrue(state.log.isEmpty)
        XCTAssertTrue(state.turns.isEmpty)
    }

    func testPositionNoteRoundTrips() {
        XCTAssertEqual(Position(noteValue: "120,-340.5"), Position(x: 120, y: -340.5))
        XCTAssertEqual(Position(x: 120, y: -340.5).noteValue, "120,-340.5")
        XCTAssertNil(Position(noteValue: "auto"))
    }

    func testCommentThatLooksLikeAStatementStaysAComment() throws {
        var state = reduce(MapState(), .applyLines(["| ana @src user"], what: "x"), now: fixedDate)
        state = reduce(state, .comment(on: "ana", "| not a statement"), now: fixedDate)
        XCTAssertEqual(state.graph.comments.count, 3) // two turn headers and the comment
        XCTAssertEqual(state.graph.comments.last?.text, "not a statement")
        XCTAssertEqual(state.graph.comments.last?.attachedTo, .node(n("ana")))
        XCTAssertEqual(state.graph.nodes.count, 1)
    }
}
