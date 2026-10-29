import SwiftUI
import Harness

/// The map's actions, floating at its top: Submit (the selected items not yet on the map),
/// Check coverage, Ask me, and a box to ask the model or tell it what to add. What the
/// model adds goes on the map at once, flagged for review (✓ keeps it, ✕ deletes it); what
/// it says back as text joins the context as a model item, and a note under the bar says
/// so. Nothing opens over the map unless something went wrong.
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
                if session.running != nil {
                    MapToolButton(symbol: "stop.fill", help: "Stop the model (⌘.)") { session.stop() }
                } else {
                    MapToolButton(symbol: "paperplane.fill", help: "Send (↩)") { send(busy: busy) }
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
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
            if let running = session.running {
                RunProgress(session: session, kind: running)
            }
            if let error = session.lastError {
                ErrorNote(session: session, message: error.message, raw: error.raw, retry: error.retry)
            }
            if let notice = session.notice {
                NoticeNote(session: session, notice: notice)
            }
            if !session.review.isEmpty, session.viewingTurn == nil {
                ReviewNote(session: session)
            }
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

/// What the model is working on, for how long, and a way to stop it when it takes too long.
struct RunProgress: View {
    @Bindable var session: MapSession
    let kind: PromptKind

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = session.runningSince.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
                Text("\(kind.rawValue.capitalized) · \(seconds / 60):\(String(format: "%02d", seconds % 60)) · ~\(session.runningTokens) tokens")
                    .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .controlSize(.small)
                .keyboardShortcut(".", modifiers: .command)
                .disabled(session.cancelRun == nil)
                .help("Stop the model; what it sent so far is dropped (⌘.)")
        }
        .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.xs).padding(.vertical, Theme.Space.xs)
        .floatingBar(in: Capsule())
    }
}

/// What the model added that is waiting for a decision, and both decisions for all of it.
struct ReviewNote: View {
    @Bindable var session: MapSession

    var body: some View {
        let n = session.review.count
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text(n == 1 ? "1 addition from the model to review" : "\(n) additions from the model to review").font(Theme.caption)
            Button { session.acceptAll() } label: { Label("Accept all", systemImage: "checkmark") }
                .controlSize(.small)
                .help("Keep everything the model added")
            Button(role: .destructive) { session.rejectAll() } label: { Label("Delete all", systemImage: "xmark") }
                .controlSize(.small)
                .help("Take everything waiting for review off the map (one undo brings it back)")
        }
        .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.xs).padding(.vertical, Theme.Space.xs)
        .floatingBar(in: Capsule())
    }
}

/// A word from the model's last turn: a reply that joined the context, or what Check
/// coverage found. It never covers the map.
struct NoticeNote: View {
    @Bindable var session: MapSession
    let notice: Notice

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary)
            Text(notice.text).font(Theme.caption).lineLimit(2).frame(maxWidth: 420, alignment: .leading)
            if let id = notice.item {
                Button("Open") { session.notice = nil; session.open(item: id) }.controlSize(.small)
            }
            if notice.report {
                Button("Report") { session.notice = nil; session.overlay = .coverage }.controlSize(.small)
            }
            Button { session.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.s).padding(.vertical, Theme.Space.xs)
        .floatingBar(in: Capsule())
    }
}

/// A model request that failed, with what it said and Retry.
struct ErrorNote: View {
    @Bindable var session: MapSession
    let message: String
    let raw: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(message).font(Theme.label)
                Text(raw).font(Theme.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            .frame(maxWidth: 420, alignment: .leading)
            if let retry { Button("Retry") { session.lastError = nil; retry() }.controlSize(.small).disabled(session.running != nil) }
            Button { session.lastError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.s).padding(.vertical, Theme.Space.s)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
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
