import XCTest
@testable import Harness

final class StorageTests: XCTestCase {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layered-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFolderRoundTripIsAppendOnly() throws {
        let root = try temp()
        let storage = try FolderStorage(root: root)
        var state = MapState()
        state = reduce(state, .submitText("I'm Sam. I'm writing a paper."), now: fixedDate)
        var previous = MapState()
        Persistence.sync(before: previous, after: state, storage: storage)
        previous = state
        state = reduce(state, .applyLines(["| sam @src user", "| sam - writes @src user | paper"], what: "typed"), now: fixedDate)
        XCTAssertEqual(Persistence.sync(before: previous, after: state, storage: storage), [])
        previous = state
        state = reduce(state, .rename("paper", to: "thesis"), now: fixedDate)
        Persistence.sync(before: previous, after: state, storage: storage)

        let log = try String(contentsOf: root.appendingPathComponent("map.mm"), encoding: .utf8)
        XCTAssertEqual(log, state.logText)
        XCTAssertEqual(try storage.readText(id: 1), "I'm Sam. I'm writing a paper.")
        XCTAssertEqual(try storage.snapshotTurns(), [1, 2])
        XCTAssertEqual(try storage.readSnapshot(turn: 2), state.canonical)

        let loaded = try Persistence.load(storage)
        XCTAssertEqual(loaded.state.log, state.log)
        XCTAssertEqual(loaded.state.graph.nodes, state.graph.nodes)
        XCTAssertEqual(loaded.state.evidence, state.evidence)
        XCTAssertEqual(loaded.state.texts, state.texts)
        XCTAssertEqual(loaded.state.turns.map(\.lines), state.turns.map(\.lines))

        // Appending again never touches earlier bytes.
        let before = try Data(contentsOf: root.appendingPathComponent("map.mm"))
        try storage.appendLog(["| extra"])
        let after = try Data(contentsOf: root.appendingPathComponent("map.mm"))
        XCTAssertEqual(after.prefix(before.count), before)
        try storage.appendEvidence([Sentence(text: 9, s: 1, sentence: "later")])
        XCTAssertEqual(try EvidenceStore(jsonl: try storage.readEvidence()).count, 3)
        try storage.writeText(id: 1, "overwrite attempt")
        XCTAssertEqual(try storage.readText(id: 1), "I'm Sam. I'm writing a paper.", "texts are written once")
    }

    func testOptimizeArchivesFirst() throws {
        let storage = try FolderStorage(root: try temp())
        try storage.appendLog(["| a | b", "| a = c"])
        let name = try storage.optimize(newLog: "| c | b\n", archiveName: "map-2026-10-28.mm")
        XCTAssertEqual(name, "map-2026-10-28.mm")
        XCTAssertEqual(try storage.readLog(), "| c | b\n")
        XCTAssertEqual(try storage.archivedLogs(), ["map-2026-10-28.mm"])
        let second = try storage.optimize(newLog: "| c | b\n", archiveName: "map-2026-10-28.mm")
        XCTAssertEqual(second, "map-2026-10-28-2.mm", "an archive is never overwritten")
    }

    func testPromptsSettingsAndUIState() throws {
        let storage = try FolderStorage(root: try temp())
        XCTAssertNil(try storage.readPrompt(.extract))
        try storage.writePrompt(.extract, "custom")
        XCTAssertEqual(try Persistence.load(storage).prompts.overrides, [.extract: "custom"])
        try storage.writePrompt(.extract, nil)
        XCTAssertNil(try storage.readPrompt(.extract))

        var settings = Settings()
        settings.model.model = "qwen"
        settings.optimizeEveryTurns = 50
        try storage.writeSettings(settings)
        XCTAssertEqual(try storage.readSettings(), settings)

        var ui = UIState()
        ui.zoom = 1.5
        ui.panels["proof"] = PanelPlacement()
        try storage.writeUIState(ui)
        XCTAssertEqual(try storage.readUIState(), ui)
    }

