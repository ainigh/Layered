import SwiftUI
import Harness
import AppKit

@main
struct MindmapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        // The icon and its menu are AppKit's (`StatusBarController`), and so is the window
        // (`AppModel.showWindow`). This scene is never shown; it's here because an app needs one,
        // and it carries the app's menus.
        MenuBarExtra("Mindmap", systemImage: "point.3.connected.trianglepath.dotted", isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.session?.dispatch(.undo) }.keyboardShortcut("z", modifiers: .command)
                Button("Redo") { model.session?.dispatch(.redo) }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Map") {
                Button("New project from clipboard") { model.newFromClipboard() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Projects…") { model.showProjects() }.keyboardShortcut("o", modifiers: .command)
                Button("Choose maps folder…") { model.chooseWorkspace() }
                Button("Transcribe audio file…") { model.pickAudio() }
                Divider()
                Button("Submit") { model.session?.submit() }.keyboardShortcut(.return, modifiers: .command)
                Button("Expand selection") { if let s = model.session { s.selection.forEach { s.expand($0) } } }.keyboardShortcut("e", modifiers: .command)
                Button("Check coverage") { model.session?.checkCoverage() }
                Button("Find duplicates") { model.session?.findDuplicates() }
                Divider()
                Menu("Export") {
                    ForEach(MapSession.ExportFormat.allCases, id: \.self) { f in
                        Button(f.rawValue) { model.export(f) }
                    }
                }
                Button("Import .mm…") { model.importMM() }
            }
        }
    }
}

/// Starts what belongs to the running app (not to previews or tests): the menu bar icon, Ollama,
/// the updater, the capture shortcut.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Appearance.saved.apply()
            AppModel.shared.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let quit = MainActor.assumeIsolated { AppModel.shared.shouldQuit() }
        return quit ? .terminateNow : .terminateCancel
    }
}

