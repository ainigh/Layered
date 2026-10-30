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

/// The one window: the map fills it, with its action bar at the top and, at the bottom
/// centre, the bar that adds text or audio (or records). The Context list floats over its left side and the details and other panels over its
/// right, each opened from a pill in its top corner (as Notation opens from the bottom
/// left), so the map never moves when a panel opens. A thin status bar below: what the model,
/// a recording or a transcription is doing, and updates.
/// Opening something over the map closes both sides until it closes.
struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        if let session = model.session {
            MapWindow(session: session, model: model)
                .id(ObjectIdentifier(session))
                .navigationTitle(session.title)
        } else {
            ProjectChooser(model: model)
                .navigationTitle("Mindmap")
        }
    }
}

/// Before any map: where the maps live (asked once), then which project to open or make.
/// Each project is a folder in the maps folder with one map; a demo is a project too.
struct ProjectChooser: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let workspace = model.workspace {
                projects(workspace)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
                    Text("Where should your maps live?").font(.title2.weight(.semibold))
                    Text("Choose a folder. Each project gets a folder inside it, with its map, its context and its recordings, so everything stays on this Mac where you can see it.")
                        .font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { model.chooseWorkspace() } label: { Label("Choose a folder…", systemImage: "folder") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Map.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                UpdateStatus(updater: model.updater)
            }
        }
    }

    @ViewBuilder
    private func projects(_ workspace: Workspace) -> some View {
        let all = workspace.projects()
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Projects").font(.title2.weight(.semibold))
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(workspace.root.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Change…") { model.chooseWorkspace() }.buttonStyle(.link)
            }
            .font(Theme.caption)
        }
        HStack(spacing: Theme.Space.s) {
            TextField("New project name", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            Button("Create", action: create).buttonStyle(.borderedProminent)
                .disabled(Workspace.folderName(name).isEmpty)
        }
        if let problem { Text(problem).font(Theme.caption).foregroundStyle(.orange) }
        if !model.working.isEmpty { WorkingList(model: model) }
        if all.isEmpty {
            Text("No projects yet. Name one above, or try a demo.").font(Theme.body).foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
                    ForEach(all) { project in ProjectTile(project: project, working: model.session(workingOn: project) != nil) { model.open(project) } }
                }
                .padding(2)
            }
            .frame(maxHeight: 420)
        }
        HStack(spacing: Theme.Space.s) {
            Text("Try a demo:").font(Theme.caption).foregroundStyle(.secondary)
            ForEach(Demo.Map.allCases, id: \.self) { map in
                Button(map.rawValue.capitalized) { model.openDemo(map) }.controlSize(.small)
            }
        }
    }

    private func create() {
        do {
            try model.createProject(name)
            name = ""
            problem = nil
        } catch {
            problem = (error as? Workspace.Problem)?.description ?? error.localizedDescription
        }
    }
}

/// Every project working now (the model, a transcription, a recording, a sentence walk),
/// each going on whether or not it is open: what it is doing, Open, and Stop where it can.
struct WorkingList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Working now").font(Theme.label).foregroundStyle(.secondary)
            ForEach(model.working) { session in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(session.title).font(Theme.label).lineLimit(1).frame(minWidth: 120, maxWidth: 200, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(session.work) { work in WorkLine(session: session, work: work) }
                    }
                    Spacer(minLength: 0)
                    if session !== model.session {
                        Button("Open") { model.show(session) }.controlSize(.small)
                    }
                }
                .rowCard()
            }
        }
    }
}

/// One thing a project is doing: what, how far or how long, and Stop where it can be stopped.
struct WorkLine: View {
    let session: MapSession
    let work: Work

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: work.symbol).foregroundStyle(Theme.accent).frame(width: 16)
            Text(work.text).lineLimit(1).truncationMode(.middle)
            if let f = work.fraction {
                ProgressView(value: f).frame(width: 60).controlSize(.mini)
            } else if let since = work.since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))").monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.mini)
            }
            switch work.id {
            case "model", "walk":
                Button("Stop") { session.stop() }.controlSize(.mini).disabled(work.id == "model" && session.cancelRun == nil)
            case "recording":
                Button("Stop") { session.stopRecording() }.controlSize(.mini).disabled(session.recording?.stopping == true && session.recording?.live != true)
            default:
                EmptyView()
            }
        }
        .font(Theme.caption)
    }
}

