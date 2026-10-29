import AppKit
import Harness
import Observation

/// The menu bar icon and its menu, made with AppKit's `NSStatusItem`. SwiftUI's `MenuBarExtra`
/// drew an icon that ignored clicks on some Macs (as tool-mac-tool-run found; its AppKit icon
/// works there). The menu is built again each time it opens, so it always shows the current maps
/// and update state.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Mindmap"
        refreshIcon()
    }

    /// The icon; an update waiting shows as an arrow. Redrawn whenever the update state changes.
    private func refreshIcon() {
        let waiting = withObservationTracking {
            model.updater.available != nil
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshIcon() } }
        }
        let symbol = waiting ? "arrow.down.circle" : "point.3.connected.trianglepath.dotted"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mindmap")
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("Open Mindmap", to: menu) { $0.showWindow() }
        menu.addItem(.separator())
        add("New project from clipboard", to: menu) { $0.newFromClipboard() }
        add("Transcribe audio file…", to: menu) { $0.pickAudio() }
        if let workspace = model.workspace {
            let sub = submenu("Projects", in: menu)
            for project in workspace.projects().prefix(12) { add(project.name, to: sub) { $0.open(project) } }
            if sub.items.count > 0 { sub.addItem(.separator()) }
            add("All projects…", to: sub) { $0.showProjects() }
        }
        add("Choose maps folder…", to: menu) { $0.chooseWorkspace() }
        let demos = submenu("Demo", in: menu)
        for map in Demo.Map.allCases {
            add(map.rawValue.capitalized, to: demos) { $0.openDemo(map) }
        }
        menu.addItem(.separator())
        addUpdateItems(to: menu)
        menu.addItem(.separator())
        add("Quit", key: "q", to: menu) { _ in NSApp.terminate(nil) }
    }

    /// What this copy is, and checking for, installing or retrying an update.
    private func addUpdateItems(to menu: NSMenu) {
        let updater = model.updater
        if Updater.canUpdate {
            switch updater.state {
            case .idle, .upToDate:
                add(updater.state == .upToDate ? "Up to date: check again" : "Check for updates", to: menu) { $0.updater.check(userInitiated: true) }
            case .checking:
                note("Checking for updates…", in: menu)
            case let .available(plan):
                add(plan.title + "…", to: menu) { $0.updater.confirmInstall() }
            case let .installing(step):
                note(step, in: menu)
            case let .failed(message):
                note(message, in: menu)
                add("Try again", to: menu) { $0.updater.check(userInitiated: true) }
                add("Copy error report", to: menu) { _ in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Updater.report(message), forType: .string)
                }
            }
        }
        note(updater.versionLine, in: menu)
    }

    // MARK: - Items

    /// A menu item that runs a closure.
    private final class ActionItem: NSMenuItem {
        var handler: (() -> Void)?
        @objc func run() { handler?() }
    }

    private func add(_ title: String, key: String = "", to menu: NSMenu, _ action: @escaping (AppModel) -> Void) {
        let item = ActionItem(title: title, action: #selector(ActionItem.run), keyEquivalent: key)
        item.target = item
        item.handler = { [model] in action(model) }
        menu.addItem(item)
    }

    private func note(_ title: String, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
        return sub
    }
}
