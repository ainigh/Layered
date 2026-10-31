import SwiftUI
import Harness

/// The map's actions, floating at its top: Check again, Ask me, a box to ask the model
/// or tell it what to add (items go on the map from their own send button in Context), and
/// two toggles, lit while on: one sentence at a time (on to begin with), and Ask me reads
/// the context only.
/// What the model adds goes on the map at once, flagged for review (✓ keeps it, ✕ deletes
/// it); what it says back as text joins the context as a model item, and a note under the
/// bar says so. What the model is working on shows in the status bar. Nothing opens over
/// the map unless something went wrong.
struct MapActionBar: View {
    @Bindable var session: MapSession
    @State private var message = ""

    var body: some View {
        let busy = session.running != nil || session.sentenceWalk != nil
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                MapToolButton(symbol: "text.badge.checkmark", help: "Check again: every sentence of the selected context goes to the model once more, one at a time with the map; it adds what the map lacks, fixes what is wrong, or writes nothing") { session.checkAgain() }
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
                Divider().frame(height: 18).padding(.horizontal, 2)
                MapToolButton(symbol: "list.number",
                              help: session.sentenceMode ? "One sentence at a time: on. Each sentence goes to the model alone with the whole map, and it writes the lines to append (click to send items all at once, with their text as context)" : "One sentence at a time: off. Items go on the map all at once (click to go sentence by sentence)",
                              pressed: session.sentenceMode) { withAnimation(Theme.selection) { session.sentenceMode.toggle() } }
                MapToolButton(symbol: "doc.text.magnifyingglass",
                              help: session.clarifyContextOnly ? "Ask me reads the context only: on (click to let it read the map too)" : "Ask me reads the context only: off. It reads the map too (click to read the context only)",
                              pressed: session.clarifyContextOnly) { withAnimation(Theme.selection) { session.clarifyContextOnly.toggle() } }
            }
            .padding(.leading, Theme.Space.xs)
            .padding(.trailing, Theme.Space.xs)
            .padding(.vertical, 4)
            .floatingBar(in: Capsule())
            if let error = session.lastError {
                ErrorNote(session: session, message: error.message, raw: error.raw, retry: error.retry)
            }
            if let notice = session.notice {
                NoticeNote(session: session, notice: notice)
            }
            if !session.review.isEmpty, session.viewingTurn == nil {
                ReviewNote(session: session)
            }
        }
        .shieldsMapScroll()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, Theme.Space.m)
        .padding(.horizontal, Theme.Space.m)
    }

    private func send(busy: Bool) {
        guard !busy, !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        session.ask(message)
        message = ""
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
/// again found. It never covers the map.
struct NoticeNote: View {
    @Bindable var session: MapSession
    let notice: Notice

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary)
            Text(notice.text).font(Theme.caption).lineLimit(2).textSelection(.enabled).frame(maxWidth: 420, alignment: .leading)
                .help(notice.text)
            if let id = notice.item {
                Button("Open") { session.notice = nil; session.open(item: id) }.controlSize(.small)
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
                Text(message).font(Theme.label).textSelection(.enabled)
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
