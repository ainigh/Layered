import Foundation

/// Output of transcription: segments with start and end times and, after diarization,
/// a speaker label (SPEC “Audio”). Saved verbatim as `audio/<id>.transcript.json`.
public struct Transcript: Equatable, Sendable, Codable {
    public struct Segment: Equatable, Sendable, Codable {
        public var t0: Double
        public var t1: Double
        public var text: String
        public var speaker: String?

        public init(t0: Double, t1: Double, text: String, speaker: String? = nil) {
            self.t0 = t0
            self.t1 = t1
            self.text = text
            self.speaker = speaker
        }
    }

    public var segments: [Segment]
    public var language: String?
    public var model: String?

    public init(segments: [Segment], language: String? = nil, model: String? = nil) {
        self.segments = segments
        self.language = language
        self.model = model
    }

    /// Splits segments into sentences for the evidence store. A segment holding several
    /// sentences shares its time span between them in proportion to their length.
    public func sentences(textID: Int) -> [Sentence] {
        var out: [Sentence] = []
        for segment in segments {
            let parts = SentenceSplitter.split(segment.text)
            guard !parts.isEmpty else { continue }
            let total = Double(parts.reduce(0) { $0 + $1.count })
            var cursor = segment.t0
            for part in parts {
                let span = total > 0 ? (segment.t1 - segment.t0) * Double(part.count) / total : 0
                out.append(Sentence(text: textID, s: out.count + 1, sentence: part, t0: cursor, t1: cursor + span, speaker: segment.speaker))
                cursor += span
            }
        }
        return out
    }

    /// The transcript as it lands in the Context panel: timestamps and speakers per line.
    public var rendered: String {
        segments.map { seg in
            let stamp = Transcript.stamp(seg.t0)
            let who = seg.speaker.map { "\($0): " } ?? ""
            return "[\(stamp)] \(who)\(seg.text)"
        }.joined(separator: "\n")
    }

    static func stamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    public var speakers: [String] {
        var seen: [String] = []
        for s in segments { if let sp = s.speaker { seen.appendUnique(sp) } }
        return seen
    }
}

/// Runs whisper on a file. The app implements it with whisper.cpp; tests use a fixture.
public protocol Transcriber: Sendable {
    func transcribe(_ audio: URL, model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript
}

/// Assigns `Speaker n` labels to segments. The app tries a local pipeline; tests use a fixture.
public protocol Diarizer: Sendable {
    func diarize(_ transcript: Transcript, audio: URL) async throws -> Transcript
}

public struct FixtureTranscriber: Transcriber, Diarizer {
    public var transcript: Transcript
    public var labels: [String]

    public init(transcript: Transcript, labels: [String] = []) {
        self.transcript = transcript
        self.labels = labels
    }

    public func transcribe(_ audio: URL, model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        progress(1)
        var t = transcript
        t.model = model
        return t
    }

    public func diarize(_ transcript: Transcript, audio: URL) async throws -> Transcript {
        var t = transcript
        for i in t.segments.indices where i < labels.count { t.segments[i].speaker = labels[i] }
        return t
    }
}

/// Speaker labels mapped to names, read from clarification paragraphs
/// (`Speaker 1 is Ana`). Produces the aliases the gate uses for proof.
public struct SpeakerMap: Equatable, Sendable {
    public var names: [String: String] = [:]   // "speaker 1" → "ana"

    public init(names: [String: String] = [:]) {
        self.names = names
    }

    public init(context: ContextDocument) {
        for p in context.paragraphs(ofKind: .clarification) {
            if let (label, name) = SpeakerMap.parse(p.body) { names[label] = name }
        }
    }

    /// `Speaker 1 is Ana` → ("speaker 1", "ana")
    public static func parse(_ body: String) -> (String, String)? {
        let lower = Text.collapse(body).lowercased()
        guard lower.hasPrefix("speaker "), let range = lower.range(of: " is ") else { return nil }
        let label = String(lower[..<range.lowerBound])
        let name = Canonicaliser.canonical(String(lower[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        guard Int(label.dropFirst("speaker ".count)) != nil, !name.isEmpty else { return nil }
        return (label, name)
    }

    public static func clarification(label: String, name: String) -> String {
        "\(label.capitalized) is \(name)"
    }

    /// name → the labels that stand for it in transcripts.
    public var aliases: [String: [String]] {
        var out: [String: [String]] = [:]
        for (label, name) in names { out[name, default: []].append(label) }
        return out.mapValues { $0.sorted() }
    }

    public func name(for label: String?) -> String? {
        label.flatMap { names[$0.lowercased()] }
    }
}
