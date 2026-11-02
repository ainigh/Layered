import XCTest
@testable import Harness

/// Bugs found reading the harness: each case failed before its fix.
final class AuditTests: XCTestCase {
    func testUndoAfterReloadKeepsWhatCameBeforeTheFirstTurn() throws {
        var hand = try MapState(log: "| a | b\n")
        hand = reduce(hand, .confirm("a"), now: fixedDate)
        var opt = reduce(MapState(), .applyLines(["| a | b"], what: "typed"), now: fixedDate)
        opt = reduce(opt, .applyLines(["| c"], what: "typed"), now: fixedDate).optimized()
        opt = reduce(opt, .confirm("a"), now: fixedDate)
        for (name, state) in [("hand-written", hand), ("optimized", opt)] {
            let undone = reduce(try MapState(log: state.logText, evidence: state.evidence), .undo, now: fixedDate)
            XCTAssertNotNil(undone.graph.node("b"), name)
            XCTAssertNil(undone.graph.node("a")?.note(kind: "src"), name)
        }
    }

    func testTurnHeadersAreWrittenOnlyByTheApp() throws {
        var s = reduce(MapState(), .applyLines(["| a", "| b"], what: "typed"), now: fixedDate)
        s = reduce(s, .applyLines(["@turn 1 2026-10-28T14:02:33Z user typed", "| c"], what: "import"), now: fixedDate)
        XCTAssertNotNil(s.graph.node("c"))
        let reloaded = try MapState(log: s.logText)
        XCTAssertEqual(reloaded.turns.map(\.number), [1, 2])
        XCTAssertNotNil(reduce(reloaded, .undo, now: fixedDate).graph.node("a"))
    }

    func testPositionsAreFiniteAndOnTheMap() {
        for v in ["nan,0", "0,nan", "inf,0", "-inf,5", "1e300,0"] { XCTAssertNil(Position(noteValue: v), v) }
        XCTAssertEqual(Position(noteValue: "120,-340"), Position(x: 120, y: -340))
        var s = reduce(MapState(), .applyLines(["| a"], what: "t"), now: fixedDate)
        s = reduce(s, .pin("a", x: .nan, y: 3), now: fixedDate)
        XCTAssertNil(s.graph.node("a")?.note(kind: "pos"))
    }

    func testACommentNeverBecomesAStatementOrHeading() throws {
        for (text, expected) in [("| | x", ["x"]), ("#1 priority", ["1 priority"]), ("plain", ["plain"])] {
            var s = reduce(MapState(), .applyLines(["| a"], what: "t"), now: fixedDate)
            s = reduce(s, .comment(on: "a", text), now: fixedDate)
            XCTAssertEqual(s.graph.nodes.count, 1, text)
            XCTAssertEqual(Outline.comments(attachedTo: "a", in: s.graph), expected, text)
        }
    }

    func testReducerErrorsNameTheLineNotLineOne() {
        let s = reduce(MapState(), .applyLines(["| a", "| b | c = d"], what: "t"), now: fixedDate)
        XCTAssertEqual(s.errors.count, 1)
        XCTAssertFalse(s.errors[0].hasPrefix("line 1"), s.errors[0])
        XCTAssertTrue(s.errors[0].hasSuffix(": | b | c = d"), s.errors[0])
    }

