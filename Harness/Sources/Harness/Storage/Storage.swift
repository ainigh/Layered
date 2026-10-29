import Foundation

/// Everything the app keeps on disk (SPEC “Storage”), behind a protocol so tests and
/// demo mode run in memory. Append-only is enforced by the shape of the protocol: there
/// is no call that truncates `map.mm`, `context.md` or the evidence store. `optimize`
/// is the one rewrite, and it archives the old log first.
public protocol MapStorage: Sendable {
    func readLog() throws -> String
    func appendLog(_ lines: [String]) throws

    func readContext() throws -> String
    func appendContext(_ text: String) throws

    func readEvidence() throws -> String
    func appendEvidence(_ sentences: [Sentence]) throws

    func writeText(id: Int, _ text: String) throws
    func readText(id: Int) throws -> String?

    func readPrompt(_ kind: PromptKind) throws -> String?
    func writePrompt(_ kind: PromptKind, _ text: String?) throws

    func readSettings() throws -> Settings?
    func writeSettings(_ settings: Settings) throws

    func readUIState() throws -> UIState?
    func writeUIState(_ state: UIState) throws

    func writeSnapshot(turn: Int, _ canonical: String) throws
    func readSnapshot(turn: Int) throws -> String?
    func snapshotTurns() throws -> [Int]

    /// Replaces the log with its canonical form. The old log is moved to `archive/` first.
    func optimize(newLog: String, archiveName: String) throws -> String
    func archivedLogs() throws -> [String]

    func storeAudio(id: Int, from url: URL) throws -> URL
    func writeTranscript(id: Int, _ json: Data) throws
    func readTranscript(id: Int) throws -> Data?

    func appendErrorLog(_ line: String) throws
    func readIconManifest() throws -> Data?
}

/// User settings saved in `settings.json`.
public struct Settings: Equatable, Sendable, Codable {
    public var model = ModelSettings()
    public var whisperModel = "large-v3-turbo"
    public var theme = "system"
    public var layout = LayoutOptions()
    public var globalShortcut = "ctrl+alt+cmd+m"
    public var optimizeEveryTurns: Int? = nil

    public init() {}
}

public struct LayoutOptions: Equatable, Sendable, Codable {
    public var linkDistance: Double = 140
    public var repulsion: Double = 9000
    public var headingPull: Double = 0.05
    public var seed: UInt64 = 1

    public init() {}
}

/// Canvas state the harness owns: viewport, panel layout, collapsed headings.
/// Kept in `ui.json` rather than in a `_ui` scope: the base notation has no line that
/// returns to the root scope, so a scope line in the log would capture every later line.
public struct UIState: Equatable, Sendable, Codable {
    public var viewportX: Double = 0
    public var viewportY: Double = 0
    public var zoom: Double = 1
    public var panels: [String: PanelPlacement] = [:]
    public var collapsedHeadings: [String] = []
    public var windowFrame: [Double]? = nil

    public init() {}
}

public struct PanelPlacement: Equatable, Sendable, Codable {
    public enum Edge: String, Sendable, Codable { case leading, trailing, top, bottom, floating }
    public var edge: Edge = .trailing
    public var open = false
    public var x: Double = 0
    public var y: Double = 0
    public var width: Double = 320
    public var height: Double = 400

    public init() {}
}

/// In-memory storage for tests and demo mode.
public final class InMemoryStorage: MapStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var context = ""
    private var evidence = ""
    private var texts: [Int: String] = [:]
    private var prompts: [PromptKind: String] = [:]
    private var settings: Settings?
    private var ui: UIState?
    private var snapshots: [Int: String] = [:]
    private var archive: [String: String] = [:]
    private var transcripts: [Int: Data] = [:]
    public private(set) var errors: [String] = []
    public var iconManifest: Data?

    public init(log: String = "", evidence: String = "", context: String = "") {
        self.log = log.split(separator: "\n").map(String.init)
        self.evidence = evidence
        self.context = context
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    public func readLog() throws -> String { sync { log.isEmpty ? "" : log.joined(separator: "\n") + "\n" } }
    public func appendLog(_ lines: [String]) throws { sync { log += lines } }
    public func readContext() throws -> String { sync { context } }
    public func appendContext(_ text: String) throws { sync { context += text } }
    public func readEvidence() throws -> String { sync { evidence } }
    public func appendEvidence(_ sentences: [Sentence]) throws {
        var store = EvidenceStore()
        for s in sentences { store.append(s) }
        let tail = store.jsonl()
        sync { evidence += tail }
    }
    public func writeText(id: Int, _ text: String) throws { sync { if texts[id] == nil { texts[id] = text } } }
    public func readText(id: Int) throws -> String? { sync { texts[id] } }
    public func readPrompt(_ kind: PromptKind) throws -> String? { sync { prompts[kind] } }
    public func writePrompt(_ kind: PromptKind, _ text: String?) throws { sync { prompts[kind] = text } }
    public func readSettings() throws -> Settings? { sync { settings } }
    public func writeSettings(_ settings: Settings) throws { sync { self.settings = settings } }
    public func readUIState() throws -> UIState? { sync { ui } }
    public func writeUIState(_ state: UIState) throws { sync { ui = state } }
    public func writeSnapshot(turn: Int, _ canonical: String) throws { sync { snapshots[turn] = canonical } }
    public func readSnapshot(turn: Int) throws -> String? { sync { snapshots[turn] } }
    public func snapshotTurns() throws -> [Int] { sync { snapshots.keys.sorted() } }
    public func optimize(newLog: String, archiveName: String) throws -> String {
        sync {
            archive[archiveName] = log.joined(separator: "\n") + "\n"
            log = newLog.split(separator: "\n").map(String.init)
            return archiveName
        }
    }
    public func archivedLogs() throws -> [String] { sync { archive.keys.sorted() } }
    public func archivedLog(named name: String) -> String? { sync { archive[name] } }
    public func storeAudio(id: Int, from url: URL) throws -> URL { url }
    public func writeTranscript(id: Int, _ json: Data) throws { sync { transcripts[id] = json } }
    public func readTranscript(id: Int) throws -> Data? { sync { transcripts[id] } }
    public func appendErrorLog(_ line: String) throws { sync { errors.append(line) } }
    public func readIconManifest() throws -> Data? { sync { iconManifest } }
}

