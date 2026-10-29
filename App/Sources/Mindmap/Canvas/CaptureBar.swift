import SwiftUI
import Harness

/// The bar at the bottom centre of the map: what goes into the context, and what the model
/// is working on just above it.
///
///   Text or audio   opens the Add panel over the map: paste or type an item, or drop a recording
///   Record          records the microphone; when it stops it is transcribed into an item
///   Live map        records, and every few seconds what was said is transcribed, added as an
///                   item and put on the map, while the recording goes on
///
/// Everything added lands in Context as an item, sent to the map from its own button.
struct CaptureBar: View {
    @Bindable var session: MapSession

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if let running = session.running {
                RunProgress(session: session, kind: running)
            }
            if let walk = session.sentenceWalk {
                WalkProgress(session: session, walk: walk)
            }
            if let job = session.audioJob, job.running {
                TranscribingNote(session: session, job: job)
            }
            if let recording = session.recording {
                RecordingNote(session: session, recording: recording)
            }
            HStack(spacing: Theme.Space.xs) {
                CaptureButton(symbol: "plus", title: "Text or audio", help: "Add text or a recording as an item in Context") {
                    session.overlay = .text
                }
                Divider().frame(height: 18).padding(.horizontal, 2)
                CaptureButton(symbol: "mic.fill", title: "Record", help: "Record from the microphone; when you stop, it is transcribed on this Mac into an item", lit: session.recording?.live == false) {
                    session.startRecording(live: false)
                }
                .disabled(session.recording != nil || session.audioJob?.running == true)
                CaptureButton(symbol: "waveform.and.mic", title: "Live map", help: "Record and map as you talk: every few seconds what was said is transcribed, added to Context and put on the map, while the recording goes on", lit: session.recording?.live == true) {
                    session.startRecording(live: true)
                }
                .disabled(session.recording != nil)
            }
            .padding(4)
            .floatingBar(in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, Theme.Space.m)
        .padding(.horizontal, Theme.Space.m)
    }
}

/// A labelled button on the capture bar; `lit` while what it started is running.
struct CaptureButton: View {
    let symbol: String
    let title: String
    let help: String
    var lit = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Theme.label)
                .padding(.horizontal, Theme.Space.s + 2)
                .frame(height: 28)
                .foregroundStyle(lit ? Color.white : hover ? Color.primary : Color.secondary)
                .background(lit ? Color.red : hover ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled || lit ? 1 : 0.4)
        .help(help)
        .onHover { hover = $0 }
        .animation(Theme.selection, value: hover)
    }
}

/// A recording under way: how long, how loud, what a live one has heard, and Stop.
struct RecordingNote: View {
    @Bindable var session: MapSession
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(recording.started)))
                    HStack(spacing: Theme.Space.s) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                            .opacity(recording.stopping || seconds % 2 == 0 ? 1 : 0.35)
                        Text(recording.live ? "Live map" : "Recording").font(Theme.label)
                        Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))").font(Theme.caption).monospacedDigit().foregroundStyle(.secondary)
                        LevelMeter(level: recording.stopping ? 0 : session.recordingLevel)
                    }
                }
                if let status = recording.status {
                    Text(status).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if recording.live, !recording.texts.isEmpty {
                    Text("· \(recording.texts.count) on the map").font(Theme.caption).foregroundStyle(.secondary)
                }
                Button { session.stopRecording() } label: { Label(recording.stopping ? "Finishing" : "Stop", systemImage: "stop.fill") }
                    .controlSize(.small)
                    .disabled(recording.stopping)
                    .help(recording.live ? "Stop recording; what was said last still goes on the map" : "Stop recording and transcribe it")
            }
            if recording.live, let last = recording.heard.suffix(2).joined(separator: " ").nilIfEmpty {
                Text(last).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 420, alignment: .leading)
            }
        }
        .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.xs).padding(.vertical, Theme.Space.xs + 2)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
    }
}

/// How loud the microphone is now: five bars.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(i) < level * 5 ? Color.green : Color.primary.opacity(0.15))
                    .frame(width: 3, height: 6 + CGFloat(i) * 2)
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

/// A recording being transcribed into an item; opens its steps.
struct TranscribingNote: View {
    @Bindable var session: MapSession
    let job: AudioJob

    var body: some View {
        Button { session.overlay = .audio } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "waveform").foregroundStyle(Theme.origin(.audio).color)
                Text("Transcribing \(job.file.lastPathComponent)").font(Theme.caption).lineLimit(1)
                if let f = job.fraction { ProgressView(value: f).controlSize(.small).frame(width: 80) } else { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.xs + 2)
            .floatingBar(in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show its steps")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
