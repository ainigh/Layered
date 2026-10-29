import Foundation

/// Demo mode (SPEC “Development approach”): three fixture maps checked into the package,
/// loaded with no folder and no model, plus recorded model responses for them.
public enum Demo {
    public enum Map: String, CaseIterable, Sendable { case tiny, typical, large }

    /// The package's resource bundle. A signed app carries it in Contents/Resources (codesign
    /// refuses anything loose beside Contents/), where SwiftPM's `Bundle.module` doesn't look.
    static var resources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Harness_Harness.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    public static func log(_ map: Map) -> String {
        guard let url = resources.url(forResource: map.rawValue, withExtension: "mm", subdirectory: "Demo"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    public static func text(_ map: Map) -> String {
        guard let url = resources.url(forResource: map.rawValue, withExtension: "txt", subdirectory: "Demo"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    /// A ready state: the text submitted, the map compiled from the fixture log.
    public static func state(_ map: Map, now: Date = Date(timeIntervalSince1970: 1_793_196_153)) -> MapState {
        var evidence = EvidenceStore()
        let text = Demo.text(map)
        if !text.isEmpty { evidence.appendText(text) }
        var state = (try? MapState(log: log(map), evidence: evidence)) ?? MapState()
        if !text.isEmpty {
            state.texts[1] = text
            state.context.append(ContextParagraph(kind: .pasted, textID: 1, date: now, body: text))
        }
        return state
    }

    /// Recorded responses so demo mode can “expand” and “chat” without Ollama.
    public static func client() -> FixtureClient {
        FixtureClient(recordings: [
            .init(kind: .expand, response: "| paper - published in | journal @src world\n| sam - should email | ana @src advice\n| paper - about | memory graph @src guess\n", promptTokens: 900, responseTokens: 40),
            .init(kind: .chat, response: "Ana reviews the paper that Sam is writing; the deadline is Nov 3.\n\n```mm\n| paper @todo send draft early @src advice\n```\n", promptTokens: 700, responseTokens: 30),
            .init(kind: .clarify, response: "s1 [pronoun] Who is \"I\" in the first sentence?\ns2 [time] Which year is Nov 3?\n", promptTokens: 500, responseTokens: 25),
            .init(kind: .dedupe, response: "", promptTokens: 300, responseTokens: 2),
            .init(kind: .verify, response: "", promptTokens: 600, responseTokens: 2),
            .init(kind: .extract, response: "| sam @kind person @src text @s 1\n| paper @kind thing @src text @s 2\n| sam - writes | paper @src text @s 2\n| ana @kind person @src text @s 2\n| ana - reviews | paper @src text @s 2\n", promptTokens: 800, responseTokens: 60),
        ], installed: [ModelInfo(name: "demo", sizeBytes: 0)])
    }
}
