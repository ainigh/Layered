import XCTest
@testable import Harness

final class HistoryTests: XCTestCase {
    func testTransitionCoversEveryEditShape() throws {
        // from → to pairs; the lines must take `from` to exactly `to` by appending.
        let cases: [(String, String)] = [
            ("| a | b", ""),
            ("", "| a - x @n 1 | b\n| b @kind thing"),
            ("| a - x | b", "| a | b"),                       // label removed
            ("| a | b\n| b | a", "| a | b"),                  // direction removed
            ("| a | b", "| a - | b"),                         // directed → undirected
            ("| a - | b", "| a | b"),
            ("| a @tag x @tag y", "| a @tag y"),              // multi-valued note removed
            ("| a @src guess", "| a @src text"),              // single-valued note changed
            ("| a @src guess", "| a"),                        // note removed, node kept
            ("| a | b\n| b | c\n| c | d", "| a | b\n| c | d"),
            ("plan\n| a", "| a"),                             // comment removed
            ("| a", "plan\n| a\n| a\nabout a"),               // comments added, one attached
            ("| a - x | b\nabout the edge", "| a - x | b"),
            ("# h1\n| a\n# h2\n| b", "# h2\n| b"),
            ("| a | b", "| c = d\n| c | d".replacingOccurrences(of: "| c = d\n", with: "")),
        ]
        for (from, to) in cases {
            let f = try Compiler.compile(from), t = try Compiler.compile(to)
            let lines = Transition.lines(from: f, to: t)
            let reached = try Transition.apply(lines, to: f)
            XCTAssertEqual(Canonical.render(reached), Canonical.render(t), "\(from) → \(to): \(lines)")
        }
    }

    func testUndoRedoAppendInverseTurns() throws {
        var state = MapState()
        state = reduce(state, .applyLines(["| sam @src user", "| sam - writes @src user | paper", "| paper @kind thing"], what: "typed"), now: fixedDate)
        let afterOne = state.canonical
        state = reduce(state, .rename("paper", to: "thesis"), now: fixedDate)
        state = reduce(state, .delete("sam"), now: fixedDate)
        let afterThree = state.canonical
        XCTAssertEqual(state.undoable, [1, 2, 3])

        state = reduce(state, .undo, now: fixedDate)
        XCTAssertEqual(state.turns.last?.what, "undo 3")
        XCTAssertNotNil(state.graph.node("sam"))
        XCTAssertNotNil(state.graph.edge("sam", "thesis"))
        XCTAssertEqual(state.undoable, [1, 2])
        XCTAssertEqual(state.redoable, [3])

        state = reduce(state, .undo, now: fixedDate)
        XCTAssertEqual(state.canonical, afterOne)
        XCTAssertEqual(state.redoable, [3, 2])

        state = reduce(state, .redo, now: fixedDate)
        XCTAssertEqual(state.turns.last?.what, "redo 2")
        XCTAssertNotNil(state.graph.node("thesis"))
        state = reduce(state, .redo, now: fixedDate)
        XCTAssertEqual(state.canonical, afterThree)
        XCTAssertEqual(state.redoable, [])
        XCTAssertEqual(state.undoable, [1, 2, 3])

        // A new action after an undo clears the redo stack.
        state = reduce(state, .undo, now: fixedDate)
        state = reduce(state, .applyLines(["| ana @src user"], what: "x"), now: fixedDate)
        XCTAssertEqual(state.redoable, [])
        state = reduce(state, .redo, now: fixedDate)
        XCTAssertEqual(state.turns.count, 9, "nothing to redo")

        // The log only ever grew, and replaying it gives the same stacks.
        XCTAssertEqual(state.log.filter { $0.hasPrefix("@turn") }.count, 9)
        let reopened = try MapState(log: state.logText, evidence: state.evidence)
        XCTAssertEqual(reopened.undoable, state.undoable)
        XCTAssertEqual(reopened.redoable, state.redoable)
        XCTAssertEqual(reopened.snapshots, state.snapshots)
        XCTAssertEqual(reopened.graph(atTurn: 1).map(Canonical.render), afterOne)
    }

