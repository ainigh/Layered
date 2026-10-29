import XCTest
@testable import Harness

final class ParserTests: XCTestCase {
    func testAcceptsEverythingTheGrammarProduces() throws {
        // One case per production of the GBNF in notation §8.
        let cases: [(String, Line)] = [
            ("| @ talk", .scope(.enter("talk"))),
            ("| @ a =", .scope(.delete("a"))),
            ("| @ a = @ b", .scope(.merge(from: "a", into: "b"))),
            ("| a", .statement(.path(Path(names: [Name("a")])))),
            ("| a | b", .statement(.path(Path(names: [Name("a"), Name("b")], links: [Link()])))),
            ("| a - | b", .statement(.path(Path(names: [Name("a"), Name("b")], links: [Link(directed: false)])))),
            ("| a - x | b", .statement(.path(Path(names: [Name("a"), Name("b")], links: [Link(labels: ["x"])])))),
            ("| a - x - y @n 1 - | b", .statement(.path(Path(names: [Name("a"), Name("b")], links: [Link(labels: ["x", "y"], notes: ["n 1"], directed: false)])))),
            ("| a @k v @k2 v2", .statement(.path(Path(names: [Name("a")], notes: ["k v", "k2 v2"])))),
            ("| a | b | c @z", .statement(.path(Path(names: [Name("a"), Name("b"), Name("c")], links: [Link(), Link()], notes: ["z"])))),
            ("| old = new", .statement(.edit(Edit(old: Name("old"), new: Name("new"))))),
            ("| old =", .statement(.edit(Edit(old: Name("old"), new: nil)))),
            ("| a@s = b@", .statement(.edit(Edit(old: Name("a", scope: "s"), new: Name("b", scope: ""))))),
            ("| well-known | q&a", .statement(.path(Path(names: [Name("well-known"), Name("q&a")], links: [Link()])))),
            ("| a=b | 2026-11-03", .statement(.path(Path(names: [Name("a=b"), Name("2026-11-03")], links: [Link()])))),
            ("|a|b", .statement(.path(Path(names: [Name("a|b")])))),
            ("  plain   comment  ", .comment("plain comment")),
            ("| a   -   x    |   b", .statement(.path(Path(names: [Name("a"), Name("b")], links: [Link(labels: ["x"])])))),
        ]
        let parser = Parser()
        for (input, expected) in cases {
            XCTAssertEqual(try parser.parseLine(input), expected, input)
        }
    }

    func testRejectsDocumentedErrorsWithLineAndMessage() {
        let cases: [(String, String)] = [
            ("|", "needs a name"),
            ("| a |", "`|` needs a name after it"),
            ("| a - | ", "needs a name"),
            ("| a -", "needs a label"),
            ("| a - x", "needs a target"),
            ("| a @", "needs note text"),
            ("| a - @n | b", "needs a label"),
            ("| @", "needs a scope name"),
            ("| @ a = b", "renamed onto another scope"),
            ("| @ a = @", "needs a scope name"),
            ("| a = b | c", "nothing may follow an edit"),
            ("| a | b = c", "must come right after the name"),
        ]
        let parser = Parser()
        for (input, fragment) in cases {
            XCTAssertThrowsError(try parser.parseLine(input, number: 7), input) { error in
                let e = error as? NotationError
                XCTAssertEqual(e?.line, 7)
                XCTAssertTrue(e?.message.contains(fragment) == true, "\(input): \(e?.message ?? "")")
            }
        }
    }

    func testStrictModeRejectsScopes() {
        let parser = Parser(options: .strict)
        XCTAssertThrowsError(try parser.parseLine("| @ talk"))
        XCTAssertThrowsError(try parser.parseLine("| a | b@talk"))
        XCTAssertNoThrow(try parser.parseLine("| a | b"))
    }

    func testWholeLogKeepsLineNumbers() throws {
        let lines = try Parser().parse("a\n\n| b\n\n\n| c")
        XCTAssertEqual(lines.map(\.number), [1, 3, 6])
        XCTAssertThrowsError(try Parser().parse("| a\n\n| b -")) { error in
            XCTAssertEqual((error as? NotationError)?.line, 3)
        }
    }

    func testRenderRoundTrip() throws {
        for input in ["| a - x - y @n 1 - | b", "| a | b | c @z", "| old = new", "| old =", "| a@s = b@"] {
            guard case .statement(let s) = try Parser().parseLine(input) else { return XCTFail(input) }
            XCTAssertEqual(Render.statement(s), input)
        }
    }
}