/// App-wide state: the maps folder and the open project's session, the window.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var session: MapSession?
    /// Projects left while they were still working (another was opened, or the list, or the
    /// window was closed on them): they carry on, and each is let go once it is done. Opening
    /// one again picks it up where it is.
    var background: [MapSession] = []
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// Set by the updater, which quits to swap the app: no asking then.
    @ObservationIgnored var quittingForUpdate = false
    /// The folder the user keeps their maps in; each folder inside is a project.
    var workspace: Workspace?
    /// The panel each side pane shows; a side with none is closed. One floating panel is
    /// open at a time: a side pane, the Notation drawer or the Model log.
    var shownPanels: [PanelPlacement.Edge: Panel] = [.leading: .context]
    /// The Notation drawer, in the map's bottom left corner, is open.
    var notationOpen = false
    /// The Model log, in the map's bottom right corner beside zoom, is open.
    var logOpen = false
    /// What a closed pane showed last, so opening it again brings that back.
    @ObservationIgnored private var lastShown: [PanelPlacement.Edge: Panel] = [.leading: .context, .trailing: .details]
    /// The panes an overlay closed, to bring back when it closes.
    @ObservationIgnored private var covered: [PanelPlacement.Edge: Panel]?
    let updater = Updater()
    private var ollama = OllamaLauncher()
    private var shortcut: GlobalShortcut?
    @ObservationIgnored private var statusBar: StatusBarController?
    @ObservationIgnored private var window: NSWindow?

    init() {
        workspace = WorkspaceStore.load().flatMap { try? Workspace(root: $0) }
    }

    /// Starts `ollama serve` if Ollama is installed and not answering at `host`.
    func startOllama(host: URL) {
        ollama.startIfInstalled(host: host)
    }

    /// Once the app has launched.
    func start() {
        statusBar = StatusBarController(model: self)
        ollama.startIfInstalled()
        Notifier.shared.start { [weak self] in self?.updater.confirmInstall() }
        updater.start()
        shortcut = GlobalShortcut { [weak self] text in
            Task { @MainActor in self?.capture(text) }
        }
        // The last project opens again; with no maps folder or no project yet, the window
        // asks for them before anything else.
        if let workspace, let last = UserDefaults.standard.string(forKey: WorkspaceStore.lastProject), let project = workspace.project(named: last) {
            open(project)
        } else {
            showWindow()
        }
        // Closing the window puts the app back in the menu bar only (no Dock icon).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard (note.object as? NSWindow).map(Self.isMainWindow) == true else { return }
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
    }

    nonisolated static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    /// Captured text (the global shortcut, a drop, the clipboard) becomes a context item.
    func capture(_ text: String) {
        guard let session else { return }
        session.addContext(text, kind: .pasted)
        show(.context, session: session)
        showWindow()
    }

    /// Opens `panel` in the pane on its side; whatever else floated over the map closes.
    func show(_ panel: Panel, session: MapSession) {
        shownPanels = [panel.edge: panel]
        notationOpen = false
        logOpen = false
        lastShown[panel.edge] = panel
    }

    /// Opens or closes the Notation drawer; opening it closes the side panes.
    func toggleNotation() {
        withAnimation(Theme.slide) {
            notationOpen.toggle()
            if notationOpen { shownPanels = [:]; logOpen = false }
        }
    }

    /// Opens or closes the Model log; opening it closes the side panes and the Notation drawer.
    func toggleLog() {
        withAnimation(Theme.slide) {
            logOpen.toggle()
            if logOpen { shownPanels = [:]; notationOpen = false }
        }
    }

    /// Something opened over the map: the panes and the drawer close; the panes come back when it closes.
    func coverPanes() {
        covered = shownPanels
        withAnimation(Theme.slide) { shownPanels = [:]; notationOpen = false; logOpen = false }
    }

    /// The overlay closed: the pane it closed comes back, unless the user opened another since.
    func uncoverPanes() {
        guard let covered else { return }
        withAnimation(Theme.slide) {
            if shownPanels.isEmpty, !notationOpen, !logOpen { shownPanels = covered }
        }
        self.covered = nil
    }

    /// The panel a side shows, or would show when opened.
    func panel(for edge: PanelPlacement.Edge) -> Panel {
        shownPanels[edge] ?? lastShown[edge] ?? (edge == .leading ? .context : .details)
    }

    func hidePane(_ edge: PanelPlacement.Edge) {
        shownPanels[edge] = nil
    }

    func togglePane(_ edge: PanelPlacement.Edge, session: MapSession) {
        withAnimation(Theme.slide) {
            if shownPanels[edge] != nil {
                shownPanels[edge] = nil
            } else {
                let docked = Panel.allCases.filter { $0.edge == edge }
                // One floating panel at a time: the other side and the drawer close.
                shownPanels = [edge: lastShown[edge].flatMap { docked.contains($0) ? $0 : nil } ?? docked.first ?? .context]
                notationOpen = false
            }
        }
    }

    /// Opens the window (or brings it back) in front of other apps. A menu bar-only app can't come
    /// to the front, so while the window is open the app is a regular one, with a Dock icon.
    func showWindow() {
        let window = self.window ?? makeWindow()
        window.title = session?.title ?? "Mindmap"
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The menu bar icon's click: the window closes when it is open in front, else it opens
    /// (or comes to the front).
    func toggleWindow() {
        if let window, window.isVisible, !window.isMiniaturized, NSApp.isActive {
            window.performClose(nil)
        } else {
            if let window, window.isMiniaturized { window.deminiaturize(nil) }
            showWindow()
        }
    }

    /// The one window, kept (not released) when it's closed so it opens again as it was.
    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindow(model: self).frame(minWidth: 900, minHeight: 600))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
        window.setFrameAutosaveName("Mindmap.main")
        self.window = window
        return window
    }

    func open(_ url: URL) {
        let folder = RecentMaps.resolve(url)
        // Open already, or working in the background: the same session, so two never write one folder.
        if let open = existing(folder) {
            switchTo(open)
            showWindow()
            return
        }
        do {
            switchTo(try MapSession.open(folder: folder))
            showWindow()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Work in the background

    /// Opens a project that is working in the background, where it is.
    func show(_ other: MapSession) {
        switchTo(other)
        showWindow()
        if let folder = other.folder { UserDefaults.standard.set(folder.lastPathComponent, forKey: WorkspaceStore.lastProject) }
    }

    /// The session working on a project, if one is.
    func session(workingOn project: Workspace.Project) -> MapSession? {
        working.first { existing(project.url) === $0 }
    }

    /// Every project working now, the open one first.
    var working: [MapSession] { ([session].compactMap { $0 } + background).filter(\.isBusy) }

    /// Shows `next`. The project left keeps working in the background when it is busy.
    private func switchTo(_ next: MapSession?) {
        if let current = session, current !== next, current.isBusy, !background.contains(where: { $0 === current }) {
            background.append(current)
            watchBackground()
        }
        if let next { background.removeAll { $0 === next } }
        session = next
    }

    private func existing(_ folder: URL) -> MapSession? {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return ([session].compactMap { $0 } + background).first { $0.folder?.standardizedFileURL.resolvingSymlinksInPath().path == path }
    }

    /// Lets each background project go once it is done, and says so in a notification.
    private func watchBackground() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let model = self else { return }
                for done in model.background where !done.isBusy {
                    let body = done.lastError.map { "\($0.message): \($0.raw)" } ?? "Finished what it was working on."
                    Notifier.post(title: done.title, body: body)
                }
                model.background.removeAll { !$0.isBusy }
                if model.background.isEmpty {
                    model.watching = nil
                    return
                }
            }
        }
    }

    /// Asked before quitting: quitting stops what the projects are doing, closing the window does not.
    func shouldQuit() -> Bool {
        let working = working
        guard !quittingForUpdate, !working.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = working.count == 1 ? "\(working[0].title) is still working" : "\(working.count) projects are still working"
        alert.informativeText = working.map { "\($0.title): " + $0.work.map(\.text).joined(separator: ", ") }.joined(separator: "\n")
            + "\n\nQuitting stops it. Close the window instead and it carries on from the menu bar."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Opens a project and remembers it for next time.
    func open(_ project: Workspace.Project) {
        open(project.url)
        if session != nil { UserDefaults.standard.set(project.name, forKey: WorkspaceStore.lastProject) }
    }

    /// The window shows the projects to pick from (or make).
    func showProjects() {
        switchTo(nil)
        showWindow()
    }

    /// Asks for the folder the maps live in; its folders are the projects.
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder for your maps. Each project is a folder inside it."
        panel.prompt = "Use for maps"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            workspace = try Workspace(root: url)
            WorkspaceStore.save(url)
            showProjects()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// A new, empty project, opened.
    func createProject(_ name: String) throws {
        guard let workspace else { return }
        open(try workspace.create(name))
    }

    /// A demo is a project too: made in the maps folder the first time, opened after.
    func openDemo(_ map: Demo.Map) {
        guard let workspace else {
            switchTo(MapSession.demo(map))
            showWindow()
            return
        }
        do { open(try workspace.demo(map)) } catch { NSAlert(error: error).runModal() }
    }

    /// The clipboard as the first item of a new project.
    func newFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), let workspace else { showProjects(); return }
        let stamp = Date().formatted(.dateTime.year().month().day().hour().minute()).replacingOccurrences(of: "/", with: "-")
        guard let project = try? workspace.create("Clipboard \(stamp)") else { showProjects(); return }
        open(project)
        capture(text)
    }

    /// Add audio: the window, with the drop panel open over the map.
    func pickAudio() {
        guard let session else { return }
        showWindow()
        session.overlay = .audio
    }

    func export(_ format: MapSession.ExportFormat) {
        guard let session else { return }
        let (data, ext) = session.export(format)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.title).\(ext)"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    func importMM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            if url.pathExtension == "mm" { session?.importMM(text) } else { capture(text) }
        }
    }
}