    func testWindowsLineEndingsSplitLikeUnixOnes() throws {
        for (src, count) in [("| a | b\r\n| c | d\r\n", 2), ("| a | b\n| c | d\n", 2), ("| a\r\n\r\n| b", 2)] {
            XCTAssertEqual(try Parser().parse(src).count, count, src.debugDescription)
        }
        XCTAssertNil(try Compiler.compile("| a | b\r\n| c | d").edge("b", "c"))
        XCTAssertEqual(try EvidenceStore(jsonl: #"{"s":1,"sentence":"a","text":1}"# + "\r\n" + #"{"s":2,"sentence":"b","text":1}"# + "\r\n").sentences.count, 2)
        var lines = LineAccumulator()
        XCTAssertEqual(lines.feed("| a\r"), [])
        XCTAssertEqual(lines.feed("\n| b\r\n| c"), ["| a", "| b"])
        XCTAssertEqual(lines.flush(), ["| c"])
    }

    func testMarkdownListsEachLinkOnceTheWayItPoints() throws {
        for (src, md) in [("| zeta - | alpha", "- alpha\n  - — zeta\n- zeta\n"),
                          ("| x - | y\n| y | x", "- x\n- y\n  - → x\n"),
                          ("| p | q\n| q | p", "- p\n  - ⇄ q\n- q\n"),
                          ("| a\nabout a\n| b", "- a\n  - _about a_\n- b\n")] {
            XCTAssertEqual(Export.markdown(try Compiler.compile(src)), md, src)
        }
    }

    func testTheDedupeGrammarKeepsStatementsStrict() {
        let g = Grammar.build(nodes: ["dog"], allowEdits: true, allowComments: true)
        XCTAssertTrue(g.contains(#"line  ::= ("| " (path | edit) "\n") | (comment "\n")"#), g)
    }

    func testSingularsOfCommonWords() {
        let cases = [("movies", "movie"), ("cookies", "cookie"), ("series", "series"), ("species", "species"), ("sizes", "size"),
                     ("prizes", "prize"), ("caches", "cache"), ("news", "news"), ("buzzes", "buzz"), ("churches", "church"),
                     ("cities", "city"), ("boxes", "box"), ("dogs", "dog"), ("bus", "bus")]
        for (plural, singular) in cases { XCTAssertEqual(Canonicaliser.singular(plural), singular, plural) }
    }

    func testPromptsFillTheirPlaceholdersOnce() {
        let set = PromptSet(overrides: [.chat: "C:{context}|I:{item}|M:{map}"])
        XCTAssertEqual(set.render(.chat, map: "", context: "use {item} here", nodes: [], item: "X {map}"), "C:use {item} here|I:X {map}|M:(empty)")
    }

    func testANameHeldBackOverBudgetIsStillNewToLaterLines() {
        let r = Gate.run("| a @src world\n| b @src world\n| a - x | b @src world", graph: Graph(), evidence: EvidenceStore(),
                         options: GateOptions(prompt: .chat, budget: 1))
        XCTAssertEqual(r.lines, ["| a @src world"])
        XCTAssertEqual(r.deferred.count, 2)
        // The link's deferred lines still declare `b`, which is not on the map.
        XCTAssertTrue(r.deferred.last?.contains("| b @src world") == true, "\(r.deferred)")
    }

    func testALargeMapRendersInLinearTime() {
        var g = Graph()
        for i in 0...4000 { g.nodes[n("n\(i)")] = Node(id: n("n\(i)")) }
        for i in 0..<4000 { g.addEdge(from: n("n\(i)"), to: n("n\(i + 1)"), directed: true) }
        let start = Date()
        let text = Canonical.render(g)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(try Compiler.compile(text).edges.count, 4000)
    }

    func testASpeakerAnswerKeepsItsQuestionOutOfTheName() {
        XCTAssertEqual(SpeakerMap.parse("Speaker 1 is Ana (s1: Who is Speaker 1?)")?.1, "ana")
        XCTAssertEqual(SpeakerMap.parse("Speaker 2 is Ana.")?.1, "ana")
    }

    func testDuplicatesAmongManyNamesAreQuick() {
        // Varied names, as a map has: letters drawn from a fixed sequence, 4 to 15 long.
        var seed: UInt64 = 7
        func letter() -> Character {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Character(Unicode.Scalar(UInt8(97 + (seed >> 33) % 26)))
        }
        let names = (0..<1500).map { i in String((0..<(4 + i % 12)).map { _ in letter() }) }
        let start = Date()
        _ = Canonicaliser.likelyDuplicates(in: names)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // The banded check agrees with the full edit distance.
        let words = ["kitten", "sitting", "mitten", "kitchen", "paper", "papers", "pager", "", "ab", "ba", "abc"]
        for a in words {
            for b in words {
                XCTAssertEqual(Canonicaliser.within(Array(a.unicodeScalars), Array(b.unicodeScalars), 2), Canonicaliser.editDistance(a, b) <= 2, "\(a) \(b)")
            }
        }
        XCTAssertEqual(Canonicaliser.likelyDuplicates(in: ["papers", "paper", "dragon"]).map(\.2), ["same normal form"])
    }

    func testCanonicalFormKeepsEachNodeUnderItsHeading() throws {
        for src in ["# A\n| x\n# B\n| y\n| x | y", "# A\n| x\n# B\n| y\n| y | x", "| x\n# B\n| y\n| x - | y", "# A\n| x | y\n# B\n| z\n| y | z"] {
            let g = try Compiler.compile(src)
            let again = try Compiler.compile(Canonical.render(g))
            XCTAssertEqual(again.nodes.mapValues(\.heading), g.nodes.mapValues(\.heading), src)
            XCTAssertEqual(Set(again.edges.keys), Set(g.edges.keys), src)
        }
    }
}