/// Other projects working in the background, at the status bar's end: click for the list.
struct BackgroundWork: View {
    @Bindable var model: AppModel
    @State private var showing = false

    var body: some View {
        let others = model.working.filter { $0 !== model.session }
        if !others.isEmpty {
            Button { showing.toggle() } label: {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView().controlSize(.mini)
                    Text(others.count == 1 ? "\(others[0].title) is working" : "\(others.count) other projects working").lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Projects working in the background")
            .popover(isPresented: $showing, arrowEdge: .top) {
                WorkingList(model: model).padding(Theme.Space.m).frame(minWidth: 420)
            }
        }
    }
}

/// One project in the chooser's grid: click to open it. One working in the background shows a spinner.
struct ProjectTile: View {
    let project: Workspace.Project
    var working = false
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Image(systemName: project.isDemo ? "play.rectangle" : "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                    if working { ProgressView().controlSize(.small).help("Working") }
                }
                Spacer(minLength: 0)
                Text(project.name).font(Theme.label).lineLimit(2).multilineTextAlignment(.leading)
                Group {
                    if project.modified > .distantPast {
                        Text(project.modified, format: .relative(presentation: .named))
                    } else {
                        Text(project.isDemo ? "Demo" : "Empty")
                    }
                }
                .font(Theme.caption).foregroundStyle(.secondary)
            }
            .padding(Theme.Space.m - 4)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(hover ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(hover ? Theme.accent.opacity(0.5) : Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.selection, value: hover)
        .help("Open \(project.name)")
    }
}

/// The open project in the toolbar: switch to another, or go back to the list to make one.
struct ProjectMenu: View {
    @Bindable var session: MapSession
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            if let workspace = model.workspace {
                ForEach(workspace.projects().prefix(12)) { project in
                    Button(project.name) { model.open(project) }.disabled(project.name == session.title)
                }
                Divider()
            }
            Button("All projects…") { model.showProjects() }
            Button("Choose maps folder…") { model.chooseWorkspace() }
        } label: {
            Label(session.title, systemImage: "folder").labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("The project open: switch to another or make a new one (⌘O)")
    }
}