    func testUndoOfAModelTurnRestoresNothingItDidNotAdd() {
        var state = reduce(MapState(), .submitText("I'm Sam. Ana reviews the paper."), now: fixedDate)
        state = reduce(state, .applyModelOutput("| sam @kind person @s 1", prompt: .extract, textID: 1, about: "t"), now: fixedDate)
        state = reduce(state, .applyModelOutput("| ana - reviews | paper @s 2", prompt: .extract, textID: 1, about: "t"), now: fixedDate)
        state = reduce(state, .undo, now: fixedDate)
        XCTAssertEqual(state.graph.rootNames, ["sam"])
        XCTAssertEqual(state.turns.last?.lines, ["| ana =", "| paper ="])
    }

    func testUndoWithNothingToDoStillMovesTheTurn() {
        var state = reduce(MapState(), .applyLines(["| a"], what: "x"), now: fixedDate)
        state = reduce(state, .applyLines(["| a"], what: "same again"), now: fixedDate)
        XCTAssertEqual(state.turns.count, 2)
        state = reduce(state, .undo, now: fixedDate)
        XCTAssertEqual(state.turns.count, 2, "no inverse lines were needed")
        XCTAssertEqual(state.redoable, [2])
    }

    func testOptimizeArchivesAndKeepsUndoWorking() throws {
        var state = reduce(MapState(), .applyLines(["| a | b", "| b | c"], what: "x"), now: fixedDate)
        state = reduce(state, .delete("c"), now: fixedDate)
        let storage = InMemoryStorage()
        Persistence.sync(before: MapState(), after: state, storage: storage)
        let before = state.logSize
        state = try Persistence.optimize(state, storage: storage, now: fixedDate)
        XCTAssertLessThan(state.logSize.lines, before.lines)
        XCTAssertEqual(state.logText, "| a | b\n")
        XCTAssertEqual(try storage.readLog(), "| a | b\n")
        XCTAssertEqual(try storage.archivedLogs(), ["map-2026-10-28.mm"])
        XCTAssertTrue(storage.archivedLog(named: "map-2026-10-28.mm")!.contains("@turn 2"))

        state = reduce(state, .undo, now: fixedDate)
        XCTAssertNotNil(state.graph.node("c"), "undo still works after Optimize in the same session")
        XCTAssertEqual(state.turns.last?.number, 3, "turn numbering continues")
        XCTAssertEqual(state.log, ["| a | b", "@turn 3 2026-10-28T14:02:33Z user undo 2", "| b | c"])

        var settings = Settings()
        XCTAssertFalse(Persistence.optimizeDue(state, settings: settings))
        settings.optimizeEveryTurns = 1
        XCTAssertTrue(Persistence.optimizeDue(state, settings: settings))
    }

    func testBranchFromHereArchivesLaterTurns() throws {
        var state = reduce(MapState(), .applyLines(["| a"], what: "one"), now: fixedDate)
        state = reduce(state, .applyLines(["| b"], what: "two"), now: fixedDate)
        state = reduce(state, .applyLines(["| c"], what: "three"), now: fixedDate)
        let storage = InMemoryStorage()
        Persistence.sync(before: MapState(), after: state, storage: storage)
        let branched = try XCTUnwrap(try Persistence.branch(state, atTurn: 1, storage: storage, now: fixedDate))
        XCTAssertEqual(branched.graph.rootNames, ["a"])
        XCTAssertEqual(branched.turns.count, 1)
        XCTAssertEqual(try storage.readLog(), branched.logText)
        XCTAssertEqual(try storage.archivedLogs().count, 1)
        XCTAssertNil(state.branched(atTurn: 9))
        let next = reduce(branched, .applyLines(["| d"], what: "four"), now: fixedDate)
        XCTAssertEqual(next.turns.last?.number, 2)
    }

