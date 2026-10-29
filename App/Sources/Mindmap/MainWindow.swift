import SwiftUI
import Harness
import UniformTypeIdentifiers

enum Panel: String, CaseIterable, Identifiable {
    case context, details, outline, history, prompt, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .context: return "doc.text"
        case .details: return "info.circle"
        case .outline: return "list.bullet.indent"
        case .prompt: return "text.quote"
        case .settings: return "gearshape"
        case .history: return "clock.arrow.circlepath"
        }
    }

    /// The left pane holds the context and nothing else; every other panel opens on the right.
    var edge: PanelPlacement.Edge { self == .context ? .leading : .trailing }

    var defaultWidth: Double { self == .prompt || self == .settings ? 400 : 340 }
}

/// The one window: the map in the middle with its action bar, the Context list on the
/// left, the selected node's details and the other panels on the right, a thin status bar
/// below. Opening something over the map closes both sides until it closes.
struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        if let session = model.session {
            MapWindow(session: session, model: model)
                .id(ObjectIdentifier(session))
                .navigationTitle(session.title)
                .preferredColorScheme(session.settings.theme == "light" ? .light : session.settings.theme == "dark" ? .dark : nil)
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
            HStack(spacing: 0) {
                pane(.leading)
                ZStack {
                    CanvasView(session: session)
                        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
                            handleDrop(providers)
                        }
                    HeldBackDrawer(session: session)
                    MapActionBar(session: session)
                    if let overlay = session.overlay {
                        MapOverlay(session: session, overlay: overlay)
                            .transition(.opacity)
                    }
                }
                .frame(minWidth: 360)
                pane(.trailing)
            }
            StatusBar(session: session, model: model)
        }
        .animation(Theme.slide, value: session.overlay)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.togglePane(.leading, session: session) } label: { Label("Context", systemImage: "sidebar.left") }
                    .help("Show or hide the context")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let running = session.running {
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text(running.rawValue.capitalized).font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                Button { session.selection.forEach { session.expand($0) } } label: { Label("Expand", systemImage: "sparkles") }
                    .help("Expand the selected nodes (⌘E)")
                    .disabled(session.selection.isEmpty || session.running != nil)
                Button { model.togglePane(.trailing, session: session) } label: { Label("Right pane", systemImage: "sidebar.right") }
                    .help("Show or hide the details and other panels")
            }
        }
        .onChange(of: session.selection) { _, selection in
            // Clicking a node opens its details on the right.
            if !selection.isEmpty { withAnimation(Theme.slide) { model.show(.details, session: session) } }
        }
        .onChange(of: session.selectedEdge) { _, edge in
            if edge != nil { withAnimation(Theme.slide) { model.show(.details, session: session) } }
        }
        .onChange(of: session.overlay) { old, new in
            if old == nil, new != nil { model.coverPanes() } else if old != nil, new == nil { model.uncoverPanes() }
        }
    }

    @ViewBuilder
    private func pane(_ edge: PanelPlacement.Edge) -> some View {
        if let panel = model.shownPanels[edge] {
            SidePane(edge: edge, panel: panel, session: session, model: model) { panelBody(panel) }
                .transition(.move(edge: edge == .leading ? .leading : .trailing))
        }
    }

    @ViewBuilder
    private func panelBody(_ panel: Panel) -> some View {
        switch panel {
        case .context: ContextPanel(session: session, addAudio: { model.pickAudio() })
        case .details: DetailsPanel(session: session)
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
                            model.show(.context, session: session)
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

extension MapSession {
    /// Where a panel sits: its side, and the width the user dragged it to (or its default).
    func placement(_ panel: Panel) -> PanelPlacement {
        var p = ui.panels[panel.rawValue] ?? PanelPlacement()
        if ui.panels[panel.rawValue] == nil { p.width = panel.defaultWidth }
        p.edge = panel.edge
        return p
    }

    func setPlacement(_ panel: Panel, _ p: PanelPlacement) {
        ui.panels[panel.rawValue] = p
        saveUI()
    }
}

/// One side of the window: on the right a tab strip of its panels, then the shown panel.
/// The inner edge drags to resize.
struct SidePane<Content: View>: View {
    let edge: PanelPlacement.Edge
    let panel: Panel
    @Bindable var session: MapSession
    @Bindable var model: AppModel
    @ViewBuilder let content: () -> Content
    @State private var dragWidth: Double?

    var body: some View {
        let placement = session.placement(panel)
        let width = dragWidth ?? placement.width
        HStack(spacing: 0) {
            if edge == .trailing { resizeHandle(placement) }
            VStack(spacing: 0) {
                if edge == .trailing {
                    PaneTabs(edge: edge, selected: panel, session: session, model: model)
                    Divider()
                }
                PanelContainer(title: panel.title, symbol: panel.symbol,
                               onClose: { withAnimation(Theme.slide) { model.hidePane(edge) } },
                               content: content)
            }
            .frame(width: width)
            .background(.background)
            if edge == .leading { resizeHandle(placement) }
        }
    }

    private func resizeHandle(_ placement: PanelPlacement) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 7).contentShape(Rectangle()).onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            })
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let delta = edge == .leading ? value.translation.width : -value.translation.width
                    dragWidth = min(640, max(260, placement.width + delta))
                }
                .onEnded { _ in
                    var p = placement
                    p.width = dragWidth ?? p.width
                    session.setPlacement(panel, p)
                    dragWidth = nil
                })
    }
}

