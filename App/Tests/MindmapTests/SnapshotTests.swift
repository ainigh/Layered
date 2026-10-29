import XCTest
import SwiftUI
import Harness
@testable import Mindmap

/// Snapshot tests: each panel and the canvas against fixture maps, light and dark, two
/// window sizes. Images live in `__Snapshots__`; a missing image is recorded, a differing
/// one fails and writes `<name>.new.png` beside it for review.
@MainActor
final class SnapshotTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")

    func snapshot<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat, dark: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not render \(name)", file: file, line: line)
        }
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let url = Self.dir.appendingPathComponent("\(name)-\(Int(width))x\(Int(height))-\(dark ? "dark" : "light").png")
        guard let existing = try? Data(contentsOf: url) else {
            try png.write(to: url)
            return
        }
        if existing != png {
            try png.write(to: url.deletingPathExtension().appendingPathExtension("new.png"))
            XCTFail("\(url.lastPathComponent) changed; review the .new.png and replace it if the diff is intentional", file: file, line: line)
        }
    }

    func forEachVariant(_ body: (CGFloat, CGFloat, Bool) throws -> Void) rethrows {
        for (w, h) in [(900.0, 600.0), (1400.0, 900.0)] { for dark in [false, true] { try body(w, h, dark) } }
    }

    func testCanvas() throws {
        for map in Demo.Map.allCases {
            try forEachVariant { w, h, dark in
                try snapshot("canvas-\(map.rawValue)", CanvasView(session: MapSession.demo(map)), width: w, height: h, dark: dark)
            }
        }
    }

    func testPanels() throws {
        let session = Fixture.contextSession()
        session.selection = ["paper"]
        session.dedupeProposals = Dedupe.cheapPass(session.state.graph)
        let panels: [(String, AnyView)] = [
            ("context", AnyView(ContextPanel(session: session))),
            ("details", AnyView(DetailsPanel(session: session))),
            ("outline", AnyView(OutlinePanel(session: session))),
            ("prompt", AnyView(PromptPanel(session: session))),
            ("settings", AnyView(SettingsPanel(session: session))),
            ("history", AnyView(HistoryPanel(session: session))),
        ]
        for (name, view) in panels {
            for dark in [false, true] {
                try snapshot("panel-\(name)", PanelContainer(title: name, symbol: "circle", onClose: {}) { view }, width: 360, height: 640, dark: dark)
            }
        }
    }

    func testOverlays() throws {
        let session = Fixture.contextSession()
        session.clarifyQuestions = [ClarifyQuestion(sentence: 1, reason: "pronoun", question: "Who is \"they\"?")]
        session.verifyReport = VerifyReport.parse("s2\n| kim - chairs | workshop @src text @s 2")
        session.audioJob = AudioJob(file: URL(fileURLWithPath: "/tmp/meeting.m4a"), step: .transcribing(0.4))
        let overlays: [(String, Overlay)] = [("item", .item(1)), ("reply", .item(session.state.context.items.last!.id)), ("clarify", .clarify), ("coverage", .coverage), ("audio", .audio)]
        for (name, overlay) in overlays {
            for dark in [false, true] {
                try snapshot("overlay-\(name)", MapOverlay(session: session, overlay: overlay), width: 900, height: 640, dark: dark)
            }
        }
    }

    func testNotationAndHeldBack() throws {
        let session = MapSession.demo(.typical)
        for dark in [false, true] {
            try snapshot("notation-editor", NotationEditor(session: session), width: 500, height: 320, dark: dark)
            try snapshot("held-back", HeldBackList(session: session), width: 500, height: 320, dark: dark)
        }
    }

    func testStatusBarAndDrawer() throws {
        let session = MapSession.demo(.tiny)
        try forEachVariant { w, _, dark in
            try snapshot("statusbar", StatusBar(session: session, model: AppModel()), width: w, height: 28, dark: dark)
        }
    }
}

/// Smoke flows the harness can run without a mouse: open demo, add, submit, expand, undo, ask.
@MainActor
final class SessionFlowTests: XCTestCase {
    func testDemoSubmitExpandUndo() async throws {
        let session = MapSession.demo(.tiny)
        let nodes = session.state.graph.nodes.count
        session.addContext("Kim chairs the workshop.")
        XCTAssertEqual(session.pendingItems.count, 1)
        session.submit()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThanOrEqual(session.state.evidence.count, 3)
        XCTAssertEqual(session.pendingItems.count, 0, "submitted items are on the map")
        let afterSubmit = session.state.graph.nodes.count
        XCTAssertGreaterThanOrEqual(afterSubmit, nodes)
        session.expand("paper")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(session.state.graph.nodes.count, afterSubmit)
        let before = session.state.log.count
        session.dispatch(.undo)
        XCTAssertGreaterThan(session.state.log.count, before, "undo appends")
        XCTAssertEqual(session.state.graph.nodes.count, afterSubmit, "expand undone")
    }

    func testAskAddsLinesAndAReplyItem() async throws {
        let session = MapSession.demo(.typical)
        let items = session.state.context.items.count
        session.ask("what should Sam do next?")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.state.context.items.count, items + 1)
        let reply = try XCTUnwrap(session.state.context.items.last)
        XCTAssertEqual(reply.origin, .model)
        XCTAssertFalse(reply.selected, "a reply waits to be selected")
        XCTAssertEqual(session.overlay, .item(reply.id), "the reply opens over the map")
        XCTAssertNotNil(session.state.graph.node("paper")?.notes.first { $0.hasPrefix("todo") }, "the reply's lines are on the map")
    }
}