    func testCoverageAndProof() {
        var state = reduce(MapState(), .submitText("I'm Sam. Ana reviews the paper. Nothing here."), now: fixedDate)
        state = reduce(state, .applyModelOutput("| sam @kind person @src text @s 1\n| ana - reviews | paper @src text @s 2\n| ghost @src world", prompt: .expand, textID: 1, about: "t"), now: fixedDate)
        let coverage = Coverage.compute(state)
        XCTAssertEqual(coverage.unsupportedNodes, ["ghost"])
        XCTAssertEqual(coverage.uncoveredSentences, [SentenceID(text: 1, s: 3)])

        let entries = Proof.entries(for: ["ana", "paper"], in: state)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sentence.s, 2)
        XCTAssertEqual(entries[0].nodes, ["ana", "paper"])
        XCTAssertEqual(Proof.nodes(supportedBy: SentenceID(text: 1, s: 2), in: state.graph), ["ana", "paper"])
        XCTAssertEqual(Proof.nodes(supportedBy: SentenceID(text: 1, s: 1), in: state.graph), ["sam"])
    }

    func testForgetTextRemovesOnlyNodesItAloneSupports() {
        var state = reduce(MapState(), .submitText("Ana reviews the paper."), now: fixedDate)
        state = reduce(state, .submitText("Sam writes the paper."), now: fixedDate)
        state = reduce(state, .applyModelOutput("| ana - reviews | paper @s 1", prompt: .extract, textID: 1, about: "t1"), now: fixedDate)
        state = reduce(state, .applyModelOutput("| sam - writes | paper @s 1", prompt: .extract, textID: 2, about: "t2"), now: fixedDate)
        state = reduce(state, .forgetText(1), now: fixedDate)
        XCTAssertEqual(state.graph.rootNames, ["paper", "sam"])
        XCTAssertEqual(state.turns.last?.lines, ["| ana ="])
        XCTAssertEqual(state.evidence.count, 2, "the evidence store is never touched")
    }

    func testDedupeProposalsAndMerge() throws {
        var state = reduce(MapState(), .applyLines(["| paper - cites | papers", "| the paper", "| ana", "| paper | x"], what: "x"), now: fixedDate)
        let cheap = Dedupe.cheapPass(state.graph)
        XCTAssertEqual(cheap.map { "\($0.old)→\($0.new)" }.sorted(), ["papers→paper", "the paper→paper", "the paper→papers"])
        XCTAssertTrue(cheap.allSatisfy { $0.source == .harness })

        let gated = Gate.run("| the paper = paper\nboth name the manuscript\n| ana = paper\n", graph: state.graph, evidence: state.evidence, options: GateOptions(prompt: .dedupe))
        let model = Dedupe.proposals(fromGated: gated.lines)
        XCTAssertEqual(model, [
            DedupeProposal(old: "the paper", new: "paper", reason: "both name the manuscript", source: .model),
            DedupeProposal(old: "ana", new: "paper", reason: "", source: .model),
        ])

        state = reduce(state, .merge(model[0]), now: fixedDate)
        XCTAssertNil(state.graph.node("the paper"))
        XCTAssertEqual(state.turns.last?.lines, ["| the paper = paper", "both name the manuscript"])
        XCTAssertEqual(state.graph.comments.last?.text, "both name the manuscript")
    }

    func testVerifyProposalsApplyThroughTheGate() {
        var state = reduce(MapState(), .submitText("I'm Sam. Ana reviews the paper."), now: fixedDate)
        let report = VerifyReport.parse("s2\n| ana - reviews | paper @src text @s 2\nmissing: sam")
        for proposal in report.proposals {
            state = reduce(state, .applyModelOutput(proposal.lines.joined(separator: "\n"), prompt: .verify, textID: 1, about: "s\(proposal.sentence)"), now: fixedDate)
        }
        XCTAssertEqual(state.graph.rootNames, ["ana", "paper"])
        XCTAssertEqual(state.graph.edge("ana", "paper")?.notes, ["src text", "text 1 s2"])
    }

    func testOutlineTree() throws {
        let graph = try Compiler.compile("intro note\n| zed\n# people\n| ana - reviews | paper\nana is the second author\n| sam | paper\n## students\n| kim\n# timeline\n| paper @date 2026-11-03")
        let outline = Outline.build(graph)
        XCTAssertEqual(outline.map(\.title), ["", "people", "students", "timeline"])
        XCTAssertEqual(outline.map(\.level), [0, 1, 2, 1])
        XCTAssertEqual(outline[0].nodes, ["zed"])
        XCTAssertEqual(outline[0].comments, ["intro note"])
        XCTAssertEqual(outline[1].nodes, ["ana", "paper", "sam"])
        XCTAssertEqual(outline[1].comments, ["ana is the second author"])
        XCTAssertEqual(outline[2].nodes, ["kim"])
        XCTAssertEqual(outline[3].nodes, [])
        XCTAssertEqual(Outline.comments(attachedTo: "paper", in: graph), [])
        let g2 = try Compiler.compile("| a\nabout a\n| b")
        XCTAssertEqual(Outline.comments(attachedTo: "a", in: g2), ["about a"])
    }
}