/// The icons of the panels docked on one side; the shown one is filled with the accent.
struct PaneTabs: View {
    let edge: PanelPlacement.Edge
    let selected: Panel
    @Bindable var session: MapSession
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Panel.allCases.filter { $0.edge == edge }) { panel in
                MapToolButton(symbol: panel.symbol, help: panel.title, pressed: panel == selected) {
                    withAnimation(Theme.selection) { model.show(panel, session: session) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs + 2)
    }
}

/// The shared panel chrome: a title row with the panel's menu, then its body (SPEC: new
/// panels add no new chrome).
struct PanelContainer<Content: View>: View {
    let title: String
    let symbol: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text(title).font(Theme.title)
                Spacer()
                Menu {
                    Button("Close Pane", action: onClose)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Panel options")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
            content()
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The “what was held back” pill and drawer, in the map's bottom left corner.
struct HeldBackDrawer: View {
    @Bindable var session: MapSession
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Spacer()
            if open, !session.state.heldBack.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
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
                .frame(width: 420)
                .frame(maxHeight: 240)
                .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !session.state.heldBack.isEmpty {
                Button {
                    withAnimation(Theme.slide) { open.toggle() }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "tray.full")
                        Text("\(session.state.heldBack.count) held back")
                        Image(systemName: open ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .bold))
                    }
                    .font(Theme.label)
                    .padding(.horizontal, Theme.Space.m - 4)
                    .frame(height: 30)
                    .floatingBar(in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Lines the gate changed or kept back")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(Theme.Space.m)
    }
}

struct StatusBar: View {
    @Bindable var session: MapSession
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Label(session.title, systemImage: session.isDemo ? "play.rectangle" : "folder").lineLimit(1)
            Label(session.settings.model.model ?? "no model", systemImage: "cpu").lineLimit(1)
            if let run = session.state.lastRun, let p = run.promptTokens {
                Text("\(p) + \(run.responseTokens ?? 0) tokens")
            }
            let graph = session.state.graph
            Text("\(graph.nodes.count) ideas · \(graph.edges.count) links")
            Spacer(minLength: Theme.Space.s)
            if !session.pendingWrites.isEmpty {
                Button { session.retryPendingWrites() } label: { Label("Folder unreachable: \(session.pendingWrites.count) lines kept in memory · Retry", systemImage: "exclamationmark.triangle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.orange)
            }
            if let error = session.lastError {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    Text(error.message)
                    Text(error.raw).font(Theme.caption.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: 260)
                    if let retry = error.retry { Button("Retry", action: retry).controlSize(.small) }
                }
            }
            if let running = session.running {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView().controlSize(.mini)
                    Text("\(running.rawValue.capitalized) · ~\(session.runningTokens) tokens")
                    if let cancel = session.cancelRun { Button("Cancel", action: cancel).controlSize(.small) }
                }
            }
            if let p = session.transcribing {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView(value: p).frame(width: 64).controlSize(.mini)
                    Text("Transcribing")
                }
            }
            let c = session.coverage
            Label("\(c.unsupportedNodes.count)", systemImage: "circle.dashed").help("Ideas no sentence supports")
            Label("\(c.uncoveredSentences.count)", systemImage: "text.badge.xmark").help("Sentences with no idea on the map")
            Label("Local only", systemImage: "lock.fill").foregroundStyle(.green).help("Nothing leaves this Mac")
        }
        .labelStyle(StatusLabelStyle())
        .font(Theme.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Icon and title close together, the icon a step quieter.
struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small).opacity(0.8)
            configuration.title
        }
    }
}
