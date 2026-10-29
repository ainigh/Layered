import XCTest
@testable import Harness

/// Table-driven: model line in, kept / rewritten / dropped out, with reason.
final class GateTests: XCTestCase {
    struct Case {
        var name: String
        var prompt: PromptKind = .extract
        var input: String
        var lines: [String]
        var dropped: [String] = []     // reason fragments, one per dropped line
        var rewritten: [String] = []   // reason fragments, one per rewritten line
        var deferred: Int = 0
    }

    var graph: Graph!
    var evidence: EvidenceStore!

    override func setUpWithError() throws {
        graph = try Compiler.compile("""
        | sam @src text @text 1 s1 @kind person
        | paper @src text @text 1 s2 @kind thing
        | sam - writes @src text @text 1 s2 | paper
        | the paper @src user
        | budget @src user
        """)
        evidence = EvidenceStore()
        evidence.appendText("I'm Sam. I'm writing a paper, Ana reviews it on Nov 3. The deadline worries me.")
    }

    func run(_ c: Case, textID: Int? = 1, budget: Int?? = nil) -> GateResult {
        Gate.run(c.input, graph: graph, evidence: evidence, options: GateOptions(prompt: c.prompt, textID: textID, budget: budget))
    }

    func check(_ c: Case, file: StaticString = #filePath, line: UInt = #line) {
        let result = run(c)
        XCTAssertEqual(result.lines, c.lines, c.name, file: file, line: line)
        let dropped = result.events.filter { $0.kind == .dropped }
        XCTAssertEqual(dropped.count, c.dropped.count, "\(c.name): dropped \(dropped.map(\.reason))", file: file, line: line)
        for (event, fragment) in zip(dropped, c.dropped) {
            XCTAssertTrue(event.reason.contains(fragment), "\(c.name): \(event.reason)", file: file, line: line)
        }
        let rewritten = result.events.filter { $0.kind == .rewritten }
        XCTAssertEqual(rewritten.count, c.rewritten.count, "\(c.name): rewritten \(rewritten.map(\.reason))", file: file, line: line)
        for (event, fragment) in zip(rewritten, c.rewritten) {
            XCTAssertTrue(event.reason.contains(fragment), "\(c.name): \(event.reason)", file: file, line: line)
        }
        XCTAssertEqual(result.deferred.count, c.deferred, c.name, file: file, line: line)
    }

