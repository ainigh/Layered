import SwiftUI
import Harness
import AppKit

@main
struct MindmapApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            // An update waiting shows on the icon.
            Image(systemName: model.updater.available == nil ? "point.3.connected.trianglepath.dotted" : "arrow.down.circle")
        }
        Window("Mindmap", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
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

/// App-wide state: the open session, the demo fallback, the window.
@MainActor
@Observable
final class AppModel {
    var session: MapSession?
    var openPanels: Set<Panel> = [.context]
    let updater = Updater()
    private var ollama = OllamaLauncher()
    private var shortcut: GlobalShortcut?
    /// SwiftUI's `openWindow`, handed over by the menu (only a view can get it), so anything here
    /// that shows the window also opens it when it's closed.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    init() {
        session = MapSession.demo(.typical)
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
        openMainWindow?()
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.windows.first(where: Self.isMainWindow)?.makeKeyAndOrderFront(nil)
        }
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

struct MenuBarMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = model.openMainWindow = { [openWindow] in openWindow(id: "main") }
        Button("Open Mindmap") { model.showWindow() }
        Divider()
        Button("New map from clipboard") { model.newFromClipboard() }
        Button("Open folder…") { model.openFolder() }
        Button("Transcribe audio file…") { model.pickAudio() }
        if !RecentMaps.all().isEmpty {
            Menu("Recent maps") {
                ForEach(RecentMaps.all(), id: \.self) { url in
                    Button(url.lastPathComponent) { model.open(url) }
                }
            }
        }
        Menu("Demo") {
            ForEach(Demo.Map.allCases, id: \.self) { map in
                Button(map.rawValue.capitalized) { model.session = MapSession.demo(map); model.showWindow() }
            }
        }
        Divider()
        UpdateMenuItems(updater: model.updater)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// What this copy is, and checking for, installing or retrying an update.
struct UpdateMenuItems: View {
    let updater: Updater

    var body: some View {
        if Updater.canUpdate {
            switch updater.state {
            case .idle, .upToDate:
                Button(updater.state == .upToDate ? "Up to date: check again" : "Check for updates") { updater.check(userInitiated: true) }
            case .checking:
                Text("Checking for updates…")
            case let .available(plan):
                Button(plan.title + "…") { updater.confirmInstall() }
            case let .installing(step):
                Text(step)
            case let .failed(message):
                Text(message)
                Button("Try again") { updater.check(userInitiated: true) }
                Button("Copy error report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Updater.report(message), forType: .string)
                }
            }
        }
        Text(updater.versionLine)
    }
}
