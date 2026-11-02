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
}