    func testExtract() {
        let cases: [Case] = [
            Case(name: "proof attached, provenance added, new node declared",
                 input: "| ana - reviews | paper @s 2",
                 lines: ["| ana @src text @text 1 s2", "| ana - reviews @src text @text 1 s2 | paper"],
                 rewritten: ["added `@src text`; declared new node `ana`"]),
            Case(name: "cited sentence lacks a name: search finds the right one",
                 input: "| ana - reviews | paper @s 1",
                 lines: ["| ana @src text @text 1 s2", "| ana - reviews @src text @text 1 s2 | paper"],
                 rewritten: ["sentence 1 does not name `ana`; using text 1 s2"]),
            Case(name: "no sentence names the new node: downgraded to guess",
                 input: "| sam - fears | dragon @s 3",
                 lines: ["| dragon @src guess", "| sam - fears @src guess | dragon"],
                 rewritten: ["no sentence names `dragon`; downgraded to `guess`"]),
            Case(name: "an edge between existing nodes needs one of them in the sentence",
                 input: "| budget - limits | the paper @s 3",
                 lines: ["| budget - limits @src guess | the paper"],
                 rewritten: ["no sentence names `budget` and `the paper`; downgraded"]),
            Case(name: "a new node named in the cited sentence is proof enough",
                 input: "| sam - fears | deadline @s 3",
                 lines: ["| deadline @src text @text 1 s3", "| sam - fears @src text @text 1 s3 | deadline"],
                 rewritten: ["declared new node `deadline`"]),
            Case(name: "no @s at all: proof is searched for",
                 input: "| ana - reviews | paper",
                 lines: ["| ana @src text @text 1 s2", "| ana - reviews @src text @text 1 s2 | paper"],
                 rewritten: ["found proof in text 1 s2"]),
            Case(name: "names are canonicalised and near matches rewritten",
                 input: "| The Papers | Review @s 2",
                 lines: ["| review @src text @text 1 s2", "| paper - | review".replacingOccurrences(of: "- | review", with: "@src text @text 1 s2 | review")],
                 rewritten: ["normalised `The Papers` to `paper`"]),
            Case(name: "single node line carries its own provenance",
                 input: "| deadline @kind event @s 3",
                 lines: ["| deadline @kind event @src text @text 1 s3"],
                 rewritten: ["added `@src text`"]),
            Case(name: "Extract may not write other provenance",
                 input: "| paper @src world",
                 lines: [],
                 dropped: ["Extract may only write `@src text`"]),
            Case(name: "parse error is dropped with the message",
                 input: "| ana -",
                 lines: [],
                 dropped: ["needs a label"]),
            Case(name: "scope lines are not the model's",
                 input: "| @ talk",
                 lines: [],
                 dropped: ["scopes are not used"]),
            Case(name: "qualified names are rejected",
                 input: "| sam | paper@talk",
                 lines: [],
                 dropped: ["names are global"]),
            Case(name: "duplicate edge is dropped",
                 input: "| sam - writes | paper @s 2",
                 lines: [],
                 dropped: ["already in the map"]),
            Case(name: "model deletes are dropped",
                 input: "| paper =",
                 lines: [],
                 dropped: ["deleting is a user action"]),
            Case(name: "merge of two existing nodes is kept",
                 input: "| the paper = paper",
                 lines: ["| the paper = paper"]),
            Case(name: "merge onto a variant of itself is dropped",
                 input: "| papers = paper",
                 lines: [],
                 dropped: ["already the same node"]),
            Case(name: "non-statements are dropped, fences ignored",
                 input: "```mm\nhere is the map\n| ana - reviews | paper @s 2\n```",
                 lines: ["| ana @src text @text 1 s2", "| ana - reviews @src text @text 1 s2 | paper"],
                 dropped: ["not a statement"],
                 rewritten: ["added"]),
            Case(name: "long labels are trimmed",
                 input: "| ana - carefully reviews every single page of | paper @s 2",
                 lines: ["| ana @src text @text 1 s2", "| ana - carefully reviews every single @src text @text 1 s2 | paper"],
                 rewritten: ["trimmed to 4 words"]),
            Case(name: "dash-pipe variant is normalised",
                 input: "| ana -| paper @s 2",
                 lines: ["| ana @src text @text 1 s2", "| ana @src text @text 1 s2 - | paper"],
                 rewritten: ["added"]),
            Case(name: "a second new node in the same batch resolves to the first",
                 input: "| ana - reviews | paper @s 2\n| Anas | deadline @s 3",
                 lines: ["| ana @src text @text 1 s2", "| ana - reviews @src text @text 1 s2 | paper", "| deadline @src text @text 1 s3", "| ana @src text @text 1 s3 | deadline"],
                 rewritten: ["added", "normalised `Anas` to `ana`"]),
        ]
        for c in cases { check(c) }
    }

