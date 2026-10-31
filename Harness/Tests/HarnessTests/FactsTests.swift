import XCTest
@testable import Harness

/// Reading in passages: `read` writes plain sentences, `facts` writes `a | relation | b`,
/// and the harness turns them into gated, proved notation.
final class FactsTests: XCTestCase {
    func testReadingsKeepTheirSentenceNumbers() {
        let output = """
        s2: Ana reviews the paper.
        - s2: Ana likes the paper.
        The paper is late.
        s9: The model slipped here.
        s3: -
        s4 nothing
        3: Sam writes.
        """
        XCTAssertEqual(Reading.parse(output, passage: [2, 3, 4]), [
            Reading(s: 2, text: "Ana reviews the paper."),
            Reading(s: 2, text: "Ana likes the paper."),
            Reading(s: 2, text: "The paper is late."),
            Reading(s: 2, text: "The model slipped here."),
            Reading(s: 3, text: "Sam writes."),
        ])
        XCTAssertEqual(Reading.parse("No numbers at all.", passage: [5]), [Reading(s: 5, text: "No numbers at all.")])
        XCTAssertEqual(Reading.bySentence([Reading(s: 2, text: "A."), Reading(s: 2, text: "B."), Reading(s: 3, text: "C.")]), [2: "A. B.", 3: "C."])
    }

    func testFactLines() {
        let cases: [(String, Fact?)] = [
            ("s2: Ana (person) | reviews | the Papers (thing)", Fact(s: 2, subject: "ana", subjectKind: "person", relation: "reviews", object: "paper", objectKind: "thing")),
            ("s1: sam (person)", Fact(s: 1, subject: "sam", subjectKind: "person")),
            ("ana | likes | paper", Fact(s: 7, subject: "ana", relation: "likes", object: "paper")),
            ("s3: ana | paper", Fact(s: 3, subject: "ana", object: "paper")),
            ("s3: ana (robot) | is | x@y = z (thing)", Fact(s: 3, subject: "ana", relation: "is", object: "x y z", objectKind: "thing")),
            ("s3: ana - smith | - works at - | acme", Fact(s: 3, subject: "ana smith", relation: "works at", object: "acme")),
            ("3 people | came to | party", Fact(s: 7, subject: "3 people", relation: "came to", object: "party")),
            ("s4: nothing", nil),
            ("not a fact at all", nil),
            ("s1: sam", nil),
            ("s4: | reviews | paper", nil),
            ("a | b | c | d", nil),
        ]
        for (line, fact) in cases { XCTAssertEqual(Facts.parse(line, s: 7), fact, line) }
    }

    func testFactsBecomeNotation() {
        XCTAssertEqual(Facts.notation(Fact(s: 1, subject: "ana", subjectKind: "person", relation: "reviews", object: "paper", objectKind: "thing")),
                       ["| ana @kind person", "| paper @kind thing", "| ana - reviews | paper"])
        XCTAssertEqual(Facts.notation(Fact(s: 1, subject: "ana", object: "paper")), ["| ana | paper"])
        XCTAssertEqual(Facts.notation(Fact(s: 1, subject: "sam")), ["| sam"])
        XCTAssertEqual(Facts.notation(Fact(s: 1, subject: "sam", subjectKind: "person")), ["| sam @kind person"])
        XCTAssertEqual(Facts.notation(Fact(s: 1, subject: "sam", relation: "is", object: "sam")), ["| sam"], "no link to itself")
        for lines in [Facts.notation(Fact(s: 1, subject: "x y z", relation: "works at", object: "acme"))] {
            for line in lines { XCTAssertNoThrow(try Parser(options: .strict).parseLine(line), line) }
        }
    }

    /// “She likes it” names neither Ana nor the paper; read as “Ana likes the paper”, it
    /// proves both, so the fact is `src text` with that sentence's proof.
    func testAFactIsProvedByTheReadingOfItsSentence() async throws {
        let state = reduce(MapState(), .submitText("Ana writes a paper. She likes it."), now: fixedDate)
        let client = FixtureClient(recordings: [.init(kind: .facts, response: "s2: ana (person) | likes | paper (thing)\nnot a fact at all\n")])
        let runner = ModelRunner(client: client, settings: ModelSettings(model: "fixture"), appendAll: true)
        let run = try await runner.run(.facts, state: state, item: "s2: Ana likes the paper.", textID: 1, readings: [2: "Ana likes the paper."])
        XCTAssertEqual(run.gate.lines, [
            "| ana @kind person @src text @text 1 s2",
            "| paper @kind thing @src text @text 1 s2",
            "| ana - likes @src text @text 1 s2 | paper",
        ])
        XCTAssertNil(run.request.grammar, "facts are not notation: no grammar")
        XCTAssertFalse(run.retried)
        XCTAssertTrue(run.gate.events.contains { $0.raw == "not a fact at all" && $0.kind == .dropped })
        // Without the reading, nothing names them in sentence 2: proof comes from sentence 1.
        let unread = try await runner.run(.facts, state: state, item: "s2: Ana likes the paper.", textID: 1)
        XCTAssertTrue(unread.gate.lines.allSatisfy { $0.contains("@text 1 s1") }, "\(unread.gate.lines)")
    }