/// A plain folder: readable, diffable and syncable without the app.
public struct FolderStorage: MapStorage {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root
        for sub in ["texts", "audio", "prompts", "icons", "snapshots", "archive"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    public var logURL: URL { root.appendingPathComponent("map.mm") }
    public var contextURL: URL { root.appendingPathComponent("context.md") }
    public var evidenceURL: URL { root.appendingPathComponent("texts/sentences.jsonl") }
    public var settingsURL: URL { root.appendingPathComponent("settings.json") }
    public var uiURL: URL { root.appendingPathComponent("ui.json") }
    public var errorLogURL: URL { root.appendingPathComponent("errors.log") }

    // MARK: - Helpers

    private func read(_ url: URL) throws -> String {
        guard fm.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Appends and flushes; never truncates.
    private func append(_ text: String, to url: URL) throws {
        guard !text.isEmpty else { return }
        let data = Data(text.utf8)
        if !fm.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: try Data(contentsOf: url))
    }

    private func writeJSON<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    // MARK: - MapStorage

    public func readLog() throws -> String { try read(logURL) }

    public func appendLog(_ lines: [String]) throws {
        try append(lines.map { $0 + "\n" }.joined(), to: logURL)
    }

    public func readContext() throws -> String { try read(contextURL) }
    public func appendContext(_ text: String) throws { try append(text, to: contextURL) }

    public func readEvidence() throws -> String { try read(evidenceURL) }

    public func appendEvidence(_ sentences: [Sentence]) throws {
        var store = EvidenceStore()
        for s in sentences { store.append(s) }
        try append(store.jsonl(), to: evidenceURL)
    }

    public func writeText(id: Int, _ text: String) throws {
        let url = root.appendingPathComponent("texts/\(id).txt")
        guard !fm.fileExists(atPath: url.path) else { return }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public func readText(id: Int) throws -> String? {
        let url = root.appendingPathComponent("texts/\(id).txt")
        return fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
    }

    public func readPrompt(_ kind: PromptKind) throws -> String? {
        let url = root.appendingPathComponent("prompts/\(kind.rawValue).md")
        return fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
    }

    public func writePrompt(_ kind: PromptKind, _ text: String?) throws {
        let url = root.appendingPathComponent("prompts/\(kind.rawValue).md")
        if let text { try Data(text.utf8).write(to: url, options: .atomic) } else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    public func readSettings() throws -> Settings? { try readJSON(Settings.self, settingsURL) }
    public func writeSettings(_ settings: Settings) throws { try writeJSON(settings, settingsURL) }
    public func readUIState() throws -> UIState? { try readJSON(UIState.self, uiURL) }
    public func writeUIState(_ state: UIState) throws { try writeJSON(state, uiURL) }

    public func writeSnapshot(turn: Int, _ canonical: String) throws {
        try Data(canonical.utf8).write(to: root.appendingPathComponent(String(format: "snapshots/%04d.mm", turn)), options: .atomic)
    }

    public func readSnapshot(turn: Int) throws -> String? {
        let url = root.appendingPathComponent(String(format: "snapshots/%04d.mm", turn))
        return fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
    }

    public func snapshotTurns() throws -> [Int] {
        try fm.contentsOfDirectory(atPath: root.appendingPathComponent("snapshots").path)
            .compactMap { $0.hasSuffix(".mm") ? Int($0.dropLast(3)) : nil }
            .sorted()
    }

    public func optimize(newLog: String, archiveName: String) throws -> String {
        var name = archiveName
        var n = 1
        while fm.fileExists(atPath: root.appendingPathComponent("archive/\(name)").path) {
            n += 1
            name = archiveName.replacingOccurrences(of: ".mm", with: "-\(n).mm")
        }
        if fm.fileExists(atPath: logURL.path) {
            try fm.moveItem(at: logURL, to: root.appendingPathComponent("archive/\(name)"))
        }
        try Data(newLog.utf8).write(to: logURL, options: .atomic)
        return name
    }

    public func archivedLogs() throws -> [String] {
        try fm.contentsOfDirectory(atPath: root.appendingPathComponent("archive").path).filter { $0.hasSuffix(".mm") }.sorted()
    }

    public func storeAudio(id: Int, from url: URL) throws -> URL {
        let target = root.appendingPathComponent("audio/\(id).\(url.pathExtension.isEmpty ? "audio" : url.pathExtension)")
        if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
        return target
    }

    public func writeTranscript(id: Int, _ json: Data) throws {
        try json.write(to: root.appendingPathComponent("audio/\(id).transcript.json"), options: .atomic)
    }

    public func readTranscript(id: Int) throws -> Data? {
        let url = root.appendingPathComponent("audio/\(id).transcript.json")
        return fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    public func appendErrorLog(_ line: String) throws { try append(line + "\n", to: errorLogURL) }

    public func readIconManifest() throws -> Data? {
        let url = root.appendingPathComponent("icons/manifest.json")
        return fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
}