    func testExpandAndChat() {
        let cases: [Case] = [
            Case(name: "world provenance passes through",
                 prompt: .expand,
                 input: "| paper - published in | journal @src world",
                 lines: ["| journal @src world", "| paper - published in @src world | journal"],
                 rewritten: ["declared new node `journal`; moved `@src` onto the edge"]),
            Case(name: "unknown provenance becomes guess",
                 prompt: .expand,
                 input: "| paper @src banana",
                 lines: ["| paper @src guess"],
                 rewritten: ["unknown provenance `banana` becomes `guess`"]),
            Case(name: "missing provenance becomes guess",
                 prompt: .chat,
                 input: "| paper - cites | prior work",
                 lines: ["| prior work @src guess", "| paper - cites @src guess | prior work"],
                 rewritten: ["missing `@src` becomes `guess`"]),
            Case(name: "the model cannot claim user provenance",
                 prompt: .expand,
                 input: "| paper @src user",
                 lines: ["| paper @src guess"],
                 rewritten: ["unknown provenance `user`"]),
            Case(name: "text lines still need proof",
                 prompt: .expand,
                 input: "| ana - reviews | paper @src text",
                 lines: ["| ana @src text @text 1 s2", "| ana - reviews @src text @text 1 s2 | paper"],
                 rewritten: ["found proof"]),
            Case(name: "advice is allowed in expand",
                 prompt: .expand,
                 input: "| sam - should ask | ana @src advice",
                 lines: ["| ana @src advice", "| sam - should ask @src advice | ana"],
                 rewritten: ["declared new node `ana`"]),
            Case(name: "an edge note the model placed on the node moves to the edge",
                 prompt: .expand,
                 input: "| dog - chases | cat @src guess",
                 lines: ["| dog @src guess", "| cat @src guess", "| dog - chases @src guess | cat"],
                 rewritten: ["moved `@src` onto the edge"]),
        ]
        for c in cases { check(c) }
    }

    func testBudgetDefersExtraLines() {
        let input = (1...10).map { "| paper - topic \($0) | t\($0) @src world" }.joined(separator: "\n")
        let result = run(Case(name: "budget", prompt: .expand, input: input, lines: []))
        XCTAssertEqual(result.lines.count, 16, "8 lines, each with its new node declaration")
        XCTAssertEqual(result.deferred.count, 2)
        XCTAssertEqual(result.events.filter { $0.kind == .deferred }.count, 2)
        XCTAssertTrue(result.events.last!.reason.contains("budget of 8"))

        let unlimited = run(Case(name: "unlimited", prompt: .expand, input: input, lines: []), budget: .some(nil))
        XCTAssertEqual(unlimited.deferred.count, 0)
    }

    func testDedupe() {
        check(Case(name: "dedupe keeps edits and their reason comments",
                   prompt: .dedupe,
                   input: "| the paper = paper\nboth name the same manuscript\n| sam | paper",
                   lines: ["| the paper = paper", "both name the same manuscript"],
                   dropped: ["Dedupe may only propose"]))
    }

    func testAliasesSupportProof() {
        var options = GateOptions(prompt: .extract, textID: 1)
        options.aliases = ["samuel": ["sam"]]
        let result = Gate.run("| samuel - writes | paper @s 2", graph: graph, evidence: evidence, options: options)
        XCTAssertEqual(result.lines, ["| samuel @src text @text 1 s1", "| samuel - writes @src text @text 1 s1 | paper"])
    }

    func testParseErrorsAreExposedForOneRetry() {
        let result = run(Case(name: "retry", input: "| ana -\n| ana | paper @s 2", lines: []))
        XCTAssertEqual(result.parseErrors.count, 1)
        XCTAssertEqual(result.parseErrors[0].line, "| ana -")
        XCTAssertTrue(result.parseErrors[0].error.hasPrefix("line 1:"))
    }

    func testNothingIsSilentlyAltered() {
        // Every kept line that differs from its input has an event; every input line
        // appears in lines (verbatim) or in events.
        let input = "| ana - reviews | paper @s 2\n| sam - writes | paper @s 2\n| paper @src world\n| nonsense -"
        let result = run(Case(name: "audit", input: input, lines: []))
        for raw in input.split(separator: "\n").map(String.init) {
            let accounted = result.lines.contains(raw) || result.events.contains { $0.raw == raw }
            XCTAssertTrue(accounted, raw)
        }
    }
}
