import SwiftUI
import AppKit
import Harness

/// One request to the model and what came back. A run that sends again (without the
/// grammar, or to repair lines that did not parse) has an exchange per request.
struct ModelExchange: Identifiable, Equatable {
    enum Status: Equatable { case running, done, stopped, failed(String) }

    let id: Int
    /// The run it belongs to, and which of that run's requests it is (1 the first).
    let run: Int
    let round: Int
    let kind: PromptKind
    /// What the run was about: `text 3 s5` for a sentence of a walk, a node for Expand.
    let about: String
    let started: Date
    let request: ModelRequest
    var response = ""
    var status = Status.running
    var finished: Date?
    var promptTokens: Int?
    var responseTokens: Int?

    var isRunning: Bool { status == .running }

    /// The exchange as plain text, for the clipboard.
    var transcript: String {
        var settings = ["temperature \(request.temperature.formatted())", request.grammar == nil ? "no grammar" : "grammar on"]
        if let size = request.contextSize { settings.append("context \(size)") }
        var out = "=== \(kind.rawValue) · \(about)\(round > 1 ? " · request \(round)" : "") · \(started.formatted(date: .abbreviated, time: .standard)) ===\n"
        out += "--- sent to \(request.model) (\(settings.joined(separator: ", "))) ---\n\(request.prompt)\n"
        if let grammar = request.grammar { out += "--- grammar ---\n\(grammar)\n" }
        out += "--- received ---\n\(response)\n"
        if case .failed(let message) = status { out += "--- failed ---\n\(message)\n" }
        if status == .stopped { out += "--- stopped ---\n" }
        return out
    }
}

/// The drawer in the map's bottom right corner, beside zoom: every request this session
/// sent the model, in full (the prompt with its map and context), and the reply as it
/// streams. The newest opens as it is sent; the others open with a click.
struct ModelLogDrawer: View {
    @Bindable var session: MapSession
    @Bindable var model: AppModel
    @State private var expanded: Set<Int> = []

    var body: some View {
        let log = session.modelLog
        let running = log.last?.isRunning == true
        VStack(alignment: .trailing, spacing: Theme.Space.s) {
            Spacer()
            if model.logOpen {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.Space.s) {
                        Text("Model log").font(Theme.label)
                        Text(log.isEmpty ? "" : "\(log.count) request\(log.count == 1 ? "" : "s")").font(Theme.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { copy(log.map(\.transcript).joined(separator: "\n")) } label: { Label("Copy all", systemImage: "doc.on.doc") }
                            .controlSize(.small)
                            .disabled(log.isEmpty)
                            .help("Copy every request and reply as plain text")
                        Button { session.modelLog.removeAll { !$0.isRunning }; expanded = [] } label: { Label("Clear", systemImage: "trash") }
                            .controlSize(.small)
                            .disabled(log.isEmpty)
                            .help("Empty the log (it lasts until the project closes)")
                    }
                    .padding(Theme.Space.s)
                    Divider()
                    if log.isEmpty {
                        Text("Nothing sent yet. Each request to the model, the whole prompt with the map and context it carries, shows here with the reply as it comes.")
                            .font(Theme.caption).foregroundStyle(.secondary)
                            .padding(Theme.Space.m)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(log) { exchange in
                                        ExchangeRow(exchange: exchange, expanded: expandedBinding(exchange.id), copy: { copy(exchange.transcript) })
                                            .id(exchange.id)
                                        Divider()
                                    }
                                }
                            }
                            .onAppear { if let id = log.last?.id { proxy.scrollTo(id, anchor: .top) } }
                            .onChange(of: log.last?.id) { _, id in
                                // The newest request opens, and the log follows it.
                                guard let id else { return }
                                expanded.insert(id)
                                withAnimation(Theme.slide) { proxy.scrollTo(id, anchor: .top) }
                            }
                        }
                    }
                }
                .frame(maxWidth: 580, maxHeight: 480)
                .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
                .shieldsMapScroll()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button {
                model.toggleLog()
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    if running { ProgressView().controlSize(.mini) } else { Image(systemName: "text.bubble") }
                    Text("Model log")
                    if !log.isEmpty { Text("· \(log.count)").foregroundStyle(.secondary) }
                    Image(systemName: model.logOpen ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .bold))
                }
                .font(Theme.label)
                .padding(.horizontal, Theme.Space.m - 4)
                .frame(height: 30)
                .floatingBar(in: Capsule())
            }
            .buttonStyle(.plain)
            .help("What was sent to the model and what it answered, in full")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(Theme.Space.m)
        // Zoom and spacing keep the corner itself.
        .padding(.trailing, ZoomBar.width + Theme.Space.s)
        .onAppear { if let last = session.modelLog.last { expanded.insert(last.id) } }
    }

    private func expandedBinding(_ id: Int) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One exchange: a summary line, and when open the prompt as sent and the reply as received.
private struct ExchangeRow: View {
    let exchange: ModelExchange
    @Binding var expanded: Bool
    let copy: () -> Void
    @State private var showGrammar = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { withAnimation(Theme.selection) { expanded.toggle() } } label: { summary }
                .buttonStyle(.plain)
            if expanded {
                section("Sent to \(exchange.request.model)", detail: settings) {
                    block(exchange.request.prompt)
                    if let grammar = exchange.request.grammar {
                        DisclosureGroup(isExpanded: $showGrammar) { block(grammar) } label: {
                            Text("Grammar · \(grammar.split(separator: "\n").count) rules").font(Theme.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                section("Received", detail: tokens) {
                    if exchange.response.isEmpty {
                        Text(exchange.isRunning ? "Waiting for the model…" : "Nothing.").font(Theme.caption).foregroundStyle(.secondary)
                    } else {
                        block(exchange.response)
                    }
                    if case .failed(let message) = exchange.status {
                        Text(message).font(Theme.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                HStack {
                    Spacer()
                    Button("Copy", action: copy).controlSize(.small).help("Copy this request and its reply as plain text")
                }
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.s - 2)
    }

    private var summary: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 12)
            Text(exchange.started.formatted(date: .omitted, time: .standard)).font(Theme.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(exchange.kind.rawValue)
                .font(Theme.caption.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.accent.opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.accent)
            Text(exchange.about).font(Theme.caption).lineLimit(1).truncationMode(.middle)
            if exchange.round > 1 { Text("request \(exchange.round)").font(Theme.caption).foregroundStyle(.secondary) }
            Spacer(minLength: Theme.Space.s)
            status
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var status: some View {
        switch exchange.status {
        case .running: ProgressView().controlSize(.mini)
        case .done:
            HStack(spacing: Theme.Space.xs) {
                if let seconds = exchange.finished.map({ $0.timeIntervalSince(exchange.started) }) {
                    Text(seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds)) s").font(Theme.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            }
        case .stopped: Label("Stopped", systemImage: "stop.circle").font(Theme.caption).foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var settings: String {
        var parts = ["temperature \(exchange.request.temperature.formatted())"]
        if let size = exchange.request.contextSize { parts.append("context \(size)") }
        parts.append(exchange.request.grammar == nil ? "no grammar" : "grammar on")
        parts.append("\(exchange.request.prompt.count) characters")
        return parts.joined(separator: " · ")
    }

    private var tokens: String {
        var parts: [String] = []
        if let p = exchange.promptTokens { parts.append("\(p) tokens in") }
        if let r = exchange.responseTokens { parts.append("\(r) out") }
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Text(title).font(Theme.caption.weight(.semibold))
                if !detail.isEmpty { Text(detail).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            content()
        }
        .padding(.leading, 16)
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.s)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }
}
