import XCTest
@testable import Harness

/// Golden tests: `.mm` in, canonical `.mm` out. The notation spec's example (§7) is the first case.
final class NotationGoldenTests: XCTestCase {
    func testSpecExampleCanonical() throws {
        let source = try Fixtures.text("spec-example.mm")
        let expected = try Fixtures.text("spec-example.canonical.mm")
        let graph = try Compiler.compile(source)
        XCTAssertEqual(Canonical.render(graph), expected)
    }

    func testSpecExampleGraphMatchesSection7() throws {
        let graph = try Compiler.compile(try Fixtures.text("spec-example.mm"))

        XCTAssertEqual(Set(graph.nodes.keys.filter { $0.scope.isEmpty }.map(\.name)), ["idea", "manuscript", "review", "well-known", "q&a", "draft"])
        XCTAssertEqual(Set(graph.nodes.keys.filter { $0.scope == "meeting" }.map(\.name)), ["outline", "slides", "sam"])
        XCTAssertEqual(graph.scopes, ["", "meeting"], "talk was merged into meeting")

        let idea = try XCTUnwrap(graph.edge("idea", "manuscript"))
        XCTAssertTrue(idea.forward && !idea.backward)

        let ms = try XCTUnwrap(graph.edge("manuscript", "review"))
        XCTAssertTrue(ms.isTwoWay)
        XCTAssertEqual(ms.labels, ["sent on"])
        XCTAssertEqual(ms.notes, ["date 2026-11-03"])

        XCTAssertEqual(graph.node("review")?.notes, ["owner sam", "tag weekly"])
        XCTAssertNotNil(graph.edge("well-known", "q&a"))
        XCTAssertNotNil(graph.edge("draft", "manuscript"))
        XCTAssertNil(graph.node("notes"))
        XCTAssertEqual(graph.comments.map(\.text), ["plan for the paper"])

        let feeds = try XCTUnwrap(graph.edges[EdgeKey(n("manuscript"), n("outline", "meeting"))])
        XCTAssertEqual(feeds.labels, ["feeds"])
        XCTAssertNotNil(graph.edges[EdgeKey(n("sam", "meeting"), n("slides", "meeting"))])
        XCTAssertEqual(graph.edges.count, 7)
    }

    func testCanonicalIsLossless() throws {
        for name in ["spec-example.mm", "outline.mm"] {
            let graph = try Compiler.compile(try Fixtures.text(name))
            let once = Canonical.render(graph)
            let again = try Compiler.compile(once)
            XCTAssertEqual(Canonical.render(again), once, name)
            XCTAssertEqual(again.nodes, graph.nodes, name)
            XCTAssertEqual(Set(again.edges.keys), Set(graph.edges.keys), name)
            for (key, edge) in graph.edges {
                let other = try XCTUnwrap(again.edges[key])
                XCTAssertEqual(Set(other.labels), Set(edge.labels))
                XCTAssertEqual(Set(other.notes), Set(edge.notes))
                XCTAssertEqual(other.forward || other.backward, edge.forward || edge.backward)
                XCTAssertEqual(other.isTwoWay, edge.isTwoWay)
            }
        }
    }

    func testOutlineHeadingsAndAttachedComments() throws {
        let graph = try Compiler.compile(try Fixtures.text("outline.mm"))
        XCTAssertEqual(Canonical.render(graph), try Fixtures.text("outline.canonical.mm"))

        let comments = graph.comments
        XCTAssertEqual(comments.map(\.text), ["# people", "ana is the second author", "# timeline"])
        XCTAssertEqual(comments[0].heading, ["people"])
        XCTAssertTrue(comments[0].isHeading)
        XCTAssertEqual(comments[1].heading, ["people"])
        XCTAssertEqual(comments[1].attachedTo, .edge(EdgeKey(n("ana"), n("paper"))))
        XCTAssertEqual(comments[2].heading, ["timeline"])
    }

    func testCommentAfterMultiLinkPathAttachesToLastNode() throws {
        let graph = try Compiler.compile("| a | b | c\nabout c\n| d\nabout d\n| e\n\nnot attached: previous line was a comment")
        XCTAssertEqual(graph.comments[0].attachedTo, .node(n("c")))
        XCTAssertEqual(graph.comments[1].attachedTo, .node(n("d")))
        XCTAssertEqual(graph.comments[2].attachedTo, .node(n("e")), "blank lines are ignored, so the comment still follows the statement")
    }

    func testTurnHeadersAreNotPartOfTheCanonicalForm() throws {
        let graph = try Compiler.compile("@turn 1 2026-10-28T14:02:33Z model expand dog\n| dog - chases @src guess | cat")
        XCTAssertEqual(Canonical.render(graph), "| dog - chases @src guess | cat\n")
        XCTAssertTrue(graph.comments[0].isTurnHeader)
    }

    func testSingleValuedNotesReplace() throws {
        let graph = try Compiler.compile("| dog @pos 1 2 @src guess\n| dog @pos 3 4\n| dog @src user\n| dog @tag a\n| dog @tag b")
        XCTAssertEqual(graph.node("dog")?.notes, ["pos 3 4", "src user", "tag a", "tag b"])
    }

    func testEditsAffectEarlierLinesOnly() throws {
        let graph = try Compiler.compile("| a | b\n| a = c\n| a | d")
        XCTAssertEqual(Set(graph.nodes.keys.map(\.name)), ["b", "c", "a", "d"])
        XCTAssertNotNil(graph.edge("c", "b"))
        XCTAssertNotNil(graph.edge("a", "d"))
    }

    func testRenameOntoExistingNodeMerges() throws {
        let graph = try Compiler.compile("| a - x | b\n| c - y | b\n| c @tag t\n| a = c")
        XCTAssertNil(graph.node("a"))
        let edge = try XCTUnwrap(graph.edge("c", "b"))
        XCTAssertEqual(edge.labels, ["y", "x"])
        XCTAssertEqual(graph.node("c")?.notes, ["tag t"])
        XCTAssertEqual(graph.edges.count, 1)
    }

    func testScopeDeleteRemovesEverything() throws {
        let graph = try Compiler.compile("| a\n| @ s\n| x | y\n| a@ | x\n| @ s =\n| b")
        XCTAssertEqual(graph.scopes, [""])
        XCTAssertEqual(Set(graph.nodes.keys.map(\.name)), ["a", "b"])
        XCTAssertTrue(graph.edges.isEmpty)
        XCTAssertEqual(graph.currentScope, "")
    }

    func testUnknownScopeIsAnError() {
        XCTAssertThrowsError(try Compiler.compile("| a\n| b@nowhere | a")) { error in
            XCTAssertEqual((error as? NotationError)?.line, 2)
        }
    }
}
