import Foundation

/// One stateless request: prompt + map + context + the item, built from scratch every time.
public struct ModelRequest: Equatable, Sendable {
    public var model: String
    public var prompt: String
    public var grammar: String?
    public var temperature: Double
    public var contextSize: Int?

    public init(model: String, prompt: String, grammar: String? = nil, temperature: Double = 0, contextSize: Int? = nil) {
        self.model = model
        self.prompt = prompt
        self.grammar = grammar
        self.temperature = temperature
        self.contextSize = contextSize
    }
}

public struct ModelChunk: Equatable, Sendable {
    public var text: String
    public var done: Bool
    public var promptTokens: Int?
    public var responseTokens: Int?

    public init(text: String, done: Bool = false, promptTokens: Int? = nil, responseTokens: Int? = nil) {
        self.text = text
        self.done = done
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
    }
}

public struct ModelInfo: Equatable, Sendable, Codable {
    public var name: String
    public var sizeBytes: Int64
    public var parameterSize: String?
    public var quantization: String?

    public init(name: String, sizeBytes: Int64, parameterSize: String? = nil, quantization: String? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.quantization = quantization
    }

    /// Whether the model fits in memory with room for the OS (SPEC “Connection”):
    /// weights plus a 25% working margin, leaving 8 GB for everything else.
    public func fits(inMemory bytes: Int64) -> Bool {
        Int64(Double(sizeBytes) * 1.25) + 8 * 1024 * 1024 * 1024 <= bytes
    }

    /// The largest installed model that fits: the default pick.
    public static func defaultModel(from models: [ModelInfo], memory: Int64) -> ModelInfo? {
        models.filter { $0.fits(inMemory: memory) }.max { $0.sizeBytes < $1.sizeBytes }
    }
}

public enum ModelError: Error, Equatable, Sendable {
    case notConnected(String)
    case badResponse(Int, String)
    case grammarRejected
    case noModel
}

/// Anything that can stream a completion: Ollama over HTTP, or recorded fixtures in tests.
public protocol ModelClient: Sendable {
    func generate(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, Error>
    func models() async throws -> [ModelInfo]
}

/// Replays recorded responses. Used by every test and by demo mode; never requires Ollama.
public struct FixtureClient: ModelClient {
    public struct Recording: Equatable, Sendable, Codable {
        public var kind: PromptKind
        public var model: String?
        /// When set, the recording only answers prompts containing this text.
        public var match: String?
        public var response: String
        public var promptTokens: Int?
        public var responseTokens: Int?

        public init(kind: PromptKind, model: String? = nil, match: String? = nil, response: String, promptTokens: Int? = nil, responseTokens: Int? = nil) {
            self.kind = kind
            self.model = model
            self.match = match
            self.response = response
            self.promptTokens = promptTokens
            self.responseTokens = responseTokens
        }
    }

    public var recordings: [Recording]
    public var installed: [ModelInfo]
    /// Split the response into chunks of this many characters to exercise streaming.
    public var chunkSize: Int

    public init(recordings: [Recording], installed: [ModelInfo] = [ModelInfo(name: "fixture", sizeBytes: 0)], chunkSize: Int = 7) {
        self.recordings = recordings
        self.installed = installed
        self.chunkSize = chunkSize
    }

    public init(json: Data) throws {
        self.init(recordings: try JSONDecoder().decode([Recording].self, from: json))
    }

    func recording(for request: ModelRequest) -> Recording? {
        let kind = PromptKind.allCases.first { request.prompt.hasPrefix(PromptSet.marker(for: $0)) }
        return recordings.first { r in
            (r.model == nil || r.model == request.model)
                && (kind == nil || r.kind == kind)
                && (r.match == nil || request.prompt.contains(r.match!))
        }
    }

    public func generate(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            guard let recording = recording(for: request) else {
                continuation.finish(throwing: ModelError.notConnected("no recording for this request"))
                return
            }
            var text = Substring(recording.response)
            while !text.isEmpty {
                let piece = text.prefix(chunkSize)
                text = text.dropFirst(chunkSize)
                continuation.yield(ModelChunk(text: String(piece)))
            }
            continuation.yield(ModelChunk(text: "", done: true, promptTokens: recording.promptTokens, responseTokens: recording.responseTokens))
            continuation.finish()
        }
    }

    public func models() async throws -> [ModelInfo] { installed }
}

extension PromptSet {
    /// The first words of each default prompt, so fixtures can tell requests apart.
    static func marker(for kind: PromptKind) -> String {
        String(defaultTemplate(for: kind).prefix(40))
    }
}

/// Splits streamed text into complete lines; the last partial line waits for more.
public struct LineAccumulator: Sendable {
    private var buffer = ""

    public init() {}

    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<newline]))
            buffer = String(buffer[buffer.index(after: newline)...])
        }
        return lines
    }

    public mutating func flush() -> [String] {
        defer { buffer = "" }
        return buffer.isEmpty ? [] : [buffer]
    }
}

/// Drops `<think>…</think>` from streamed text: what a thinking model reasons before it
/// answers. A tag split across chunks waits for the rest.
public struct ThinkFilter: Sendable {
    private var inside = false
    private var pending = ""

    public init() {}

    public mutating func feed(_ text: String) -> String {
        pending += text
        var out = ""
        while true {
            let tag = inside ? "</think>" : "<think>"
            if let r = pending.range(of: tag) {
                if !inside { out += pending[..<r.lowerBound] }
                pending = String(pending[r.upperBound...])
                inside.toggle()
                continue
            }
            // The end might be the start of a tag: keep it for the next chunk.
            let keep = (1..<tag.count).reversed().first { pending.hasSuffix(tag.prefix($0)) } ?? 0
            if !inside { out += pending.dropLast(keep) }
            pending = String(pending.suffix(keep))
            return out
        }
    }

    /// The end of the stream: what was held back, unless it was inside a think block.
    public mutating func flush() -> String {
        defer { pending = "" }
        return inside ? "" : pending
    }
}