    func testInMemoryStorageBehavesLikeTheFolder() throws {
        let storage = InMemoryStorage()
        try storage.appendLog(["| a"])
        try storage.appendLog(["| b"])
        XCTAssertEqual(try storage.readLog(), "| a\n| b\n")
        _ = try storage.optimize(newLog: "| a\n| b\n", archiveName: "x.mm")
        XCTAssertEqual(storage.archivedLog(named: "x.mm"), "| a\n| b\n")
        XCTAssertEqual(try Persistence.load(storage).state.graph.nodes.count, 2)
    }

    func testWriteFailureIsReportedNotLost() throws {
        struct Broken: MapStorage {
            func readLog() throws -> String { "" }
            func appendLog(_ lines: [String]) throws { throw CocoaError(.fileWriteNoPermission) }
            func readContext() throws -> String { "" }
            func appendContext(_ text: String) throws {}
            func readEvidence() throws -> String { "" }
            func appendEvidence(_ sentences: [Sentence]) throws {}
            func writeText(id: Int, _ text: String) throws {}
            func readText(id: Int) throws -> String? { nil }
            func readPrompt(_ kind: PromptKind) throws -> String? { nil }
            func writePrompt(_ kind: PromptKind, _ text: String?) throws {}
            func readSettings() throws -> Settings? { nil }
            func writeSettings(_ settings: Settings) throws {}
            func readUIState() throws -> UIState? { nil }
            func writeUIState(_ state: UIState) throws {}
            func writeSnapshot(turn: Int, _ canonical: String) throws {}
            func readSnapshot(turn: Int) throws -> String? { nil }
            func snapshotTurns() throws -> [Int] { [] }
            func optimize(newLog: String, archiveName: String) throws -> String { "" }
            func archivedLogs() throws -> [String] { [] }
            func storeAudio(id: Int, from url: URL) throws -> URL { url }
            func writeTranscript(id: Int, _ json: Data) throws {}
            func readTranscript(id: Int) throws -> Data? { nil }
            func appendErrorLog(_ line: String) throws {}
            func readIconManifest() throws -> Data? { nil }
        }
        let after = reduce(MapState(), .applyLines(["| a"], what: "x"), now: fixedDate)
        XCTAssertEqual(Persistence.sync(before: MapState(), after: after, storage: Broken()), after.log)
        XCTAssertEqual(after.log.count, 2, "the turn stays in memory")
    }

    func testContextDocumentRoundTrip() {
        var doc = ContextDocument()
        doc.append(ContextParagraph(kind: .pasted, textID: 1, date: fixedDate, body: "I'm Sam.\nSecond line."))
        doc.append(ContextParagraph(kind: .clarification, date: fixedDate, body: "Speaker 1 is Ana"))
        doc.append(ContextParagraph(kind: .chat, date: fixedDate, body: "what is the deadline?"))
        let md = doc.markdown
        XCTAssertTrue(md.hasPrefix("[text 1 · pasted · 2026-10-28T14:02:33Z]\nI'm Sam.\nSecond line.\n\n[clarification · "))
        XCTAssertEqual(ContextDocument(markdown: md), doc)
        XCTAssertEqual(doc.plainText, "I'm Sam.\nSecond line.\n\n[clarification] Speaker 1 is Ana\n\n[chat] what is the deadline?")
        XCTAssertEqual(ContextDocument(markdown: "loose text\nmore").paragraphs.map(\.kind), [.note])
    }

    func testSubmitModes() {
        let previous = "Para one.\n\nPara two."
        XCTAssertEqual(Submit.changedParagraphs(previous: previous, current: "Para one.\n\nPara two changed.\n\nPara three."), ["Para two changed.", "Para three."])
        XCTAssertEqual(Submit.changedParagraphs(previous: nil, current: "A.\n\nB."), ["A.", "B."])

        var walk = SentenceWalk(textID: 1, sentences: [Sentence(text: 1, s: 1, sentence: "A."), Sentence(text: 1, s: 2, sentence: "B.")])
        XCTAssertEqual(walk.current?.s, 1)
        XCTAssertEqual(walk.progress, 0)
        walk.advance()
        XCTAssertEqual(walk.current?.s, 2)
        walk.advance()
        XCTAssertTrue(walk.isFinished)
        XCTAssertNil(walk.current)
        XCTAssertEqual(walk.progress, 1)
    }
}
