import XCTest
@testable import Harness

final class ModelTests: XCTestCase {
    let text = "I'm Sam. I'm writing a paper, Ana reviews it on Nov 3."

    func state() -> MapState {
        reduce(MapState(), .submitText(text), now: fixedDate)
    }

    func runner(_ recordings: [FixtureClient.Recording], model: String = "fixture") -> ModelRunner {
        ModelRunner(client: FixtureClient(recordings: recordings), settings: ModelSettings(model: model))
    }

    func testSameTextThroughTwoModelsGivesTheSameNodeSet() async throws {
        // Two models phrase the same facts differently; the canonicaliser and gate converge.
        let modelA = """
        | sam @kind person @src text @s 1
        | paper @kind thing @src text @s 2
        | sam - writes | paper @src text @s 2
        | ana @kind person @src text @s 2
        | ana - reviews | paper @src text @s 2
        """
        let modelB = """
        | Sam @kind person @s 1
        | The Papers @kind thing @s 2
        | Sam - is writing | the papers @s 2
        | Ana @kind person @s 2
        | Ana - reviews carefully every single page of | The Paper @s 2
        | paper @src world
        """
        var results: [Set<String>] = []
        for (model, response) in [("a", modelA), ("b", modelB)] {
            let r = runner([.init(kind: .extract, model: model, response: response)], model: model)
            let run = try await r.run(.extract, state: state(), item: text, textID: 1)
            let next = reduce(state(), .applyRun(run, about: "text 1"), now: fixedDate)
            results.append(Set(next.graph.rootNames))
            XCTAssertEqual(next.graph.node("paper")?.note(kind: "src"), "text", model)
            XCTAssertNotNil(next.graph.edge("ana", "paper"), model)
            XCTAssertTrue(next.graph.edges.values.allSatisfy { $0.note(kind: "src") != nil }, "\(model): every edge carries provenance")
            XCTAssertTrue(next.graph.nodes.values.allSatisfy { $0.note(kind: "src") != nil }, "\(model): every node carries provenance")
        }
        XCTAssertEqual(results[0], ["sam", "paper", "ana"])
        XCTAssertEqual(results[0], results[1])
    }

    func testStreamingFeedsTheGateLineByLineAndReportsTokens() async throws {
        let r = runner([.init(kind: .extract, response: "| sam @kind person @s 1\n| nonsense -\n", promptTokens: 120, responseTokens: 14)])
        let box = EventBox()
        let run = try await r.run(.extract, state: state(), item: text, textID: 1) { box.append($0) }
        XCTAssertEqual(run.gate.lines, ["| sam @kind person @src text @text 1 s1"])
        XCTAssertEqual(run.promptTokens, 120)
        XCTAssertEqual(run.responseTokens, 14)
        XCTAssertTrue(run.grammarUsed)
        XCTAssertGreaterThan(box.events.filter { if case .chunk = $0 { return true } else { return false } }.count, 3, "text arrives in chunks")
        XCTAssertTrue(box.events.contains(.kept(["| sam @kind person @src text @text 1 s1"])))
        XCTAssertTrue(box.events.contains { if case .heldBack(let e) = $0 { return e.raw == "| nonsense -" } else { return false } })
        XCTAssertEqual(box.events.last, .done)
    }

    func testFailedLinesAreSentBackOnceWithTheError() async throws {
        // The first recording answers the extract; the repair round matches on the error text.
        let r = runner([
            .init(kind: .extract, match: "These lines did not parse", response: "| ana - reviews | paper @s 2\n"),
            .init(kind: .extract, response: "| ana - reviews |\n| sam @kind person @s 1\n"),
        ])
        let run = try await r.run(.extract, state: state(), item: text, textID: 1)
        XCTAssertTrue(run.retried)
        XCTAssertEqual(run.gate.lines, [
            "| sam @kind person @src text @text 1 s1",
            "| ana @src text @text 1 s2",
            "| paper @src text @text 1 s2",
            "| ana - reviews @src text @text 1 s2 | paper",
        ])
        XCTAssertTrue(run.rawOutput.contains("| ana - reviews |\n"), "the raw output keeps the audit trail")
        XCTAssertTrue(run.gate.parseErrors.isEmpty, "after the retry nothing is pending")
    }

