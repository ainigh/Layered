import XCTest
@testable import Harness

/// Editing the map as text: what the drawer appends, and what it refuses.
final class NotationEditTests: XCTestCase {
    func base() throws -> MapState {
        reduce(MapState(), .applyLines(["| sam @kind person", "| sam - writes | paper", "| ana - reviews | paper"], what: "start"), now: fixedDate)
    }

    func edited(_ state: MapState, _ transform: (String) -> String) throws -> (MapState, [String]) {
        let target = try NotationEdit.compile(transform(state.canonical)).get()
        let lines = NotationEdit.lines(from: state.graph, to: target)
        return (reduce(state, .applyLines(lines, what: "edit notation"), now: fixedDate), lines)
    }

    func testEditsBecomeAppendedLines() throws {
        let state = try base()
        // (what the user does to the text, what the map should then say)
        let cases: [(String, (String) -> String, (Graph) -> Bool)] = [
            ("add a line", { $0 + "| kim - chairs | workshop\n" }, { $0.edge("kim", "workshop") != nil }),
            ("rename everywhere", { $0.replacingOccurrences(of: "ana", with: "anna") }, { $0.node("ana") == nil && $0.edge("anna", "paper") != nil }),
            ("remove a link", { $0.components(separatedBy: "\n").filter { !$0.contains("reviews") }.joined(separator: "\n") }, { $0.edge("ana", "paper") == nil && $0.node("paper") != nil }),
            ("change a note", { $0.replacingOccurrences(of: "@kind person", with: "@kind idea") }, { $0.node("sam")?.note(kind: "kind") == "idea" }),
        ]
        for (name, transform, check) in cases {
            let (next, lines) = try edited(state, transform)
            XCTAssertFalse(lines.isEmpty, name)
            XCTAssertTrue(check(next.graph), name)
            XCTAssertEqual(Array(next.log.prefix(state.log.count)), state.log, "\(name): the log only grows")
            XCTAssertEqual(next.canonical, try NotationEdit.compile(transform(state.canonical)).get().canonicalText, "\(name): the map says what the text says")
        }
    }

    func testUnchangedTextAppendsNothing() throws {
        let state = try base()
        XCTAssertEqual(try edited(state, { $0 }).1, [])
        XCTAssertEqual(try edited(state, { $0 + "\n\n" }).1, [], "blank lines are not a change")
    }

    func testTextThatDoesNotCompileSaysWhere() throws {
        let state = try base()
        guard case .failure(let error) = NotationEdit.compile(state.canonical + "| broken - | \n") else { return XCTFail("should not compile") }
        XCTAssertEqual(error.line, state.canonical.split(separator: "\n").count + 1)
        XCTAssertFalse(error.message.isEmpty)
    }

    func testAnEditKeepsWhatTheMapGainedMeanwhile() throws {
        let state = try base()
        let text = state.canonical.replacingOccurrences(of: "ana", with: "anna")
        // The model adds a node while the user is typing.
        let meanwhile = reduce(state, .applyLines(["| deadline @src world"], what: "model"), now: fixedDate)
        let lines = NotationEdit.lines(from: state.graph, to: try NotationEdit.compile(text).get())
        let next = reduce(meanwhile, .applyLines(lines, what: "edit notation"), now: fixedDate)
        XCTAssertNotNil(next.graph.node("anna"))
        XCTAssertNil(next.graph.node("ana"))
        XCTAssertNotNil(next.graph.node("deadline"), "the model's node stays")
    }
}

extension Graph {
    var canonicalText: String { Canonical.render(self) }
}
