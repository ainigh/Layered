import SwiftUI
import Harness

/// The infinite canvas: pan, zoom, nodes by kind and provenance, edges with labels,
/// heading regions, selection, drag to pin, double-click to expand, context menu.
/// Everything drawn comes from `session.displayedGraph` and `session.layout`.
struct CanvasView: View {
    @Bindable var session: MapSession
    @State private var pan: CGSize = .zero
    @State private var dragStartPan: CGSize?
    @State private var zoom: CGFloat = 1
    @State private var draggingNode: (name: String, offset: CGSize)?
    @State private var linkDrag: (from: String, to: CGPoint)?
    @State private var boxSelect: (start: CGPoint, end: CGPoint)?
    @State private var labelPrompt: (from: String, to: String)?
    @State private var labelText = ""
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var commentTarget: String?
    @State private var commentText = ""
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let graph = session.displayedGraph
            let layout = session.layout
            let center = CGPoint(x: geo.size.width / 2 + pan.width, y: geo.size.height / 2 + pan.height)

            ZStack {
                Canvas(rendersAsynchronously: graph.nodes.count > 500) { ctx, size in
                    draw(graph: graph, layout: layout, in: &ctx, center: center)
                }
                .gesture(canvasDrag(graph: graph, layout: layout, center: center))
                .simultaneousGesture(MagnifyGesture().onChanged { v in zoom = min(max(v.magnification * zoomBase, 0.2), 4) }.onEnded { _ in zoomBase = zoom })
                .onTapGesture(count: 2) { location in
                    if let name = hit(location, graph: graph, layout: layout, center: center) { session.expand(name) }
                }
                .onTapGesture(count: 1) { location in
                    select(at: location, graph: graph, layout: layout, center: center, additive: NSEvent.modifierFlags.contains(.shift))
                }
                .contextMenu { contextMenu(graph: graph) }
                .onContinuousHover { phase in
                    if case .active(let p) = phase, let name = hit(p, graph: graph, layout: layout, center: center) { hovered = name } else { hovered = nil }
                }

                if let hovered, let node = graph.nodes[NodeID(name: hovered)], let p = layout.positions[hovered] {
                    HoverCard(node: node, graph: graph)
                        .position(x: center.x + p.x * zoom, y: center.y + p.y * zoom - Layout.radius(degree: graph.degree(of: node.id)) * zoom - 48)
                        .allowsHitTesting(false)
                }
                if let boxSelect {
                    Rectangle().fill(Theme.accent.opacity(0.1)).overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
                        .frame(width: abs(boxSelect.end.x - boxSelect.start.x), height: abs(boxSelect.end.y - boxSelect.start.y))
                        .position(x: (boxSelect.start.x + boxSelect.end.x) / 2, y: (boxSelect.start.y + boxSelect.end.y) / 2)
                        .allowsHitTesting(false)
                }
                if session.viewingTurn != nil {
                    VStack {
                        HStack {
                            Label("Viewing turn \(session.viewingTurn!) (read-only)", systemImage: "clock")
                            Button("Back to now") { session.viewingTurn = nil }
                        }
                        .padding(Theme.Space.s)
                        .background(.regularMaterial, in: Capsule())
                        Spacer()
                    }
                    .padding(Theme.Space.m)
                }
            }
            .onReceive(tick) { now = $0 }
            .onScrollWheel { delta in
                pan.width += delta.width
                pan.height += delta.height
            }
            .onAppear { pan = CGSize(width: session.ui.viewportX, height: session.ui.viewportY); zoom = session.ui.zoom; zoomBase = zoom }
            .onChange(of: pan) { _, p in session.ui.viewportX = p.width; session.ui.viewportY = p.height; session.saveUI() }
            .onChange(of: zoom) { _, z in session.ui.zoom = z; session.saveUI() }
            .sheet(isPresented: Binding(get: { labelPrompt != nil }, set: { if !$0 { labelPrompt = nil } })) {
                TextPrompt(title: "Edge label", placeholder: "short phrasal verb", text: $labelText) {
                    if let l = labelPrompt { session.dispatch(.addEdge(from: l.from, label: labelText.isEmpty ? nil : labelText, to: l.to)) }
                    labelText = ""; labelPrompt = nil
                }
            }
            .sheet(isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextPrompt(title: "Rename \(renameTarget ?? "")", placeholder: "new name", text: $renameText) {
                    if let old = renameTarget { session.dispatch(.rename(old, to: renameText)); session.selection = [Canonicaliser.canonical(renameText)] }
                    renameTarget = nil
                }
            }
            .sheet(isPresented: Binding(get: { commentTarget != nil }, set: { if !$0 { commentTarget = nil } })) {
                TextPrompt(title: "Comment on \(commentTarget ?? "")", placeholder: "note", text: $commentText) {
                    if let name = commentTarget { session.dispatch(.comment(on: name, commentText)) }
                    commentText = ""; commentTarget = nil
                }
            }
        }
    }

    @State private var zoomBase: CGFloat = 1
    @State private var hovered: String?

    // MARK: - Drawing

    private func screen(_ p: Placed, _ center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + p.x * zoom, y: center.y + p.y * zoom)
    }

    private func draw(graph: Graph, layout: Layout, in ctx: inout GraphicsContext, center: CGPoint) {
        // Heading regions
        var regions: [[String]: [CGPoint]] = [:]
        for (id, node) in graph.nodes where id.scope.isEmpty && !node.heading.isEmpty {
            if let p = layout.positions[id.name] { regions[node.heading, default: []].append(screen(p, center)) }
        }
        for (heading, points) in regions where points.count > 1 {
            let xs = points.map(\.x), ys = points.map(\.y)
            let rect = CGRect(x: xs.min()! - 40 * zoom, y: ys.min()! - 40 * zoom, width: xs.max()! - xs.min()! + 80 * zoom, height: ys.max()! - ys.min()! + 80 * zoom)
            let path = Path(roundedRect: rect, cornerRadius: Theme.radiusLarge * 2)
            ctx.fill(path, with: .color(Theme.accent.opacity(0.06)))
            ctx.stroke(path, with: .color(Theme.accent.opacity(0.2)), lineWidth: 1)
            ctx.draw(Text(heading.joined(separator: " › ")).font(Theme.label).foregroundStyle(.secondary), at: CGPoint(x: rect.minX + 12, y: rect.minY + 10), anchor: .topLeading)
        }

        // Edges
        for edge in graph.edges.values {
            guard let pa = layout.positions[edge.a.name], let pb = layout.positions[edge.b.name] else { continue }
            let a = screen(pa, center), b = screen(pb, center)
            let ra = Layout.radius(degree: graph.degree(of: edge.a)) * zoom * 1.3
            let rb = Layout.radius(degree: graph.degree(of: edge.b)) * zoom * 1.3
            let d = max(hypot(b.x - a.x, b.y - a.y), 1)
            let ux = (b.x - a.x) / d, uy = (b.y - a.y) / d
            let start = CGPoint(x: a.x + ux * ra, y: a.y + uy * ra), end = CGPoint(x: b.x - ux * rb, y: b.y - uy * rb)
            var path = Path()
            path.move(to: start); path.addLine(to: end)
            let style = Theme.provenance(edge.note(kind: "src"))
            let selected = session.selectedEdge == edge.key
            let colour: Color = selected ? Theme.accent : Color.secondary.opacity(style.opacity)
            ctx.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: (selected ? 2.5 : 1.5) * zoom, dash: style.dash.map { $0 * zoom }))
            if edge.forward || edge.isTwoWay { arrow(&ctx, at: end, ux: ux, uy: uy, colour: colour) }
            if edge.backward { arrow(&ctx, at: start, ux: -ux, uy: -uy, colour: colour) }
            if !edge.labels.isEmpty {
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                ctx.draw(Text(edge.labels.joined(separator: ", ")).font(Theme.caption).foregroundStyle(.secondary), at: mid, anchor: .bottom)
            }
        }
        if let linkDrag, let p = layout.positions[linkDrag.from] {
            var path = Path(); path.move(to: screen(p, center)); path.addLine(to: linkDrag.to)
            ctx.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
        }

        // Nodes
        for id in graph.nodes.keys where id.scope.isEmpty {
            guard let node = graph.nodes[id], var p = layout.positions[id.name] else { continue }
            if let d = draggingNode, d.name == id.name { p.x += d.offset.width / zoom; p.y += d.offset.height / zoom }
            let c = screen(p, center)
            let r = Layout.radius(degree: graph.degree(of: id)) * zoom
            let kind = node.note(kind: "kind")
            let style = Theme.provenance(node.note(kind: "src"))
            let colour = Theme.kind(kind)
            let shape = nodeShape(kind, center: c, r: r)
            let fresh = session.highlighted[id.name].map { now.timeIntervalSince($0) < Theme.highlightSeconds } ?? false
            let selected = session.selection.contains(id.name)
            var layer = ctx
            layer.opacity = style.opacity
            if fresh { layer.fill(shape.insetBy(-6 * zoom), with: .color(Theme.accent.opacity(0.25))) }
            if selected { layer.stroke(shape.insetBy(-4 * zoom), with: .color(Theme.accent), lineWidth: 3 * zoom) }
            layer.fill(shape, with: .color((style.tint ?? colour).opacity(style.fillOpacity * 0.25)))
            layer.fill(shape, with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.85)))
            layer.stroke(shape, with: .color(colour), style: StrokeStyle(lineWidth: style.lineWidth * zoom, dash: style.dash.map { $0 * zoom }))
            if style.doubleBorder { layer.stroke(shape.insetBy(4 * zoom), with: .color(colour), lineWidth: 1 * zoom) }
            layer.draw(Text(id.name).font(.system(size: 12 * zoom, design: .rounded)).foregroundStyle(.primary), at: c, anchor: .center)
            if let badge = style.badge {
                layer.draw(Image(systemName: badge), at: CGPoint(x: c.x + r * 1.2, y: c.y - r * 0.8), anchor: .center)
            }
            let icons = session.icons.icons(for: id.name)
            if icons.isEmpty {
                layer.draw(Image(systemName: IconManifest.fallbackSymbol(kind: kind)), at: CGPoint(x: c.x - r * 1.2, y: c.y - r * 0.8), anchor: .center)
            } else {
                let (shown, more) = IconManifest.badge(icons)
                for (i, icon) in shown.enumerated().reversed() {
                    layer.draw(Image(systemName: icon), at: CGPoint(x: c.x - r * 1.2 + CGFloat(i) * 8 * zoom, y: c.y - r * 0.8), anchor: .center)
                }
                if more > 0 { layer.draw(Text("+\(more)").font(Theme.caption), at: CGPoint(x: c.x - r * 1.2 + 30 * zoom, y: c.y - r * 0.8)) }
            }
            // Chips
            var chips = node.notes.compactMap { NoteKind.split($0) }.filter { ["date", "todo", "ref"].contains($0.kind) }.map { "\($0.kind) \($0.value)" }
            let proofs = node.notes.filter { $0.hasPrefix("text ") }.count + graph.edges(touching: id).flatMap(\.notes).filter { $0.hasPrefix("text ") }.count
            if proofs > 0 { chips.append("\(proofs) proof") }
            if p.pinned { chips.append("pinned") }
            for (i, chip) in chips.prefix(3).enumerated() {
                layer.draw(Text(chip).font(.system(size: 9 * zoom)).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y + r + (CGFloat(i) * 11 + 8) * zoom), anchor: .center)
            }
        }
    }

    private func arrow(_ ctx: inout GraphicsContext, at p: CGPoint, ux: CGFloat, uy: CGFloat, colour: Color) {
        let s = 8 * zoom
        var path = Path()
        path.move(to: p)
        path.addLine(to: CGPoint(x: p.x - ux * s - uy * s * 0.5, y: p.y - uy * s + ux * s * 0.5))
        path.addLine(to: CGPoint(x: p.x - ux * s + uy * s * 0.5, y: p.y - uy * s - ux * s * 0.5))
        path.closeSubpath()
        ctx.fill(path, with: .color(colour))
    }

    private func nodeShape(_ kind: String?, center c: CGPoint, r: CGFloat) -> Path {
        switch kind {
        case "person": return Path(roundedRect: CGRect(x: c.x - r * 1.5, y: c.y - r * 0.8, width: r * 3, height: r * 1.6), cornerRadius: r * 0.8)
        case "place": return polygon(c, r * 1.5, 6)
        case "thing": return Path(roundedRect: CGRect(x: c.x - r * 1.5, y: c.y - r * 0.8, width: r * 3, height: r * 1.6), cornerRadius: Theme.radiusSmall)
        case "action": return Path(roundedRect: CGRect(x: c.x - r * 1.5, y: c.y - r * 0.6, width: r * 3, height: r * 1.2), cornerRadius: r)
        case "event": return polygon(c, r * 1.6, 4)
        case "idea": return Path(ellipseIn: CGRect(x: c.x - r * 1.6, y: c.y - r, width: r * 3.2, height: r * 2))
        default: return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }

    private func polygon(_ c: CGPoint, _ r: CGFloat, _ n: Int) -> Path {
        var path = Path()
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Hit testing and gestures

    private func hit(_ point: CGPoint, graph: Graph, layout: Layout, center: CGPoint) -> String? {
        var best: (String, CGFloat)?
        for (name, p) in layout.positions {
            let r = Layout.radius(degree: graph.degree(of: NodeID(name: name))) * zoom * 1.5
            let d = hypot(point.x - screen(p, center).x, point.y - screen(p, center).y)
            if d < r, best == nil || d < best!.1 { best = (name, d) }
        }
        return best?.0
    }

    private func hitEdge(_ point: CGPoint, graph: Graph, layout: Layout, center: CGPoint) -> EdgeKey? {
        for edge in graph.edges.values {
            guard let pa = layout.positions[edge.a.name], let pb = layout.positions[edge.b.name] else { continue }
            let a = screen(pa, center), b = screen(pb, center)
            let l2 = pow(b.x - a.x, 2) + pow(b.y - a.y, 2)
            guard l2 > 0 else { continue }
            let t = max(0, min(1, ((point.x - a.x) * (b.x - a.x) + (point.y - a.y) * (b.y - a.y)) / l2))
            let proj = CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
            if hypot(point.x - proj.x, point.y - proj.y) < 6 { return edge.key }
        }
        return nil
    }

    private func select(at point: CGPoint, graph: Graph, layout: Layout, center: CGPoint, additive: Bool) {
        withAnimation(Theme.selection) {
            if let name = hit(point, graph: graph, layout: layout, center: center) {
                if additive { session.selection.formSymmetricDifference([name]) } else { session.selection = [name] }
                session.selectedEdge = nil
            } else if let key = hitEdge(point, graph: graph, layout: layout, center: center) {
                session.selectedEdge = key
                session.selection = []
            } else if !additive {
                session.selection = []
                session.selectedEdge = nil
            }
        }
    }

    private func canvasDrag(graph: Graph, layout: Layout, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if let link = linkDrag { linkDrag = (link.from, value.location); return }
                if let d = draggingNode { draggingNode = (d.name, value.translation); return }
                if boxSelect != nil { boxSelect = (value.startLocation, value.location); return }
                if dragStartPan != nil { pan = CGSize(width: dragStartPan!.width + value.translation.width, height: dragStartPan!.height + value.translation.height); return }
                // First movement decides what this drag is.
                if let name = hit(value.startLocation, graph: graph, layout: layout, center: center) {
                    if NSEvent.modifierFlags.contains(.option) { linkDrag = (name, value.location) } else { draggingNode = (name, value.translation) }
                } else if NSEvent.modifierFlags.contains(.shift) {
                    boxSelect = (value.startLocation, value.location)
                } else {
                    dragStartPan = pan
                }
            }
            .onEnded { value in
                if let link = linkDrag {
                    if let target = hit(value.location, graph: graph, layout: layout, center: center), target != link.from {
                        labelPrompt = (link.from, target)
                    }
                    linkDrag = nil
                } else if let d = draggingNode, let p = layout.positions[d.name] {
                    session.dispatch(.pin(d.name, x: (p.x + d.offset.width / zoom).rounded(), y: (p.y + d.offset.height / zoom).rounded()))
                    draggingNode = nil
                } else if let box = boxSelect {
                    let rect = CGRect(x: min(box.start.x, box.end.x), y: min(box.start.y, box.end.y), width: abs(box.end.x - box.start.x), height: abs(box.end.y - box.start.y))
                    session.selection = Set(layout.positions.values.filter { rect.contains(screen($0, center)) }.map(\.name))
                    boxSelect = nil
                }
                dragStartPan = nil
            }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(graph: Graph) -> some View {
        if let name = session.selection.first, session.selection.count == 1, let node = graph.nodes[NodeID(name: name)] {
            Button("Expand") { session.expand(name) }
            Button("Rename…") { renameText = name; renameTarget = name }
            Button("Delete") { session.dispatch(.delete(name)); session.selection = [] }
            if ["world", "guess", "advice"].contains(node.note(kind: "src") ?? "") { Button("Confirm (mark as mine)") { session.dispatch(.confirm(name)) } }
            Button("Add comment…") { commentTarget = name }
            Menu("Set kind") {
                ForEach(["person", "place", "thing", "action", "event", "idea"], id: \.self) { k in
                    Button(k) { session.dispatch(.applyLines(["| \(name) @kind \(k)"], what: "kind \(name)")) }
                }
            }
            Menu("Set icon") {
                ForEach(Array(session.icons.entries.keys.sorted().prefix(30)), id: \.self) { icon in
                    Button(icon) { session.dispatch(.applyLines(["| \(name) @icon \(icon)"], what: "icon \(name)")) }
                }
                if session.icons.entries.isEmpty { Text("Add SVGs to icons/ in the folder") }
            }
            if session.layout.positions[name]?.pinned == true { Button("Release") { session.dispatch(.release(name)) } }
            Button("Show in text") { session.selection = [name] }
        } else if session.selection.count > 1 {
            Button("Expand \(session.selection.count) nodes") { session.selection.forEach { session.expand($0) } }
            Button("Delete \(session.selection.count) nodes") { session.selection.forEach { session.dispatch(.delete($0)) }; session.selection = [] }
        } else if let key = session.selectedEdge, let edge = graph.edges[key] {
            Button("Edit label…") { labelText = edge.labels.first ?? ""; labelPrompt = (edge.a.name, edge.b.name) }
            Button("Delete edge") {
                // The notation removes an edge only with a node: Transition rebuilds the endpoint without it.
                var without = graph
                without.edges.removeValue(forKey: key)
                session.dispatch(.applyLines(Transition.lines(from: graph, to: without), what: "delete edge \(edge.a.name) \(edge.b.name)"))
                session.selectedEdge = nil
            }
            if ["world", "guess", "advice"].contains(edge.note(kind: "src") ?? "") {
                Button("Confirm") { session.dispatch(.applyLines(["| \(edge.a.name) @src user - | \(edge.b.name)"], what: "confirm edge")) }
            }
            Button("Add comment…") { commentTarget = edge.a.name }
        } else {
            Button("Release all pins") {
                for (name, p) in session.layout.positions where p.pinned { session.dispatch(.release(name)) }
            }
            Button("Reset view") { pan = .zero; zoom = 1; zoomBase = 1 }
        }
    }
}

struct HoverCard: View {
    let node: Node
    let graph: Graph

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(node.id.name).font(Theme.label)
                if let src = node.note(kind: "src") { Text(src).font(Theme.caption).foregroundStyle(.secondary) }
            }
            ForEach(node.notes.filter { !$0.hasPrefix("src") && !$0.hasPrefix("pos") }, id: \.self) { Text($0).font(Theme.caption) }
            ForEach(Outline.comments(attachedTo: node.id.name, in: graph), id: \.self) { Text($0).font(Theme.caption).italic() }
        }
        .padding(Theme.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }
}

