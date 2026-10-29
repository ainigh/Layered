import XCTest
@testable import Harness

/// The maps folder: one project per folder inside it, demos included.
final class WorkspaceTests: XCTestCase {
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layered-ws-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testProjectsAreTheFoldersInside() throws {
        let ws = try Workspace(root: try temp())
        XCTAssertEqual(ws.projects(), [])
        let thesis = try ws.create("  Thesis ")
        XCTAssertEqual(thesis.name, "Thesis")
        XCTAssertTrue(FileManager.default.fileExists(atPath: thesis.url.appendingPathComponent("texts").path), "a project is a map folder")
        try ws.create("Notes/2026: draft")
        try "not a project".write(to: ws.root.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: ws.root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)

        XCTAssertEqual(Set(ws.projects().map(\.name)), ["Thesis", "Notes-2026- draft"])
        XCTAssertThrowsError(try ws.create("Thesis")) { XCTAssertEqual($0 as? Workspace.Problem, .exists("Thesis")) }
        XCTAssertThrowsError(try ws.create(" ..  ")) { XCTAssertEqual($0 as? Workspace.Problem, .emptyName) }
    }

    func testTheMostRecentlyChangedComesFirst() throws {
        let ws = try Workspace(root: try temp())
        let old = try ws.create("Old")
        let new = try ws.create("New")
        try "| a".write(to: old.url.appendingPathComponent("map.mm"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.url.appendingPathComponent("map.mm").path)
        try "| b".write(to: new.url.appendingPathComponent("map.mm"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ws.projects().map(\.name), ["New", "Old"])
    }

    func testADemoIsAProjectWithItsMapAndRecordedModel() throws {
        let ws = try Workspace(root: try temp())
        let demo = try ws.demo(.typical)
        XCTAssertEqual(demo.name, "Demo – Typical")
        XCTAssertTrue(demo.isDemo)
        XCTAssertTrue(Workspace.isDemo(demo.url))

        let loaded = try Persistence.load(try FolderStorage(root: demo.url))
        XCTAssertEqual(loaded.state.graph.nodes, Demo.state(.typical).graph.nodes)
        XCTAssertEqual(loaded.state.texts, Demo.state(.typical).texts)
        XCTAssertEqual(loaded.settings.model.model, Workspace.demoModel)

        // Asking again opens what is there, edits and all.
        try FolderStorage(root: demo.url).appendLog(["| extra @src user"])
        let again = try ws.demo(.typical)
        XCTAssertEqual(again.url, demo.url)
        XCTAssertNotNil(try Persistence.load(try FolderStorage(root: again.url)).state.graph.node("extra"))
        XCTAssertEqual(ws.projects().count, 1)
    }
}