struct MapWindow: View {
    @Bindable var session: MapSession
    @Bindable var model: AppModel
    /// Where panels and bars float over the map: the wheel there scrolls them, not the map.
    @State private var shields: [CGRect] = []

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CanvasView(session: session, shields: shields)
                    .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
                        handleDrop(providers)
                    }
                NotationDrawer(session: session, model: model)
                ModelLogDrawer(session: session, model: model)
                side(.leading)
                side(.trailing)
                MapActionBar(session: session)
                CaptureBar(session: session)
                if let overlay = session.overlay {
                    MapOverlay(session: session, overlay: overlay)
                        .shieldsMapScroll()
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: MapScroll.space)
            .onPreferenceChange(MapScroll.Shields.self) { shields = $0 }
            .frame(minWidth: 480)
            StatusBar(session: session, model: model)
        }
        .animation(Theme.slide, value: session.overlay)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ProjectMenu(session: session, model: model)
            }
            ToolbarItem(placement: .principal) {
                ModelPicker(session: session) { withAnimation(Theme.slide) { model.show(.settings, session: session) } }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let running = session.running {
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text(running.rawValue.capitalized).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    Button { session.stop() } label: { Label("Stop", systemImage: "stop.circle") }
                        .help("Stop the model (⌘.)")
                        .disabled(session.cancelRun == nil)
                }
                Button { session.selection.forEach { session.expand($0) } } label: { Label("Expand", systemImage: "sparkles") }
                    .help("Expand the selected nodes (⌘E)")
                    .disabled(session.selection.isEmpty || session.running != nil)
            }
            // Updates at the top right, last of all.
            ToolbarItem(placement: .primaryAction) {
                UpdateStatus(updater: model.updater)
            }
        }
        .onChange(of: session.detailsRequests) { _, _ in
            // The ⓘ beside a selected node opens its details; selecting alone stays on the map.
            withAnimation(Theme.slide) { model.show(.details, session: session) }
        }
        .onChange(of: session.contextRequests) { _, _ in
            // A new item from the Add panel: Context opens on it, with its send button.
            withAnimation(Theme.slide) { model.show(.context, session: session) }
        }
        .onChange(of: session.selectedEdge) { _, edge in
            if edge != nil { withAnimation(Theme.slide) { model.show(.details, session: session) } }
        }
        .onChange(of: session.overlay) { old, new in
            if old == nil, new != nil { model.coverPanes() } else if old != nil, new == nil { model.uncoverPanes() }
        }
    }

    /// How far the right-hand panels stop above the map's bottom: spacing over zoom, with room around it.
    static let zoomColumnClearance: CGFloat = {
        let column: CGFloat = ZoomBar.height + SpacingBar.height + Theme.Space.s
        return column + Theme.Space.m + Theme.Space.m
    }()

    /// One side's pill in its top corner and, when open, its panel floating below it. The
    /// panels stop short of what sits in the bottom corners (Notation; spacing over zoom).
    private func side(_ edge: PanelPlacement.Edge) -> some View {
        let leading = edge == .leading
        return VStack(alignment: leading ? .leading : .trailing, spacing: Theme.Space.s) {
            PanePill(edge: edge, session: session, model: model)
            if let panel = model.shownPanels[edge] {
                SidePane(edge: edge, panel: panel, session: session, model: model) { panelBody(panel) }
                    .transition(.move(edge: leading ? .leading : .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, leading ? 62 : Self.zoomColumnClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leading ? .topLeading : .topTrailing)
    }

    @ViewBuilder
    private func panelBody(_ panel: Panel) -> some View {
        switch panel {
        case .context: ContextPanel(session: session)
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
                        if AudioOverlay.kinds.contains(url.pathExtension.lowercased()) {
                            session.dropAudio(url)
                            session.overlay = .audio
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

/// One side's panel, floating over the map: on the right a tab strip of its panels, then
/// the shown panel. The inner edge drags to resize.
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
            if edge == .leading { resizeHandle(placement) }
        }
        .background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
        .shieldsMapScroll()
    }

    private func resizeHandle(_ placement: PanelPlacement) -> some View {
        Rectangle()
            .fill(Color.clear)
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

/// A side's button in its top corner: the panel it opens (or closes), like the Notation
/// pill in the bottom left. The Context pill counts the items not yet on the map.
struct PanePill: View {
    let edge: PanelPlacement.Edge
    @Bindable var session: MapSession
    @Bindable var model: AppModel

    var body: some View {
        let open = model.shownPanels[edge] != nil
        let panel = model.panel(for: edge)
        let waiting = edge == .leading ? session.pendingItems.count : 0
        Button {
            withAnimation(Theme.slide) { model.togglePane(edge, session: session) }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: panel.symbol)
                Text(panel.title)
                if waiting > 0 { Text("· \(waiting) new").foregroundStyle(.secondary) }
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(Theme.label)
            .padding(.horizontal, Theme.Space.m - 4)
            .frame(height: 30)
            .floatingBar(in: Capsule())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide \(panel.title)" : edge == .leading ? "Show the context" : "Show \(panel.title) and the other panels")
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
            if let recording = session.recording {
                RecordingStatus(session: session, recording: recording)
            }
            if let walk = session.sentenceWalk {
                WalkStatus(session: session, walk: walk)
            }
            if let running = session.running {
                RunStatus(session: session, kind: running)
            }
            if let job = session.audioJob, job.running {
                Button { session.overlay = .audio } label: {
                    HStack(spacing: Theme.Space.xs) {
                        if let f = job.fraction { ProgressView(value: f).frame(width: 64).controlSize(.mini) } else { ProgressView().controlSize(.mini) }
                        Text("Transcribing \(job.file.lastPathComponent)").lineLimit(1).truncationMode(.middle).frame(maxWidth: 200)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show its steps")
            }
            let c = session.coverage
            Label("\(c.unsupportedNodes.count)", systemImage: "circle.dashed").help("Ideas no sentence supports")
            Label("\(c.uncoveredSentences.count)", systemImage: "text.badge.xmark").help("Sentences with no idea on the map")
            Label("Local only", systemImage: "lock.fill").foregroundStyle(.green).help("Nothing leaves this Mac")
            BackgroundWork(model: model)
            AppearanceToggle()
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

/// What the model is working on, for how long, and Stop (⌘.; what it sent so far is dropped).
struct RunStatus: View {
    @Bindable var session: MapSession
    let kind: PromptKind

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ProgressView().controlSize(.mini)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = session.runningSince.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
                Text("\(kind.rawValue.capitalized) · \(seconds / 60):\(String(format: "%02d", seconds % 60)) · ~\(session.runningTokens) tokens").monospacedDigit()
            }
            Button("Stop") { session.stop() }
                .controlSize(.small)
                .keyboardShortcut(".", modifiers: .command)
                .disabled(session.cancelRun == nil)
                .help("Stop the model; what it sent so far is dropped (⌘.)")
        }
    }
}

/// One sentence at a time: how far along, the sentence under consideration, pause.
struct WalkStatus: View {
    @Bindable var session: MapSession
    let walk: SentenceWalk

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ProgressView(value: walk.progress).frame(width: 64).controlSize(.mini)
            Text("\(walk.again ? "Checking sentence" : "Sentence") \(walk.index + 1) of \(walk.sentences.count)").monospacedDigit()
                .help(walk.current?.sentence ?? "")
            Button(walk.paused ? "Resume" : "Pause") {
                session.sentenceWalk?.paused.toggle()
                if session.sentenceWalk?.paused == false { Task { await session.walkSentences() } }
            }
            .controlSize(.small)
            // Paused while a sentence is with the model: it finishes first, then Resume goes on.
            .disabled(walk.paused && session.running != nil)
            if walk.paused {
                Button("Stop") { session.sentenceWalk = nil }.controlSize(.small)
                    .help("Stop here; what is not done stays waiting to be sent")
            }
        }
    }
}

/// A recording under way: how long, how loud, what it is doing, the last words a live one
/// heard, and Stop.
struct RecordingStatus: View {
    @Bindable var session: MapSession
    let recording: Recording

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(recording.started)))
                let what = recording.live ? "Live map" : "Recording"
                HStack(spacing: Theme.Space.xs) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                        .opacity(recording.stopping || seconds % 2 == 0 ? 1 : 0.35)
                    Text("\(what) \(seconds / 60):\(String(format: "%02d", seconds % 60))").monospacedDigit()
                    LevelMeter(level: recording.stopping ? 0 : session.recordingLevel)
                }
            }
            if let status = recording.status { Text(status).lineLimit(1) }
            if recording.live, !recording.texts.isEmpty { Text("· \(recording.texts.count) on the map") }
            if recording.live, let last = recording.heard.last {
                Text("“\(last)”").italic().lineLimit(1).truncationMode(.head).frame(maxWidth: 220, alignment: .leading)
                    .help(recording.heard.suffix(4).joined(separator: " "))
            }
            Button(recording.stopping ? "Stop now" : "Stop") { session.stopRecording() }
                .controlSize(.small)
                .disabled(recording.cancelled || (recording.stopping && !recording.live))
                .help(recording.stopping ? "Stop now: what is not on the map yet stays in the recording, unmapped" : recording.live ? "Stop recording; what was said last still goes on the map" : "Stop recording and transcribe it")
        }
    }
}