    func testGrammarRejectionFallsBackToPostValidation() async throws {
        struct Rejecting: ModelClient {
            func generate(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, Error> {
                AsyncThrowingStream { c in
                    if request.grammar != nil { c.finish(throwing: ModelError.grammarRejected); return }
                    c.yield(ModelChunk(text: "| sam @kind person @s 1\n", done: true))
                    c.finish()
                }
            }
            func models() async throws -> [ModelInfo] { [] }
        }
        let r = ModelRunner(client: Rejecting(), settings: ModelSettings(model: "m"))
        let run = try await r.run(.extract, state: state(), item: text, textID: 1)
        XCTAssertFalse(run.grammarUsed)
        XCTAssertEqual(run.gate.lines.count, 1)
    }

    func testGrammarListsCurrentNamesAndTightenings() {
        let g = Grammar.build(nodes: ["paper", "q&a", "well-known"], allowEdits: false)
        XCTAssertTrue(g.contains("name  ::= \"paper\" | \"q&a\" | \"well-known\" | free"))
        XCTAssertTrue(g.contains("link  ::= seg? term"), "one label per link")
        XCTAssertTrue(g.contains("path  ::= name (link name)* note? note?"), "two notes per path")
        XCTAssertFalse(g.contains("edit"))
        XCTAssertTrue(Grammar.build(nodes: [], allowEdits: true).contains("edit  ::="))
    }

    func testPromptsAreFilledAndEditable() {
        var prompts = PromptSet()
        var s = state()
        s = reduce(s, .applyLines(["| sam @src user"], what: "x"), now: fixedDate)
        let r = ModelRunner(client: FixtureClient(recordings: []), settings: ModelSettings(model: "m"), prompts: prompts)
        let p = r.prompt(.extract, state: s, item: "new text")
        XCTAssertTrue(p.contains("Existing nodes: sam"))
        XCTAssertTrue(p.contains("[text 1]\ns1: I'm Sam.\ns2: I'm writing a paper, Ana reviews it on Nov 3."))
        XCTAssertTrue(p.contains("| sam @src user"))
        XCTAssertTrue(p.hasSuffix("new text\noutput:"))

        prompts.overrides[.extract] = "custom {nodes} {item}"
        XCTAssertEqual(prompts.render(.extract, map: "", context: "", nodes: ["a"], item: "i"), "custom a i")
        XCTAssertFalse(prompts.isDefault(.extract))
        XCTAssertTrue(prompts.isDefault(.chat))

        let contextOnly = r.prompt(.clarify, state: s, item: "", contextOnly: true)
        XCTAssertTrue(contextOnly.contains("Map:\n(empty)"))
    }

    func testClarifyVerifyAndChatOutputsParse() {
        let questions = ClarifyQuestion.parse("s1 [speaker] Who is Speaker 1?\ns3 [Pronoun] Who is \"he\"?\njunk\ns9 no reason given\n")
        XCTAssertEqual(questions, [
            ClarifyQuestion(sentence: 1, reason: "speaker", question: "Who is Speaker 1?"),
            ClarifyQuestion(sentence: 3, reason: "pronoun", question: "Who is \"he\"?"),
            ClarifyQuestion(sentence: 9, reason: "other", question: "no reason given"),
        ])
        XCTAssertEqual(ClarifyQuestion.parse((1...8).map { "s\($0) [other] q\($0)" }.joined(separator: "\n")).count, 5)

        let report = VerifyReport.parse("s4\n| ana - reviews | paper @src text @s 4\n| paper @kind thing\ns6\nmissing: The Dragons\ns7\n| x | y\n")
        XCTAssertEqual(report.proposals.map(\.sentence), [4, 7])
        XCTAssertEqual(report.proposals[0].lines.count, 2)
        XCTAssertEqual(report.missingNodes, ["dragon"])

        let reply = ChatReply.parse("Ana reviews it.\n\n```mm\n| ana - reviews | paper @src world\nnot a line\n```\nThanks.")
        XCTAssertTrue(reply.prose.hasPrefix("Ana reviews it."))
        XCTAssertTrue(reply.prose.hasSuffix("Thanks."))
        XCTAssertFalse(reply.prose.contains("```"))
        XCTAssertEqual(reply.lines, ["| ana - reviews | paper @src world"])
    }

    func testNeighbourhoodAndNodeList() throws {
        let graph = try Compiler.compile("| a - x | b\n| b | c\n| c | d\n| b @kind thing")
        XCTAssertEqual(ModelRunner.neighbourhood(of: "b", in: graph), "| a - x | b\n| b @kind thing\n| b | c\n")
        XCTAssertEqual(ModelRunner.neighbourhood(of: "zzz", in: graph), "| zzz")
        XCTAssertEqual(ModelRunner.nodeList(graph), "a (no notes; degree 1)\nb (kind thing; degree 2)\nc (no notes; degree 2)\nd (no notes; degree 1)")
    }

    func testModelFit() {
        let gb: Int64 = 1024 * 1024 * 1024
        let models = [ModelInfo(name: "small", sizeBytes: 2 * gb), ModelInfo(name: "big", sizeBytes: 20 * gb), ModelInfo(name: "huge", sizeBytes: 60 * gb)]
        XCTAssertEqual(ModelInfo.defaultModel(from: models, memory: 64 * gb)?.name, "big")
        XCTAssertEqual(ModelInfo.defaultModel(from: models, memory: 8 * gb)?.name, nil)
        XCTAssertEqual(ModelInfo.defaultModel(from: models, memory: 16 * gb)?.name, "small")
    }

    func testLineAccumulator() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.feed("| a |"), [])
        XCTAssertEqual(acc.feed(" b\n| c\n| d"), ["| a | b", "| c"])
        XCTAssertEqual(acc.flush(), ["| d"])
        XCTAssertEqual(acc.flush(), [])
    }

    func testNoModelConfiguredIsAnError() async {
        let r = ModelRunner(client: FixtureClient(recordings: []), settings: ModelSettings())
        do {
            _ = try await r.run(.extract, state: state(), item: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ModelError, .noModel)
        }
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RunEvent] = []
    var events: [RunEvent] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ e: RunEvent) { lock.lock(); storage.append(e); lock.unlock() }
}
