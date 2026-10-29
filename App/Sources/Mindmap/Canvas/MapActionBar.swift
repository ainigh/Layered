import SwiftUI
import Harness

/// The map's actions, floating at its top: Submit (the selected items not yet on the map),
/// Check coverage, Ask me, and a box to ask the model or tell it what to add. What the
/// model adds goes on the map; what it says back as text opens over the map and joins the
/// context as a model item.
struct MapActionBar: View {
    @Bindable var session: MapSession
    @State private var message = ""

    var body: some View {
        let busy = session.running != nil || session.sentenceWalk != nil
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                submit(busy: busy)
                MapToolButton(symbol: "text.badge.checkmark", help: "Check coverage: what the selected context states that the map lacks") { session.checkCoverage() }
                    .disabled(busy)
                MapToolButton(symbol: "questionmark.bubble", help: "Ask me: the model asks about gaps in the selected context") { session.askMe() }
                    .disabled(busy)
                Divider().frame(height: 18).padding(.horizontal, 2)
                TextField("Ask the model, or tell it what to add…", text: $message)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .frame(minWidth: 160, idealWidth: 300, maxWidth: 340)
                    .onSubmit { send(busy: busy) }
                MapToolButton(symbol: "paperplane.fill", help: "Send (↩)") { send(busy: busy) }
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                Menu {
                    Toggle("Submit one sentence at a time", isOn: $session.sentenceMode)
                    Toggle("Ask me reads the context only", isOn: $session.clarifyContextOnly)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.xs)
                .help("Options")
            }
            .padding(.leading, 4)
            .padding(.trailing, Theme.Space.xs)
            .padding(.vertical, 4)
            .floatingBar(in: Capsule())
            if let walk = session.sentenceWalk {
                WalkProgress(session: session, walk: walk)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, Theme.Space.m)
        .padding(.horizontal, Theme.Space.m)
    }

    /// Submit, with how many selected items are waiting to go on the map.
    private func submit(busy: Bool) -> some View {
        let waiting = session.pendingItems.count
        return Button { session.submit() } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "arrow.up.circle.fill")
                Text("Submit")
                if waiting > 0 { Text("\(waiting)").monospacedDigit().opacity(0.85) }
            }
            .font(Theme.label)
            .padding(.horizontal, Theme.Space.s + 2)
            .frame(height: 28)
            .foregroundStyle(waiting > 0 ? Color.white : Color.secondary)
            .background(waiting > 0 ? Theme.accent : Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(waiting == 0 || busy)
        .help(waiting == 0 ? "Every selected item is on the map" : "Put the \(waiting) selected items that are new or edited on the map (⌘↩)")
    }

    private func send(busy: Bool) {
        guard !busy, !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        session.ask(message)
        message = ""
    }
}

/// One sentence at a time: the sentence under consideration, how far along, pause.
struct WalkProgress: View {
    @Bindable var session: MapSession
    let walk: SentenceWalk

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                ProgressView(value: walk.progress).frame(width: 140)
                Text("\(walk.index + 1) of \(walk.sentences.count)").font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                Button(walk.paused ? "Resume" : "Pause") {
                    session.sentenceWalk?.paused.toggle()
                    if session.sentenceWalk?.paused == false { Task { await session.walkSentences() } }
                }
                .controlSize(.small)
                if walk.paused {
                    Button("Stop") { session.sentenceWalk = nil }.controlSize(.small)
                        .help("Stop here; what is not done stays waiting to be submitted")
                }
            }
            if let s = walk.current { Text(s.sentence).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
    }
}