    func testFactsAddNoRepeats() async throws {
        var state = reduce(MapState(), .submitText("Ana writes a paper."), now: fixedDate)
        let client = FixtureClient(recordings: [.init(kind: .facts, response: "s1: ana (person) | writes | paper\n")])
        let runner = ModelRunner(client: client, settings: ModelSettings(model: "fixture"), appendAll: true)
        let first = try await runner.run(.facts, state: state, item: "s1: Ana writes a paper.", textID: 1)
        XCTAssertEqual(first.gate.lines.count, 3, "ana, the new node paper, the link")
        state = reduce(state, .applyRun(first, about: "text 1"), now: fixedDate)
        let again = try await runner.run(.facts, state: state, item: "s1: Ana writes a paper.", textID: 1)
        XCTAssertEqual(again.gate.lines, [], "reading the sentence again adds nothing")
    }

    func testReadSendsThePassageAndWhatCameBeforeNotTheMap() {
        var state = reduce(MapState(), .submitText("Ana writes a paper. She likes it."), now: fixedDate)
        state = reduce(state, .applyLines(["| ana - writes | paper"], what: "test"), now: fixedDate)
        let runner = ModelRunner(client: FixtureClient(recordings: []), settings: ModelSettings(model: "fixture"))
        let passage = Reading.passage(state.evidence.sentences(text: 1).suffix(1))
        let prompt = runner.prompt(.read, state: state, item: passage, before: "Ana writes a paper.")
        XCTAssertTrue(prompt.hasSuffix("Known names: ana, paper\nBefore:\nAna writes a paper.\nPassage:\ns2: She likes it.\nOutput:"), prompt)
        XCTAssertFalse(prompt.contains("| ana - writes | paper"), "no map")
        let facts = runner.prompt(.facts, state: state, item: "s2: Ana likes the paper.")
        XCTAssertTrue(facts.hasSuffix("Known names: ana, paper\nSentences:\ns2: Ana likes the paper.\nOutput:"), facts)
    }

    func testAWalkReadsInPassagesOfOneText() {
        var walk = SentenceWalk(sentences: (1...6).map { Sentence(text: 1, s: $0, sentence: "S\($0).") } + [Sentence(text: 2, s: 1, sentence: "T.")])
        walk.reads = true
        XCTAssertEqual(walk.passage.map(\.s), [1, 2, 3, 4])
        XCTAssertEqual(walk.label, "Reading sentences 1–4 of 7")
        for _ in 0..<4 { walk.advance() }
        XCTAssertEqual(walk.passage.map(\.s), [5, 6], "a passage never crosses into the next text")
        walk.remember(["A.", "B."], of: 1)
        walk.remember(["C.", "D.", "E.", "F.", "G."], of: 1)
        XCTAssertEqual(walk.context(for: 1), ["B.", "C.", "D.", "E.", "F.", "G."])
        XCTAssertEqual(walk.context(for: 2), [], "a new text starts with nothing before it")
        walk.remember(["H."], of: 2)
        XCTAssertEqual(walk.context(for: 2), ["H."])
        walk.reads = false
        XCTAssertEqual(walk.passage.count, 1, "Check again goes one sentence at a time")
    }

    func testTheDemoReadsItsText() async throws {
        var state = Demo.state(.tiny)
        state = MapState()
        state = reduce(state, .submitText("I'm Sam. I'm writing a paper, Ana reviews it on Nov 3."), now: fixedDate)
        let runner = ModelRunner(client: Demo.client(), settings: ModelSettings(model: "demo"), appendAll: true)
        let passage = state.evidence.sentences(text: 1)
        let read = try await runner.run(.read, state: state, item: Reading.passage(passage), textID: 1)
        let readings = Reading.parse(read.rawOutput, passage: passage.map(\.s))
        XCTAssertEqual(readings.count, 3)
        let facts = try await runner.run(.facts, state: state, item: Reading.render(readings), textID: 1, readings: Reading.bySentence(readings))
        let next = reduce(state, .applyRun(facts, about: "text 1"), now: fixedDate)
        XCTAssertEqual(Set(next.graph.rootNames), ["sam", "paper", "ana", "nov 3"])
        XCTAssertNotNil(next.graph.edge("ana", "paper"))
        XCTAssertTrue(next.graph.nodes.values.allSatisfy { $0.note(kind: "src") == "text" })
    }
}

final class ThinkingTests: XCTestCase {
    func testThinkBlocksNeverReachTheAnswer() {
        var f = ThinkFilter()
        let chunks = ["<thi", "nk>Hmm, she is", " Ana.</th", "ink>\n\ns1: Ana", " likes <b>it</b>.<", "x"]
        let out = chunks.map { f.feed($0) }.joined() + f.flush()
        XCTAssertEqual(out, "\n\ns1: Ana likes <b>it</b>.<x")
        var open = ThinkFilter()
        XCTAssertEqual(open.feed("ok <think>never closed"), "ok ")
        XCTAssertEqual(open.flush(), "")
    }

    func testAThinkingModelStillGivesFacts() async throws {
        let state = reduce(MapState(), .submitText("Ana writes a paper."), now: fixedDate)
        let client = FixtureClient(recordings: [.init(kind: .facts, response: "<think>\nThe | subject is ana.\n</think>\ns1: ana (person) | writes | paper (thing)\n")])
        let run = try await ModelRunner(client: client, settings: ModelSettings(model: "fixture"), appendAll: true)
            .run(.facts, state: state, item: "s1: Ana writes a paper.", textID: 1)
        XCTAssertFalse(run.rawOutput.contains("think"))
        XCTAssertEqual(run.gate.lines.count, 3)
        XCTAssertTrue(run.gate.events.isEmpty || !run.gate.events.contains { $0.raw.contains("subject is") })
    }
}
