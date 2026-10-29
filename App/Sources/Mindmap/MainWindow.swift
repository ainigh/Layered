import SwiftUI
import Harness
import UniformTypeIdentifiers

enum Panel: String, CaseIterable, Identifiable {
    case context, clarify, proof, chat, outline, prompt, settings, history
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .context: return "doc.text"
        case .clarify: return "questionmark.bubble"
        case .proof: return "checkmark.seal"
        case .chat: return "bubble.left.and.bubble.right"
        case .outline: return "list.bullet.indent"
        case .prompt: return "text.quote"
        case .settings: return "gearshape"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// The one window: the canvas fills it, panels slide in from the edges, a thin status bar below.
struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        if let session = model.session {
            MapWindow(session: session, model: model)
                .navigationTitle(session.title)
        } else {
            ContentUnavailableView("No map open", systemImage: "folder", description: Text("Open a folder or a demo from the menu bar."))
        }
    }
}

struct MapWindow: View {
    @Bindable var session: MapSession
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CanvasView(session: session)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
                        handleDrop(providers)
                    }
                panelsOverlay
                HeldBackDrawer(session: session)
            }
            StatusBar(session: session, model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(Panel.allCases) { panel in
                    Toggle(isOn: Binding(get: { model.openPanels.contains(panel) },
                                         set: { on in withAnimation(Theme.slide) { if on { model.openPanels.insert(panel) } else { model.openPanels.remove(panel) } } })) {
                        Label(panel.title, systemImage: panel.symbol)
                    }
                    .help(panel.title)
                }
            }
        }
        .onAppear {
            session.contextDraft = UserDefaults.standard.string(forKey: "draft:\(session.title)") ?? session.state.context.plainText
            session.submittedDraft = session.contextDraft
        }
    }

    @ViewBuilder
    private var panelsOverlay: some View {
        HStack(spacing: 0) {
            VStack(spacing: Theme.Space.s) { panels(on: .leading) }.frame(maxHeight: .infinity, alignment: .top)
            Spacer()
            VStack(spacing: Theme.Space.s) { panels(on: .trailing) }.frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(Theme.Space.s)
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func panels(on edge: PanelPlacement.Edge) -> some View {
        ForEach(Panel.allCases.filter { model.openPanels.contains($0) && placement($0).edge == edge }) { panel in
            PanelContainer(title: panel.title, symbol: panel.symbol, placement: binding(for: panel), onClose: { model.openPanels.remove(panel) }) {
                panelBody(panel)
            }
            .frame(width: placement(panel).width)
            .transition(.move(edge: edge == .leading ? .leading : .trailing).combined(with: .opacity))
        }
    }

    private func placement(_ panel: Panel) -> PanelPlacement {
        session.ui.panels[panel.rawValue] ?? defaultPlacement(panel)
    }

    private func defaultPlacement(_ panel: Panel) -> PanelPlacement {
        var p = PanelPlacement()
        p.edge = [.context, .clarify, .chat, .outline].contains(panel) ? .leading : .trailing
        p.width = panel == .prompt || panel == .settings ? 420 : 340
        return p
    }

    private func binding(for panel: Panel) -> Binding<PanelPlacement> {
        Binding(get: { placement(panel) }, set: { session.ui.panels[panel.rawValue] = $0; session.saveUI() })
    }

    @ViewBuilder
    private func panelBody(_ panel: Panel) -> some View {
        switch panel {
        case .context: ContextPanel(session: session)
        case .clarify: ClarifyPanel(session: session)
        case .proof: ProofPanel(session: session)
        case .chat: ChatPanel(session: session)
        case .outline: OutlinePanel(session: session)
        case .prompt: PromptPanel(session: session)
        case .settings: SettingsPanel(session: session)
        case .history: HistoryPanel(session: session)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        if ["m4a", "mp3", "wav", "aiff", "caf"].contains(url.pathExtension.lowercased()) {
                            session.dropAudio(url)
                        } else if url.pathExtension == "mm", let text = try? String(contentsOf: url, encoding: .utf8) {
                            session.importMM(text)
                        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                            model.capture(text)
                        }
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    if let text = item as? String ?? (item as? Data).flatMap({ String(data: $0, encoding: .utf8) }) {
                        Task { @MainActor in model.capture(text) }
                    }
                }
                return true
            }
        }
        return false
    }
}

