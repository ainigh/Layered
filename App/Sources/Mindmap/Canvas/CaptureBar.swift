import SwiftUI
import Harness

/// The bar at the bottom centre of the map: what goes into the context.
///
///   Text or audio   opens the Add panel over the map: paste or type an item, or drop a recording
///   Record          records the microphone; when it stops it is transcribed into an item
///   Live map        records, and every few seconds what was said is transcribed, added as an
///                   item and put on the map, while the recording goes on
///
/// A recording's button is lit while it runs, and a click on it stops it. How it is going
/// (and what the model is working on) shows in the status bar. Everything added lands in
/// Context as an item, sent to the map from its own button.
struct CaptureBar: View {
    @Bindable var session: MapSession

    var body: some View {
        let recording = session.recording
        HStack(spacing: Theme.Space.xs) {
            CaptureButton(symbol: "plus", title: "Text or audio", help: "Add text or a recording as an item in Context") {
                session.overlay = .text
            }
            Divider().frame(height: 18).padding(.horizontal, 2)
            CaptureButton(symbol: recording?.live == false ? "stop.fill" : "mic.fill", title: "Record",
                          help: recording?.live == false ? "Stop recording and transcribe it" : "Record from the microphone; when you stop, it is transcribed on this Mac into an item",
                          lit: recording?.live == false) {
                if recording?.live == false { session.stopRecording() } else { session.startRecording(live: false) }
            }
            .disabled(recording?.live == true || recording?.stopping == true || (recording == nil && session.audioJob?.running == true))
            CaptureButton(symbol: recording?.live == true ? "stop.fill" : "waveform.and.mic", title: "Live map",
                          help: recording?.live == true ? (recording?.stopping == true ? "Stop now: what is not on the map yet stays in the recording, unmapped" : "Stop the live map; what was said last still goes on the map") : "Record and map as you talk: every few seconds what was said is transcribed, added to Context and put on the map, while the recording goes on",
                          lit: recording?.live == true) {
                if recording?.live == true { session.stopRecording() } else { session.startRecording(live: true) }
            }
            .disabled(recording?.live == false || recording?.cancelled == true)
        }
        .padding(4)
        .floatingBar(in: Capsule())
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
