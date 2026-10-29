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
                Button("New map from clipboard") { model.newFromClipboard() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open folder…") { model.openFolder() }.keyboardShortcut("o", modifiers: .command)
                Button("Transcribe audio file…") { model.pickAudio() }
                Divider()
                Button("Submit") { model.session?.submit(sentenceMode: false) }.keyboardShortcut(.return, modifiers: .command)
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
        MainActor.assumeIsolated { AppModel.shared.start() }
    }
}

/// App-wide state: the open session, the demo fallback, the window.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var session: MapSession?
    var openPanels: Set<Panel> = [.context]
    let updater = Updater()
    private var ollama = OllamaLauncher()
    private var shortcut: GlobalShortcut?
    @ObservationIgnored private var statusBar: StatusBarController?
    @ObservationIgnored private var window: NSWindow?

    init() {
        session = MapSession.demo(.typical)
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
        // Closing the window puts the app back in the menu bar only (no Dock icon).
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard (note.object as? NSWindow).map(Self.isMainWindow) == true else { return }
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
    }

    nonisolated static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    func capture(_ text: String) {
        guard let session else { return }
        session.contextDraft += (session.contextDraft.isEmpty ? "" : "\n\n") + text
        session.saveDraft()
        openPanels.insert(.context)
        showWindow()
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
        do {
            session = try MapSession.open(folder: RecentMaps.resolve(url))
            showWindow()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func newFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        openFolder()
        capture(text)
    }

    func pickAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { session?.dropAudio(url); openPanels.insert(.context) }
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
