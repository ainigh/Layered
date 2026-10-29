import Foundation
import AppKit
import Harness

/// Starts `ollama serve` as a helper if Ollama is installed and not already running.
final class OllamaLauncher {
    private var process: Process?

    func startIfInstalled(host: URL = URL(string: "http://localhost:11434")!) {
        Task.detached { [weak self] in
            if await OllamaClient(host: host).ping() { return }
            guard let path = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            await MainActor.run { self?.process = p }
        }
    }

    deinit { process?.terminate() }
}

/// The global capture shortcut: sends the current selection from any app into the Context panel.
/// Uses an event monitor (needs Accessibility permission, which macOS asks for once) and reads
/// the selection by posting ⌘C and taking the pasteboard.
final class GlobalShortcut {
    private var monitor: Any?
    private let handler: (String) -> Void

    init(handler: @escaping (String) -> Void) {
        self.handler = handler
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.command, .option, .control]), event.charactersIgnoringModifiers == "m" else { return }
            self?.capture()
        }
    }

    private func capture() {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)   // c
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [handler] in
            guard pasteboard.changeCount != before, let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
            handler(text)
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
