import AVFoundation
import Foundation

/// Records the microphone on this Mac: the audio goes to a file as it comes (what the item
/// plays back, and what is transcribed in one go when it stops) and, for a live map, is kept
/// as 16 kHz mono samples (what whisper reads) until they have been transcribed. Nothing
/// leaves the Mac.
@MainActor
final class LiveRecorder {
    static let rate = 16000

    private let engine = AVAudioEngine()
    private var sink: AudioSink?
    /// The file being written.
    let url: URL
    private(set) var stopped = false

    /// Writes into `folder`: the project's audio folder, so the recording is kept from its
    /// first second, whatever happens to its transcription.
    init(in folder: URL) {
        let stamp = Date().formatted(.dateTime.year().month().day().hour().minute().second())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        url = folder.appendingPathComponent("\(Self.prefix)\(stamp).m4a")
    }

    /// How a recording made here is named until it is transcribed and takes its text id.
    static let prefix = "Recording "

    /// Asks for the microphone the first time; false when the user said no (or said no before).
    static func permission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts recording; with `keepSamples`, the samples stay readable until `discard`.
    func start(keepSamples: Bool) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioJob.Problem("No microphone is connected.") }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.rate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw AudioJob.Problem("The microphone's audio can't be read.") }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sink = AudioSink(converter: converter, target: target, file: file, keepSamples: keepSamples)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(sink))
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.sink = sink
    }

    /// Stops recording and closes the file.
    func stop() {
        guard !stopped else { return }
        stopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink?.close()
    }

    /// Made outside the main actor: the tap runs on an audio thread.
    private nonisolated static func tap(_ sink: AudioSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.receive(buffer) }
    }

    /// How loud the last moment was, 0 to 1, for a meter.
    var level: Float { sink?.level ?? 0 }
    /// Samples recorded so far (counting those already discarded).
    var sampleCount: Int { sink?.count ?? 0 }
    func samples(_ range: Range<Int>) -> [Float] { sink?.samples(range) ?? [] }
    /// Forgets the samples before `index` (they have been transcribed).
    func discard(upTo index: Int) { sink?.discard(upTo: index) }

    /// Where to end a chunk that runs to `end`: the quietest moment of its last second and a
    /// half, so a word is not cut in two.
    func quietCut(from start: Int, to end: Int) -> Int {
        let window = Self.rate / 20
        let from = max(start, end - Self.rate * 3 / 2)
        guard end - from > window * 2 else { return end }
        let tail = samples(from..<end)
        var best = tail.count, quietest = Float.infinity
        var i = 0
        while i + window <= tail.count {
            let energy = Self.rms(tail[i..<(i + window)])
            if energy < quietest { quietest = energy; best = i + window / 2 }
            i += window / 2
        }
        return from + best
    }

    nonisolated static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}

/// Where the tap's audio goes: converted to 16 kHz mono, written to the file, kept for whisper.
/// The tap calls it on the audio thread and the session reads it on the main one, hence the lock.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private var file: AVAudioFile?
    private let keepSamples: Bool
    private var kept: [Float] = []
    /// The index of `kept[0]` among everything recorded.
    private var base = 0
    private var total = 0
    private var lastLevel: Float = 0

    init(converter: AVAudioConverter, target: AVAudioFormat, file: AVAudioFile, keepSamples: Bool) {
        self.converter = converter
        self.target = target
        self.file = file
        self.keepSamples = keepSamples
    }

    func receive(_ input: AVAudioPCMBuffer) {
        let ratio = target.sampleRate / input.format.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 64) else { return }
        var fed = false
        var error: NSError?
        // `noDataNow` (not end of stream) keeps the converter's state from one buffer to the next.
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let data = output.floatChannelData else { return }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: output)
        if keepSamples { kept.append(contentsOf: samples) }
        total += samples.count
        lastLevel = min(1, LiveRecorder.rms(samples) * 4)
    }

    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }

    var level: Float { lock.lock(); defer { lock.unlock() }; return lastLevel }
    var count: Int { lock.lock(); defer { lock.unlock() }; return total }

    func samples(_ range: Range<Int>) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let lo = max(range.lowerBound, base) - base, hi = min(range.upperBound - base, kept.count)
        return lo < hi ? Array(kept[lo..<hi]) : []
    }

    func discard(upTo index: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = min(max(0, index - base), kept.count)
        kept.removeFirst(n)
        base += n
    }
}
