import Foundation

/// Connects the pure reducer to storage: load a folder into a `MapState`, and after each
/// action append exactly what the step added. A write failure keeps the turn in memory
/// and is reported so the UI can warn until the folder is reachable.
public enum Persistence {
    public struct Loaded: Sendable {
        public var state: MapState
        public var context: ContextDocument
        public var settings: Settings
        public var prompts: PromptSet
        public var ui: UIState
    }

    public static func load(_ storage: any MapStorage) throws -> Loaded {
        let evidence = try EvidenceStore(jsonl: try storage.readEvidence())
        var state = try MapState(log: try storage.readLog(), evidence: evidence)
        for id in Set(evidence.sentences.map(\.text)) {
            if let text = try storage.readText(id: id) { state.texts[id] = text }
            if let data = try storage.readTranscript(id: id), let t = try? JSONDecoder().decode(Transcript.self, from: data) { state.transcripts[id] = t }
        }
        state.context = ContextDocument(markdown: try storage.readContext())
        var prompts = PromptSet()
        for kind in PromptKind.allCases {
            if let override = try storage.readPrompt(kind) { prompts.overrides[kind] = override }
        }
        return Loaded(state: state,
                      context: ContextDocument(markdown: try storage.readContext()),
                      settings: try storage.readSettings() ?? Settings(),
                      prompts: prompts,
                      ui: try storage.readUIState() ?? UIState())
    }

    /// Appends the log tail, new evidence and new texts that `after` has beyond `before`.
    /// Returns the lines that could not be written (empty when everything was flushed).
    @discardableResult
    public static func sync(before: MapState, after: MapState, storage: any MapStorage) -> [String] {
        var pending: [String] = []
        let newLines = Array(after.log.dropFirst(before.log.count))
        if !newLines.isEmpty {
            do { try storage.appendLog(newLines) } catch { pending += newLines; try? storage.appendErrorLog("map.mm: \(error)") }
        }
        let newSentences = Array(after.evidence.sentences.dropFirst(before.evidence.count))
        if !newSentences.isEmpty {
            do { try storage.appendEvidence(newSentences) } catch { pending.append("evidence"); try? storage.appendErrorLog("sentences.jsonl: \(error)") }
        }
        for (id, text) in after.texts where before.texts[id] == nil {
            do { try storage.writeText(id: id, text) } catch { pending.append("text \(id)"); try? storage.appendErrorLog("texts/\(id).txt: \(error)") }
        }
        let newParagraphs = after.context.paragraphs.dropFirst(before.context.paragraphs.count)
        if !newParagraphs.isEmpty {
            do { try storage.appendContext(newParagraphs.map(\.rendered).joined()) } catch { pending.append("context"); try? storage.appendErrorLog("context.md: \(error)") }
        }
        for (id, transcript) in after.transcripts where before.transcripts[id] == nil {
            if let data = try? JSONEncoder().encode(transcript) { try? storage.writeTranscript(id: id, data) }
        }
        if let last = after.turns.last, after.turns.count > before.turns.count {
            try? storage.writeSnapshot(turn: last.number, after.canonical)
        }
        return pending
    }
}
