import Foundation
import AVFoundation
import Harness
import whisper

/// Transcribes on the machine with whisper.cpp (Metal). The model is downloaded on first
/// use to the app's support folder. Output is segments with start and end times.
struct WhisperTranscriber: Transcriber {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mindmap/whisper")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    func transcribe(_ audio: URL, model: String, progress: @escaping @Sendable (TranscriptionStep) -> Void) async throws -> Transcript {
        let modelURL = try await WhisperModels.ensure(model, progress: { progress(.downloadingModel(model, $0)) })
        progress(.decoding)
        let samples = try await Task.detached(priority: .userInitiated) { try AudioDecoder.pcm16k(audio) }.value
        progress(.transcribing(0))
        return try await Task.detached(priority: .userInitiated) {
            try WhisperRun.run(modelURL: modelURL, samples: samples, tinydiarize: false, progress: { progress(.transcribing($0)) })
        }.value
    }
}

/// Speaker labels. Tries whisper.cpp's tinydiarize model (two-speaker turn detection);
/// a Core ML pyannote pipeline can replace this behind the same protocol.
struct WhisperDiarizer: Diarizer {
    func diarize(_ transcript: Transcript, audio: URL) async throws -> Transcript {
        guard let modelURL = try? await WhisperModels.ensure("small.en-tdrz", progress: { _ in }) else {
            var t = transcript
            for i in t.segments.indices { t.segments[i].speaker = "Speaker 1" }
            return t
        }
        let samples = try AudioDecoder.pcm16k(audio)
        let turns = try await Task.detached(priority: .userInitiated) {
            try WhisperRun.run(modelURL: modelURL, samples: samples, tinydiarize: true, progress: { _ in })
        }.value
        // Map each original segment to the speaker of the tinydiarize segment that overlaps it most.
        var t = transcript
        for i in t.segments.indices {
            let seg = t.segments[i]
            let best = turns.segments.max { overlap($0, seg) < overlap($1, seg) }
            t.segments[i].speaker = best?.speaker ?? "Speaker 1"
        }
        return t
    }

    private func overlap(_ a: Transcript.Segment, _ b: Transcript.Segment) -> Double {
        max(0, min(a.t1, b.t1) - max(a.t0, b.t0))
    }
}

enum WhisperModels {
    /// Downloads `ggml-<name>.bin` from Hugging Face on first use, reporting how far along
    /// it is (nil while the size is unknown). Nothing is reported when the model is there.
    static func ensure(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let url = WhisperTranscriber.supportDir.appendingPathComponent("ggml-\(name).bin")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        progress(nil)
        let remote = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")!
        let watcher = DownloadWatcher(progress)
        let (temp, response) = try await URLSession.shared.download(from: remote, delegate: watcher)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ModelError.notConnected("could not download the whisper model \(name) from \(remote.host ?? "huggingface.co")")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        progress(1)
        return url
    }

    /// Watches a download task's progress (the async download call has no progress of its own).
    final class DownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double?) -> Void
        private var observation: NSKeyValueObservation?

        init(_ report: @escaping @Sendable (Double?) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] p, _ in
                report(p.totalUnitCount > 0 ? p.fractionCompleted : nil)
            }
        }
    }
}

/// A whisper model loaded once and kept, for the many short pieces of a live recording
/// (loading a model takes longer than transcribing ten seconds). One piece at a time.
final class WhisperSession: @unchecked Sendable {
    private let ctx: OpaquePointer
    private let modelURL: URL
    private let lock = NSLock()

    init(modelURL: URL) throws {
        ctx = try WhisperRun.load(modelURL)
        self.modelURL = modelURL
    }

    deinit { whisper_free(ctx) }

    func transcribe(_ samples: [Float]) throws -> Transcript {
        lock.lock()
        defer { lock.unlock() }
        return try WhisperRun.full(ctx, modelURL: modelURL, samples: samples, tinydiarize: false, progress: { _ in })
    }
}

enum WhisperRun {
    static func run(modelURL: URL, samples: [Float], tinydiarize: Bool, progress: @escaping (Double) -> Void) throws -> Transcript {
        let ctx = try load(modelURL)
        defer { whisper_free(ctx) }
        return try full(ctx, modelURL: modelURL, samples: samples, tinydiarize: tinydiarize, progress: progress)
    }

    static func load(_ modelURL: URL) throws -> OpaquePointer {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelURL.path, cparams) else {
            throw ModelError.notConnected("whisper could not load \(modelURL.lastPathComponent)")
        }
        return ctx
    }

    static func full(_ ctx: OpaquePointer, modelURL: URL, samples: [Float], tinydiarize: Bool, progress: @escaping (Double) -> Void) throws -> Transcript {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        params.tdrz_enable = tinydiarize
        params.language = nil
        let box = ProgressBox(progress)
        // The box is handed to C unretained; keep it alive for the whole call.
        let status: Int32 = withExtendedLifetime(box) {
            params.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
            params.progress_callback = { _, _, percent, data in
                guard let data else { return }
                Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue().report(Double(percent) / 100)
            }
            return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
        }
        guard status == 0 else { throw ModelError.badResponse(Int(status), "whisper_full failed") }

        var segments: [Transcript.Segment] = []
        var speaker = 1
        for i in 0..<whisper_full_n_segments(ctx) {
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100
            let text = String(cString: whisper_full_get_segment_text(ctx, i)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            segments.append(Transcript.Segment(t0: t0, t1: t1, text: text, speaker: tinydiarize ? "Speaker \(speaker)" : nil))
            if tinydiarize, whisper_full_get_segment_speaker_turn_next(ctx, i) { speaker += 1 }
        }
        let lang = String(cString: whisper_lang_str(whisper_full_lang_id(ctx)))
        return Transcript(segments: segments, language: lang, model: modelURL.deletingPathExtension().lastPathComponent)
    }

    final class ProgressBox {
        let report: (Double) -> Void
        init(_ report: @escaping (Double) -> Void) { self.report = report }
    }
}

/// Decodes any audio file AVFoundation reads into 16 kHz mono float samples.
enum AudioDecoder {
    static func pcm16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw ModelError.badResponse(0, "unsupported audio format")
        }
        let frames = AVAudioFrameCount(file.length)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw ModelError.badResponse(0, "empty audio") }
        try file.read(into: input)
        let ratio = 16000 / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 1024) else { throw ModelError.badResponse(0, "empty audio") }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