struct TextPrompt: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(Theme.title)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).onSubmit { onDone(); dismiss() }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("OK") { onDone(); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(Theme.Space.l)
        .frame(width: 360)
    }
}

/// Scroll-wheel panning: SwiftUI has no modifier, so an NSView reports the deltas.
extension View {
    func onScrollWheel(_ action: @escaping (CGSize) -> Void) -> some View {
        background(ScrollWheelCatcher(action: action))
    }
}

struct ScrollWheelCatcher: NSViewRepresentable {
    let action: (CGSize) -> Void
    func makeNSView(context: Context) -> ScrollView { let v = ScrollView(); v.action = action; return v }
    func updateNSView(_ nsView: ScrollView, context: Context) { nsView.action = action }

    final class ScrollView: NSView {
        var action: ((CGSize) -> Void)?
        override func scrollWheel(with event: NSEvent) {
            action?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
        override var acceptsFirstResponder: Bool { true }
    }
}

extension Path {
    func insetBy(_ d: CGFloat) -> Path {
        let b = boundingRect
        guard b.width > 0, b.height > 0 else { return self }
        let sx = (b.width - 2 * d) / b.width, sy = (b.height - 2 * d) / b.height
        return applying(CGAffineTransform(translationX: b.midX, y: b.midY).scaledBy(x: sx, y: sy).translatedBy(x: -b.midX, y: -b.midY))
    }
}