/// Updates, at the end of the status bar: check, install what was found, or what went wrong.
/// Light, dark, or as the Mac is, in the status bar.
struct AppearanceToggle: View {
    @AppStorage(Appearance.key) private var appearance: Appearance = .system

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(Appearance.allCases) { Image(systemName: $0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        .help("Appearance: \(appearance.title) (system, light, dark)")
        .onChange(of: appearance) { _, chosen in chosen.apply() }
    }
}

/// Checking for, installing or retrying an update, at the top right of the window.
struct UpdateStatus: View {
    let updater: Updater

    var body: some View {
        Group {
            if Updater.canUpdate {
                switch updater.state {
                case .idle, .upToDate:
                    Button { updater.check(userInitiated: true) } label: {
                        Label(updater.state == .upToDate ? "Up to date" : "Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help(updater.state == .upToDate ? "\(updater.versionLine). Click to check again" : updater.versionLine)
                case .checking:
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("Checking for updates…")
                    }
                case let .available(plan):
                    Button { updater.confirmInstall() } label: { Label(plan.title + "…", systemImage: "arrow.down.circle.fill") }
                        .foregroundStyle(Theme.accent)
                        .help("Review the update; nothing installs until you say so")
                case let .installing(step):
                    HStack(spacing: Theme.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text(step).lineLimit(1).frame(maxWidth: 220)
                    }
                case let .failed(message):
                    Menu {
                        Text(message)
                        Button("Try again") { updater.check(userInitiated: true) }
                        Button("Copy error report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Updater.report(message), forType: .string)
                        }
                    } label: {
                        Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    .help(message)
                }
            } else {
                Text(updater.versionLine).lineLimit(1).foregroundStyle(.secondary)
            }
        }
        .font(Theme.caption)
        .labelStyle(.titleAndIcon)
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
