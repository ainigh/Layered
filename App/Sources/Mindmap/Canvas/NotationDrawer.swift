import SwiftUI
import Harness

/// The drawer in the map's bottom left corner. Its first tab is the map written in the
/// notation (its canonical form), editable: when you pause typing, what the text says is
/// applied to the map as a user turn (append-only, so History can undo it); text that does
/// not compile changes nothing and says which line and why. Its second tab is what the gate
/// held back from the model's last turn, so nothing the model wrote is silently altered.
/// Optimize, at its top right, rewrites the log as the canonical form (the old log is
/// archived) and tidies the text to match.
struct NotationDrawer: View {
    @Bindable var session: MapSession
    @Bindable var model: AppModel
    @State private var tab: Tab = .notation
    /// Bumped by Optimize; the editor applies what is waiting, optimizes and reloads.
    @State private var optimizeRequests = 0

    enum Tab: Hashable { case notation, heldBack }

    var body: some View {
        let held = session.state.heldBack.count
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Spacer()
            if model.notationOpen {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Picker("", selection: $tab) {
                            Text("Notation").tag(Tab.notation)
                            Text(held > 0 ? "Held back · \(held)" : "Held back").tag(Tab.heldBack)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Button {
                            tab = .notation
                            optimizeRequests += 1
                        } label: { Label("Optimize", systemImage: "wand.and.rays") }
                            .controlSize(.small)
                            .help("Rewrite the log as the map's canonical text: one line per fact, sorted (the old log is archived; \(session.state.logSize.lines) lines now, \(session.state.canonicalSize.lines) after)")
                    }
                    .padding(Theme.Space.s)
                    Divider()
                    switch tab {
                    case .notation: NotationEditor(session: session, optimizeRequests: optimizeRequests)
                    case .heldBack: HeldBackList(session: session)
                    }
                }
                .frame(width: 500, height: 360)
                .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button {
                model.toggleNotation()
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("Notation")
                    if held > 0 { Text("· \(held) held back").foregroundStyle(.secondary) }
                    Image(systemName: model.notationOpen ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .bold))
                }
                .font(Theme.label)
                .padding(.horizontal, Theme.Space.m - 4)
                .frame(height: 30)
                .floatingBar(in: Capsule())
            }
            .buttonStyle(.plain)
            .help("The map as text: edit it and the map follows")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(Theme.Space.m)
    }
}

/// The map's canonical text, edited in place. The text keeps what you typed (no reflow
/// under the cursor); it reloads from the map only when the map changes and you have
/// nothing waiting to apply.
struct NotationEditor: View {
    @Bindable var session: MapSession
    var optimizeRequests = 0
    /// What the last Optimize did, until the next edit.
    @State private var optimized: String?
    @State private var draft = ""
    /// The text last loaded from the map, to tell your typing from a reload.
    @State private var loaded = ""
    /// The map the text was taken from: your edit is the difference from it, applied on
    /// top of whatever the map gained since.
    @State private var base = Graph()
    @State private var pending = false
    @State private var problem: NotationError?
    @State private var debounce: Task<Void, Never>?
    @State private var turns = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.85))
            Divider()
            HStack(spacing: Theme.Space.s) {
                if let problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem.description).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Revert to the map", action: reload).controlSize(.small)
                } else if pending {
                    ProgressView().controlSize(.mini)
                    Text("Applies when you pause typing…").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else if let optimized {
                    Image(systemName: "wand.and.rays").foregroundStyle(.secondary)
                    Text(optimized).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text(turns == 0 ? "Edit the text and the map follows. Each change is a turn History can undo." : "Applied to the map · \(turns) edit\(turns == 1 ? "" : "s") this time")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .font(Theme.caption)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 30)
        }
        .onAppear(perform: reload)
        .onDisappear {
            // Closing with an edit waiting applies it rather than dropping it.
            debounce?.cancel()
            if pending { apply() }
        }
        .onChange(of: optimizeRequests) { _, _ in optimize() }
        .onChange(of: draft) { _, text in
            guard text != loaded else { return }
            optimized = nil
            pending = true
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { apply() }
            }
        }
        .onChange(of: session.state.canonical) { _, canonical in
            // Our own edit leaves the map saying what the text says: keep the text as typed.
            guard !pending, canonical != Canonical.render(base) else { return }
            reload()
        }
    }

    private func reload() {
        debounce?.cancel()
        loaded = session.state.canonical
        draft = loaded
        base = session.state.graph
        pending = false
        problem = nil
    }

    /// Applies what is waiting (unless it does not compile), rewrites the log as the
    /// canonical form, and tidies the text to it.
    private func optimize() {
        debounce?.cancel()
        if pending { apply() }
        guard problem == nil else { return }
        let before = session.state.logSize.lines
        session.optimize()
        reload()
        let after = session.state.logSize.lines
        optimized = before == after ? "Already optimal: \(after) lines" : "Optimized: \(before) → \(after) lines (the old log is archived)"
    }

    private func apply() {
        switch NotationEdit.compile(draft) {
        case .failure(let error):
            problem = error
        case .success(let target):
            problem = nil
            let lines = NotationEdit.lines(from: base, to: target)
            base = target
            pending = false
            if !lines.isEmpty {
                session.dispatch(.applyLines(lines, what: "edit notation"))
                turns += 1
            }
        }
    }
}

/// What the gate changed or kept back from the model's last turn, with Apply for suggestions.
struct HeldBackList: View {
    @Bindable var session: MapSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if session.state.heldBack.isEmpty {
                    Text("Nothing held back: the model's last lines went on the map as written.").font(Theme.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(session.state.heldBack.enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(event.kind.rawValue)
                                .font(Theme.caption.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background((event.kind == .dropped ? Color.red : Color.secondary).opacity(0.15), in: Capsule())
                                .foregroundStyle(event.kind == .dropped ? Color.red : Color.secondary)
                            Text(event.raw).font(Theme.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                        Text(event.reason).font(Theme.caption).foregroundStyle(.secondary)
                        if !event.result.isEmpty {
                            Text(event.result.joined(separator: "\n")).font(Theme.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                        if event.kind == .deferred {
                            Button("Apply") { session.dispatch(.applyLines(event.result, what: "suggestion")) }.controlSize(.small)
                        }
                    }
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
