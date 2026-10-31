import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to Ollama's HTTP API: streams `/api/generate`, lists `/api/tags`.
public struct OllamaClient: ModelClient {
    public var host: URL
    public var session: URLSession
    /// Send the GBNF grammar with the request. Builds that reject it answer 400 and the
    /// runner falls back to post-validation only.
    public var sendGrammar: Bool

    public init(host: URL = URL(string: "http://localhost:11434")!, session: URLSession = .shared, sendGrammar: Bool = true) {
        self.host = host
        self.session = session
        self.sendGrammar = sendGrammar
    }

    struct GenerateBody: Encodable {
        var model: String
        var prompt: String
        var stream = true
        /// Thinking off: a thinking model (qwen3, deepseek-r1…) answers at once instead of
        /// reasoning at length first. Builds without the field ignore it.
        var think = false
        var grammar: String?
        var options: Options
        struct Options: Encodable {
            var temperature: Double
            var num_ctx: Int?
        }
    }

    struct GenerateLine: Decodable {
        var response: String?
        var done: Bool?
        var prompt_eval_count: Int?
        var eval_count: Int?
        var error: String?
    }

    struct Tags: Decodable {
        struct Model: Decodable {
            var name: String
            var size: Int64
            struct Details: Decodable {
                var parameter_size: String?
                var quantization_level: String?
            }
            var details: Details?
        }
        var models: [Model]
    }

    public func generate(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            var http = URLRequest(url: host.appendingPathComponent("api/generate"))
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.timeoutInterval = 600
            let body = GenerateBody(model: request.model, prompt: request.prompt,
                                    grammar: sendGrammar ? request.grammar : nil,
                                    options: .init(temperature: request.temperature, num_ctx: request.contextSize))
            do {
                http.httpBody = try JSONEncoder().encode(body)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let hasGrammar = request.grammar != nil && sendGrammar
            let delegate = StreamingDelegate(
                onLine: { line in
                    guard let data = line.data(using: .utf8), let chunk = try? JSONDecoder().decode(GenerateLine.self, from: data) else { return }
                    if let error = chunk.error {
                        continuation.finish(throwing: ModelError.badResponse(200, error))
                        return
                    }
                    continuation.yield(ModelChunk(text: chunk.response ?? "", done: chunk.done ?? false,
                                                  promptTokens: chunk.prompt_eval_count, responseTokens: chunk.eval_count))
                },
                onEnd: { status, tail, error in
                    if let error {
                        continuation.finish(throwing: ModelError.notConnected(error.localizedDescription))
                    } else if status == 200 {
                        continuation.finish()
                    } else if status == 400, hasGrammar {
                        continuation.finish(throwing: ModelError.grammarRejected)
                    } else {
                        continuation.finish(throwing: ModelError.badResponse(status, tail))
                    }
                })
            let streamingSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
            let task = streamingSession.dataTask(with: http)
            continuation.onTermination = { _ in
                task.cancel()
                streamingSession.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }

    public func models() async throws -> [ModelInfo] {
        let (data, response) = try await session.data(from: host.appendingPathComponent("api/tags"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelError.notConnected(host.absoluteString)
        }
        return try JSONDecoder().decode(Tags.self, from: data).models.map {
            ModelInfo(name: $0.name, sizeBytes: $0.size, parameterSize: $0.details?.parameter_size, quantization: $0.details?.quantization_level)
        }
    }

    /// “Test connection”: true when `/api/tags` answers.
    public func ping() async -> Bool {
        (try? await models()) != nil
    }
}

/// Collects a streamed body line by line (Ollama sends one JSON object per line).
final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onLine: @Sendable (String) -> Void
    private let onEnd: @Sendable (Int, String, Error?) -> Void
    private var buffer = Data()
    private var status = 0
    private var tail = ""

    init(onLine: @escaping @Sendable (String) -> Void, onEnd: @escaping @Sendable (Int, String, Error?) -> Void) {
        self.onLine = onLine
        self.onEnd = onEnd
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        guard status == 200 else {
            tail += String(decoding: data, as: UTF8.self)
            return
        }
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine(line) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if status == 200, !buffer.isEmpty {
            onLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        onEnd(status, tail, error)
        session.finishTasksAndInvalidate()
    }
}