/// The shared panel chrome: header, drag handle, body (SPEC: new panels add no new chrome).
struct PanelContainer<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var placement: PanelPlacement
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol).foregroundStyle(Theme.accent)
                Text(title).font(Theme.label)
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .help("Drag to the other edge")
                    .gesture(DragGesture(minimumDistance: 40).onEnded { value in
                        withAnimation(Theme.slide) { placement.edge = value.translation.width > 0 ? .trailing : .leading }
                    })
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            Divider()
            content()
                .padding(Theme.Space.m)
        }
        .frame(maxHeight: 640, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(.quaternary))
        .shadow(radius: 8, y: 2)
    }
}

/// The “what was held back” drawer on the status bar.
struct HeldBackDrawer: View {
    @Bindable var session: MapSession
    @State private var open = false

    var body: some View {
        VStack {
            Spacer()
            if open, !session.state.heldBack.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(Array(session.state.heldBack.enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                HStack {
                                    Text(event.kind.rawValue).font(Theme.label).foregroundStyle(event.kind == .dropped ? Color.red : Color.secondary)
                                    Text(event.raw).font(Theme.caption.monospaced()).lineLimit(1)
                                }
                                Text(event.reason).font(Theme.caption).foregroundStyle(.secondary)
                                if !event.result.isEmpty {
                                    Text(event.result.joined(separator: "\n")).font(Theme.caption.monospaced()).foregroundStyle(.tertiary)
                                }
                                if event.kind == .deferred {
                                    Button("Apply") { session.dispatch(.applyLines(event.result, what: "suggestion")) }.font(Theme.caption)
                                }
                            }
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .frame(maxHeight: 220)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
                .padding(Theme.Space.s)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                Spacer()
                if !session.state.heldBack.isEmpty {
                    Button {
                        withAnimation(Theme.slide) { open.toggle() }
                    } label: {
                        Label("\(session.state.heldBack.count) held back", systemImage: open ? "chevron.down" : "chevron.up")
                            .font(Theme.caption)
                    }
                    .buttonStyle(.bordered)
                    .padding(Theme.Space.s)
                }
            }
        }
    }
}

struct StatusBar: View {
    @Bindable var session: MapSession
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Label(session.title, systemImage: session.isDemo ? "play.rectangle" : "folder").lineLimit(1)
            Label(session.settings.model.model ?? "no model", systemImage: "cpu")
            if let run = session.state.lastRun, let p = run.promptTokens {
                Text("\(p)+\(run.responseTokens ?? 0) tokens").foregroundStyle(.secondary)
            }
            let c = session.coverage
            Label("\(c.unsupportedNodes.count)", systemImage: "circle.dashed").help("nodes with no sentence support")
            Label("\(c.uncoveredSentences.count)", systemImage: "text.badge.xmark").help("sentences with no node")
            Spacer()
            if !session.pendingWrites.isEmpty {
                Button { session.retryPendingWrites() } label: { Label("Folder unreachable; \(session.pendingWrites.count) lines kept in memory", systemImage: "exclamationmark.triangle") }
                    .buttonStyle(.plain).foregroundStyle(.orange)
            }
            if let error = session.lastError {
                HStack(spacing: Theme.Space.xs) {
                    Text(error.raw).font(Theme.caption.monospaced()).lineLimit(1).foregroundStyle(.red)
                    Text(error.message).font(Theme.caption)
                    if let retry = error.retry { Button("Retry", action: retry).font(Theme.caption) }
                }
            }
            if let running = session.running {
                ProgressView().controlSize(.small)
                Text("\(running.rawValue) · ~\(session.runningTokens) tokens").font(Theme.caption)
                if let cancel = session.cancelRun { Button("Cancel", action: cancel).font(Theme.caption) }
            }
            if let p = session.transcribing {
                ProgressView(value: p).frame(width: 80)
                Text("transcribing").font(Theme.caption)
            }
            Label("local only", systemImage: "lock.shield").foregroundStyle(.green)
        }
        .font(Theme.caption)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(.bar)
    }
}
