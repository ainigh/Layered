import SwiftUI
import Harness

/// The mind map, drawn the way GridClip draws one: left-to-right trees on a dot grid that
/// travels with the map, each first-level branch in its own colour, cross-links dashed.
/// What the context or the user says is open (its icon above its name); the model's extras
/// are cards in their provenance's colours. Everything drawn comes from `session.displayedLayout`.
///
///   drag empty space      move the map          scroll        move the map
///   pinch, ⌘-scroll       zoom about the pointer double-click  zoom in there (on a node: expand)
///   + − 0, arrows         zoom, fit, move        hover a node  its links and neighbours stand out
///   drag a node           pin it there (`@pos`)  ⌥-drag        link it to another node
///   ⇧-drag                select a box           right-click   the node's actions
///
/// The map fits the view when it opens and refits as the window resizes or the map grows,
/// until the user moves or zooms it. Buttons, keys and fit glide; drags follow the hand.
struct CanvasView: View {
    @Bindable var session: MapSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the map is going; what is on screen may still be gliding toward it.
    @State private var view = Viewport()
    @State private var glide: Glide?
    /// The user moved or zoomed: a resize or a new node keeps their view instead of refitting.
    @State private var touched = false
    @State private var size: CGSize = .zero
    @State private var pinchBase: Viewport?
    @State private var panStart: Viewport?
    @State private var draggingNode: (name: String, offset: CGSize)?
    @State private var linkDrag: (from: String, to: CGPoint)?
    @State private var boxSelect: (start: CGPoint, end: CGPoint)?
    @State private var hovered: String?
    @State private var labelPrompt: (from: String, to: String)?
    @State private var labelText = ""
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var commentTarget: String?
    @State private var commentText = ""
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let graph = session.displayedGraph
        let base = session.displayedLayout
        let layout = draggingNode.map { base.moving($0.name, dx: $0.offset.width / view.k, dy: $0.offset.height / view.k) } ?? base

        GeometryReader { geo in
            ZStack {
                TimelineView(.animation(paused: glide == nil)) { timeline in
                    let v = shown(at: timeline.date)
                    Canvas(rendersAsynchronously: layout.nodes.count > 500) { ctx, size in
                        draw(graph: graph, layout: layout, in: &ctx, size: size, v: v)
                    }
                }
                .gesture(canvasDrag(layout: layout))
                .simultaneousGesture(pinch)
                .onTapGesture(count: 2) { location in
                    if let name = hit(location, layout) { session.expand(name) } else { zoom(by: Theme.Map.zoomStep, at: location, animate: true) }
                }
                .onTapGesture(count: 1) { location in
                    select(at: location, layout: layout, additive: NSEvent.modifierFlags.contains(.shift))
                }
                .contextMenu { contextMenu(graph: graph) }
                .onContinuousHover { phase in
                    guard draggingNode == nil, panStart == nil else { return }
                    if case .active(let p) = phase { hovered = hit(p, layout) } else { hovered = nil }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in key(press) ? .handled : .ignored }

                if let hovered, draggingNode == nil, linkDrag == nil, let p = layout[hovered], let node = graph.nodes[NodeID(name: hovered)] {
                    let top = view.screen(MapLayout.Point(x: p.x + p.w / 2, y: p.y))
                    HoverCard(node: node, graph: graph, pinned: p.pinned)
                        .fixedSize()
                        .frame(width: 0, height: 0, alignment: .bottom)
                        .position(x: top.x, y: top.y - Theme.Space.s)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if let boxSelect {
                    Rectangle().fill(Theme.accent.opacity(0.08)).overlay(Rectangle().stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                        .frame(width: abs(boxSelect.end.x - boxSelect.start.x), height: abs(boxSelect.end.y - boxSelect.start.y))
                        .position(x: (boxSelect.start.x + boxSelect.end.x) / 2, y: (boxSelect.start.y + boxSelect.end.y) / 2)
                        .allowsHitTesting(false)
                }
                if layout.nodes.isEmpty { EmptyMap() }
                if let turn = session.viewingTurn {
                    // Bottom centre: the top of the map holds the action bar.
                    VStack {
                        Spacer()
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text("Turn \(turn), read-only").font(Theme.label)
                            Button("Back to now") { session.viewingTurn = nil }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                        .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.xs).padding(.vertical, Theme.Space.xs)
                        .floatingBar(in: Capsule())
                    }
                    .padding(Theme.Space.m)
                }
                ZoomBar(zoomIn: { zoom(by: Theme.Map.zoomStep) }, zoomOut: { zoom(by: 1 / Theme.Map.zoomStep) }, fit: refit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(Theme.Space.m)
            }
            .background(Theme.Map.background)
            .clipped()
            .animation(Theme.selection, value: hovered)
            .onScrollWheel { delta, location, zooms in
                if zooms {
                    zoom(by: exp(delta.height * 0.01), at: location, animate: false)
                } else {
                    touched = true
                    go(Viewport(x: view.x + delta.width, y: view.y + delta.height, k: view.k), animate: false)
                }
            }
            .onAppear { size = geo.size; fit(layout: base, animate: false) }
            .onChange(of: geo.size) { _, s in size = s; if !touched { fit(layout: base, animate: false) } }
            .onChange(of: base) { _, next in if !touched { fit(layout: next, animate: true) } }
            .onChange(of: session.viewingTurn) { _, _ in touched = false; fit(layout: session.displayedLayout, animate: true) }
            .onReceive(tick) { t in
                // Redraw only while a highlight is fading.
                if session.highlighted.values.contains(where: { t.timeIntervalSince($0) < Theme.highlightSeconds + 0.5 }) { now = t }
            }
            .sheet(isPresented: Binding(get: { labelPrompt != nil }, set: { if !$0 { labelPrompt = nil } })) {
                TextPrompt(title: "Label the link", placeholder: "a short phrasal verb, like “reports to”", text: $labelText) {
                    if let l = labelPrompt { session.dispatch(.addEdge(from: l.from, label: labelText.isEmpty ? nil : labelText, to: l.to)) }
                    labelText = ""; labelPrompt = nil
                }
            }
            .sheet(isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextPrompt(title: "Rename “\(renameTarget ?? "")”", placeholder: "new name", text: $renameText) {
                    if let old = renameTarget { session.dispatch(.rename(old, to: renameText)); session.selection = [Canonicaliser.canonical(renameText)] }
                    renameTarget = nil
                }
            }
            .sheet(isPresented: Binding(get: { commentTarget != nil }, set: { if !$0 { commentTarget = nil } })) {
                TextPrompt(title: "Comment on “\(commentTarget ?? "")”", placeholder: "a note for yourself", text: $commentText) {
                    if let name = commentTarget { session.dispatch(.comment(on: name, commentText)) }
                    commentText = ""; commentTarget = nil
                }
            }
        }
    }

    // MARK: - Moving and zooming

    /// What is on screen at `date`: the view, or a point on the glide toward it.
    private func shown(at date: Date) -> Viewport {
        guard let glide else { return view }
        let t = min(1, date.timeIntervalSince(glide.start) / Theme.Map.glide)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return glide.from.interpolated(to: glide.to, at: CGFloat(eased))
    }

    private func go(_ next: Viewport, animate: Bool) {
        let from = shown(at: Date())
        view = next
        guard animate, !reduceMotion, from != next else { glide = nil; return }
        let g = Glide(from: from, to: next, start: Date())
        glide = g
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Map.glide) { if glide == g { glide = nil } }
    }

    /// The whole map in view, centred, never zoomed in past `maxFit`.
    private func fit(layout: MapLayout, animate: Bool) {
        guard size.width > 0, !layout.nodes.isEmpty else { return }
        let pad = Theme.Map.fitPad
        let w = CGFloat(layout.width), h = CGFloat(layout.height)
        let k = max(Theme.Map.minZoom, min(Theme.Map.maxFit, (size.width - 2 * pad) / max(1, w), (size.height - 2 * pad) / max(1, h)))
        let x: CGFloat = (size.width - w * k) / 2 - CGFloat(layout.minX) * k
        let y: CGFloat = max(pad, (size.height - h * k) / 2) - CGFloat(layout.minY) * k
        go(Viewport(x: x, y: y, k: k), animate: animate)
    }

    private func refit() {
        touched = false
        fit(layout: session.displayedLayout, animate: true)
    }

    /// Zooms by `factor` keeping the map point under `point` (the centre by default) where it is.
    private func zoom(by factor: CGFloat, at point: CGPoint? = nil, animate: Bool = true) {
        let p = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let next = view.zoomed(by: factor, at: p)
        guard next != view else { return }
        touched = true
        go(next, animate: animate)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? view
                if pinchBase == nil { pinchBase = base }
                touched = true
                go(base.zoomed(by: value.magnification, at: value.startLocation), animate: false)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func key(_ press: KeyPress) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch press.characters {
        case "+", "=": zoom(by: Theme.Map.zoomStep); return true
        case "-", "_": zoom(by: 1 / Theme.Map.zoomStep); return true
        case "0": refit(); return true
        default: break
        }
        let step: CGFloat = 60
        let move: CGSize
        switch press.key {
        case .leftArrow: move = CGSize(width: step, height: 0)
        case .rightArrow: move = CGSize(width: -step, height: 0)
        case .upArrow: move = CGSize(width: 0, height: step)
        case .downArrow: move = CGSize(width: 0, height: -step)
        default: return false
        }
        touched = true
        go(Viewport(x: view.x + move.width, y: view.y + move.height, k: view.k), animate: true)
        return true
    }

    // MARK: - Drawing

    private func draw(graph: Graph, layout: MapLayout, in ctx: inout GraphicsContext, size: CGSize, v: Viewport) {
        drawDots(&ctx, size: size, v: v)

        // What the hovered node touches stays lit; the rest steps back.
        var lit: Set<String>?
        var litEdges = Set<EdgeKey>()
        if let hovered, draggingNode == nil {
            lit = [hovered]
            for e in layout.edges where e.key.lo.name == hovered || e.key.hi.name == hovered {
                litEdges.insert(e.key)
                lit!.insert(e.key.lo.name); lit!.insert(e.key.hi.name)
            }
        }

        var world = ctx
        world.translateBy(x: v.x, y: v.y)
        world.scaleBy(x: v.k, y: v.k)

        for e in layout.edges {
            var layer = world
            if lit != nil, !litEdges.contains(e.key) { layer.opacity = Theme.Map.dimmed }
            drawEdge(e, graph.edges[e.key], lit: litEdges.contains(e.key), in: &layer)
        }
        for p in layout.nodes {
            guard let node = graph.nodes[p.id] else { continue }
            var layer = world
            if let lit, !lit.contains(p.id.name) { layer.opacity = Theme.Map.dimmed }
            drawNode(p, node, in: &layer)
        }
        // Labels last, so no curve runs through them.
        for e in layout.edges where !e.label.isEmpty || !e.note.isEmpty {
            var layer = world
            if lit != nil, !litEdges.contains(e.key) { layer.opacity = Theme.Map.dimmed }
            drawLabel(e, in: &layer)
        }

        if let linkDrag, let p = layout[linkDrag.from] {
            var path = Path()
            path.move(to: v.screen(MapLayout.Point(x: p.x + p.w, y: p.y + p.h / 2)))
            path.addLine(to: linkDrag.to)
            ctx.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
        }
    }

    /// A faint dot grid that moves with the map, so a drag reads as moving a sheet.
    private func drawDots(_ ctx: inout GraphicsContext, size: CGSize, v: Viewport) {
        var gap = Theme.Map.dotGap * v.k
        while gap < 14 { gap *= 2 }
        let r = min(1.4, max(0.7, v.k))
        var dots = Path()
        var x = v.x.truncatingRemainder(dividingBy: gap)
        if x < 0 { x += gap }
        while x < size.width {
            var y = v.y.truncatingRemainder(dividingBy: gap)
            if y < 0 { y += gap }
            while y < size.height {
                dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                y += gap
            }
            x += gap
        }
        ctx.fill(dots, with: .color(Theme.Map.dot))
    }

    private func drawNode(_ p: MapLayout.PlacedNode, _ node: Node, in ctx: inout GraphicsContext) {
        let rect = CGRect(x: p.x, y: p.y, width: p.w, height: p.h)
        let src = node.note(kind: "src")
        let selected = session.selection.contains(p.id.name)
        let fresh = session.highlighted[p.id.name].map { now.timeIntervalSince($0) < Theme.highlightSeconds } ?? false

        if src == "guess" { ctx.opacity *= Theme.provenance(src).opacity }
        if fresh {
            ctx.fill(Path(roundedRect: rect.insetBy(dx: -6, dy: -6), cornerRadius: Theme.Map.corner + 6), with: .color(Theme.accent.opacity(0.22)))
        }
        if selected {
            let ring = Path(roundedRect: rect.insetBy(dx: -3.5, dy: -3.5), cornerRadius: Theme.Map.corner + 3.5)
            if !p.boxed { ctx.fill(ring, with: .color(Theme.accent.opacity(0.1))) }
            ctx.stroke(ring, with: .color(Theme.accent), lineWidth: 2)
        }
        if p.boxed { drawCard(p, node, rect: rect, src: src, in: &ctx) } else { drawOpen(p, node, in: &ctx) }
    }

    /// The node's icon: its own, a matching one from the icon set, or its kind's glyph.
    private func symbol(for p: MapLayout.PlacedNode, kind: String?) -> String {
        session.icons.icons(for: p.id.name).first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            ?? IconManifest.fallbackSymbol(kind: kind)
    }

    /// From the context or the user: the icon above the name, no card.
    private func drawOpen(_ p: MapLayout.PlacedNode, _ node: Node, in ctx: inout GraphicsContext) {
        typealias M = MapLayout.Metrics
        let kind = node.note(kind: "kind")
        let cx = p.x + p.w / 2
        let iconY = p.y + p.anchorY
        let ink = kind == nil ? Theme.Map.branch(p.branch) ?? Theme.Map.secondary : Theme.kind(kind)
        ctx.draw(Text(Image(systemName: symbol(for: p, kind: kind))).font(Theme.Map.icon).foregroundStyle(ink), at: CGPoint(x: cx, y: iconY), anchor: .center)
        if p.badge, let badge = Theme.provenance(node.note(kind: "src")).badge {
            ctx.draw(Text(Image(systemName: badge)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.Map.tertiary),
                     at: CGPoint(x: cx + M.iconBox / 2 + 3, y: iconY - M.iconLine / 2 + 5), anchor: .center)
        }
        let nameY = p.y + M.openPadY + M.iconLine + M.iconGap + M.nameLine / 2
        ctx.draw(Text(p.name).font(p.depth == 0 ? Theme.Map.rootName : Theme.Map.name).foregroundStyle(Theme.Map.primary), at: CGPoint(x: cx, y: nameY), anchor: .center)
        for (i, note) in p.notes.enumerated() {
            let y = nameY + M.nameLine / 2 + (Double(i) + 0.5) * M.noteLine
            ctx.draw(noteText(note), at: CGPoint(x: cx, y: y), anchor: .center)
        }
    }

    /// The model's extras: a card in the colours of its provenance (world, guess, advice).
    private func drawCard(_ p: MapLayout.PlacedNode, _ node: Node, rect: CGRect, src: String?, in ctx: inout GraphicsContext) {
        typealias M = MapLayout.Metrics
        let card = Path(roundedRect: rect, cornerRadius: Theme.Map.corner)
        let style = Theme.provenance(src)
        let colours = Theme.Map.cardColours(src)
        // A soft lift, like GridClip's boxes.
        ctx.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 1), cornerRadius: Theme.Map.corner), with: .color(.black.opacity(0.06)))
        ctx.fill(card, with: .color(colours.fill))
        ctx.stroke(card, with: .color(colours.ink), style: StrokeStyle(lineWidth: style.lineWidth, dash: style.dash))
        if style.doubleBorder {
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerRadius: Theme.Map.corner - 3), with: .color(colours.ink), lineWidth: 1)
        }

        let nameY = p.y + M.padY + M.nameLine / 2
        var x = p.x + M.padX
        if p.glyph {
            let kind = node.note(kind: "kind")
            ctx.draw(Text(Image(systemName: symbol(for: p, kind: kind))).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.kind(kind)),
                     at: CGPoint(x: x + 6, y: nameY), anchor: .center)
            x += M.glyph
        }
        ctx.draw(Text(p.name).font(p.depth == 0 ? Theme.Map.rootName : Theme.Map.name).foregroundStyle(Theme.Map.primary), at: CGPoint(x: x, y: nameY), anchor: .leading)
        if p.badge, let badge = style.badge {
            ctx.draw(Text(Image(systemName: badge)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(colours.ink),
                     at: CGPoint(x: p.x + p.w - M.padX - M.badge / 2 + 3, y: nameY), anchor: .center)
        }
        for (i, note) in p.notes.enumerated() {
            let y = p.y + M.padY + M.nameLine + (Double(i) + 0.5) * M.noteLine
            ctx.draw(noteText(note), at: CGPoint(x: p.x + M.padX, y: y), anchor: .leading)
        }
    }

    /// `date 2026-11-03`: the kind is set quieter than what it says.
    private func noteText(_ note: String) -> Text {
        if let split = NoteKind.split(note), split.kind.count <= 12, !split.value.isEmpty {
            return Text(split.kind + " ").font(Theme.Map.note).foregroundStyle(Theme.Map.tertiary)
                + Text(split.value).font(Theme.Map.note).foregroundStyle(Theme.Map.secondary)
        }
        return Text(note).font(Theme.Map.note).foregroundStyle(Theme.Map.secondary)
    }

    private func drawEdge(_ e: MapLayout.PlacedEdge, _ edge: Edge?, lit: Bool, in ctx: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(e.p0))
        path.addCurve(to: CGPoint(e.p3), control1: CGPoint(e.p1), control2: CGPoint(e.p2))
        let src = edge?.note(kind: "src")
        let selected = session.selectedEdge == e.key
        let colour = selected ? Theme.accent : Theme.Map.branch(e.branch) ?? Theme.Map.tertiary
        let dash: [CGFloat] = src == "guess" ? [2, 3] : src == "world" ? [6, 4] : e.tree ? [] : [5, 4]
        let width: CGFloat = (e.tree ? 2 : 1.5) + (lit || selected ? 0.75 : 0)
        if src == "guess" { ctx.opacity *= 0.75 }
        ctx.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        if e.arrowEnd { arrow(&ctx, tip: e.p3, from: e.p2.x == e.p3.x && e.p2.y == e.p3.y ? e.p0 : e.p2, colour: colour) }
        if e.arrowStart { arrow(&ctx, tip: e.p0, from: e.p1.x == e.p0.x && e.p1.y == e.p0.y ? e.p3 : e.p1, colour: colour) }
    }

    private func arrow(_ ctx: inout GraphicsContext, tip: MapLayout.Point, from: MapLayout.Point, colour: Color) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let d = max(hypot(dx, dy), 0.001)
        let ux = dx / d, uy = dy / d
        let length = 7.0, half = 2.8
        var path = Path()
        path.move(to: CGPoint(x: tip.x, y: tip.y))
        path.addLine(to: CGPoint(x: tip.x - ux * length - uy * half, y: tip.y - uy * length + ux * half))
        path.addLine(to: CGPoint(x: tip.x - ux * length + uy * half, y: tip.y - uy * length - ux * half))
        path.closeSubpath()
        ctx.fill(path, with: .color(colour))
    }

    /// Labels sit on their curves on a chip of the map's own background.
    private func drawLabel(_ e: MapLayout.PlacedEdge, in ctx: inout GraphicsContext) {
        let lines = [(e.label, true), (e.note, false)].filter { !$0.0.isEmpty }
        for (i, line) in lines.enumerated() {
            var text = Text(line.0).font(Theme.Map.label).foregroundStyle(line.1 ? Theme.Map.secondary : Theme.Map.tertiary)
            if !e.tree { text = text.italic() }
            let resolved = ctx.resolve(text)
            let s = resolved.measure(in: CGSize(width: 1000, height: 100))
            let at = CGPoint(x: e.labelAt.x, y: e.labelAt.y + (Double(i) - Double(lines.count - 1) / 2) * MapLayout.Metrics.labelLine)
            let chip = CGRect(x: at.x - s.width / 2 - 4, y: at.y - s.height / 2 - 1, width: s.width + 8, height: s.height + 2)
            ctx.fill(Path(roundedRect: chip, cornerRadius: chip.height / 2), with: .color(Theme.Map.background.opacity(0.92)))
            ctx.draw(resolved, at: at, anchor: .center)
        }
    }

    // MARK: - Hit testing and gestures

    private func hit(_ point: CGPoint, _ layout: MapLayout) -> String? {
        let p = view.map(point)
        return layout.nodes.last { $0.contains(p) }?.id.name
    }

    private func hitEdge(_ point: CGPoint, _ layout: MapLayout) -> EdgeKey? {
        let p = view.map(point)
        let tolerance = Double(6 / view.k)
        for e in layout.edges {
            for i in 0...24 {
                let q = e.point(at: Double(i) / 24)
                if hypot(q.x - p.x, q.y - p.y) < tolerance { return e.key }
            }
        }
        return nil
    }

    private func select(at point: CGPoint, layout: MapLayout, additive: Bool) {
        withAnimation(Theme.selection) {
            if let name = hit(point, layout) {
                if additive { session.selection.formSymmetricDifference([name]) } else { session.selection = [name] }
                session.selectedEdge = nil
            } else if let key = hitEdge(point, layout) {
                session.selectedEdge = key
                session.selection = []
            } else if !additive {
                session.selection = []
                session.selectedEdge = nil
            }
        }
    }

    private func canvasDrag(layout: MapLayout) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if let link = linkDrag { linkDrag = (link.from, value.location); return }
                if let d = draggingNode { draggingNode = (d.name, value.translation); return }
                if boxSelect != nil { boxSelect = (value.startLocation, value.location); return }
                if let start = panStart {
                    go(Viewport(x: start.x + value.translation.width, y: start.y + value.translation.height, k: start.k), animate: false)
                    return
                }
                // The first movement decides what this drag is.
                hovered = nil
                if let name = hit(value.startLocation, layout) {
                    if NSEvent.modifierFlags.contains(.option) { linkDrag = (name, value.location) } else { draggingNode = (name, value.translation) }
                } else if NSEvent.modifierFlags.contains(.shift) {
                    boxSelect = (value.startLocation, value.location)
                } else {
                    touched = true
                    panStart = view
                }
            }
            .onEnded { value in
                if let link = linkDrag {
                    if let target = hit(value.location, layout), target != link.from { labelPrompt = (link.from, target) }
                    linkDrag = nil
                } else if let d = draggingNode {
                    if let c = session.displayedLayout.pinnedCenter(d.name, dx: d.offset.width / view.k, dy: d.offset.height / view.k) {
                        touched = true
                        session.dispatch(.pin(d.name, x: c.x, y: c.y))
                    }
                    draggingNode = nil
                } else if let box = boxSelect {
                    let a = view.map(box.start), b = view.map(box.end)
                    let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    session.selection = Set(layout.nodes.filter { rect.intersects(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)) }.map(\.id.name))
                    boxSelect = nil
                }
                panStart = nil
            }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(graph: Graph) -> some View {
        // Right-clicking a node acts on it, even when something else is selected.
        let target = hovered.flatMap { session.selection.contains($0) ? nil : $0 }
        let names = target.map { [$0] } ?? session.selection.sorted()
        if names.count == 1, let name = names.first, let node = graph.nodes[NodeID(name: name)] {
            Button("Expand") { session.expand(name) }
            Button("Rename…") { renameText = name; renameTarget = name }
            Button("Add comment…") { commentTarget = name }
            if ["world", "guess", "advice"].contains(node.note(kind: "src") ?? "") { Button("Confirm (mark as mine)") { session.dispatch(.confirm(name)) } }
            Divider()
            Menu("Kind") {
                ForEach(["person", "place", "thing", "action", "event", "idea"], id: \.self) { k in
                    Button { session.dispatch(.applyLines(["| \(name) @kind \(k)"], what: "kind \(name)")) } label: { Label(k.capitalized, systemImage: IconManifest.fallbackSymbol(kind: k)) }
                }
            }
            Menu("Icon") {
                ForEach(Array(session.icons.entries.keys.sorted().prefix(30)), id: \.self) { icon in
                    Button(icon) { session.dispatch(.applyLines(["| \(name) @icon \(icon)"], what: "icon \(name)")) }
                }
                if session.icons.entries.isEmpty { Text("Add SVGs to icons/ in the folder") }
            }
            if session.layout[name]?.pinned == true { Button("Release pin") { session.dispatch(.release(name)) } }
            Button("Show details") { session.selection = [name] }
            Divider()
            Button("Delete", role: .destructive) { session.dispatch(.delete(name)); session.selection = [] }
        } else if names.count > 1 {
            Button("Expand \(names.count) nodes") { names.forEach { session.expand($0) } }
            Divider()
            Button("Delete \(names.count) nodes", role: .destructive) { names.forEach { session.dispatch(.delete($0)) }; session.selection = [] }
        } else if let key = session.selectedEdge, let edge = graph.edges[key] {
            Button("Edit label…") { labelText = edge.labels.first ?? ""; labelPrompt = (edge.a.name, edge.b.name) }
            if ["world", "guess", "advice"].contains(edge.note(kind: "src") ?? "") {
                Button("Confirm") { session.dispatch(.applyLines(["| \(edge.a.name) @src user - | \(edge.b.name)"], what: "confirm edge")) }
            }
            Button("Add comment…") { commentTarget = edge.a.name }
            Divider()
            Button("Delete link", role: .destructive) {
                // The notation removes an edge only with a node: Transition rebuilds the endpoint without it.
                var without = graph
                without.edges.removeValue(forKey: key)
                session.dispatch(.applyLines(Transition.lines(from: graph, to: without), what: "delete edge \(edge.a.name) \(edge.b.name)"))
                session.selectedEdge = nil
            }
        } else {
            Button("Fit map") { refit() }
            if session.layout.nodes.contains(where: \.pinned) {
                Button("Release all pins") {
                    for p in session.layout.nodes where p.pinned { session.dispatch(.release(p.id.name)) }
                }
            }
        }
    }
}

/// Where the map is: screen = map × k + (x, y).
struct Viewport: Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var k: CGFloat = 1

    func screen(_ p: MapLayout.Point) -> CGPoint { CGPoint(x: x + CGFloat(p.x) * k, y: y + CGFloat(p.y) * k) }
    func map(_ p: CGPoint) -> MapLayout.Point { MapLayout.Point(x: Double((p.x - x) / k), y: Double((p.y - y) / k)) }

    /// Zoomed by `factor` (within bounds), keeping the map point under `p` where it is.
    func zoomed(by factor: CGFloat, at p: CGPoint) -> Viewport {
        let next = min(Theme.Map.maxZoom, max(Theme.Map.minZoom, k * factor))
        return Viewport(x: p.x - (p.x - x) * next / k, y: p.y - (p.y - y) * next / k, k: next)
    }

    /// Zoom glides in log space, so halving and doubling feel the same speed.
    func interpolated(to b: Viewport, at t: CGFloat) -> Viewport {
        Viewport(x: x + (b.x - x) * t, y: y + (b.y - y) * t, k: k * pow(b.k / k, t))
    }
}

struct Glide: Equatable {
    let from: Viewport
    let to: Viewport
    let start: Date
}

extension CGPoint {
    init(_ p: MapLayout.Point) { self.init(x: p.x, y: p.y) }
}

/// Zoom in, zoom out and fit: a small bar in the bottom right corner.
struct ZoomBar: View {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let fit: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            MapToolButton(symbol: "plus", help: "Zoom in (+)", action: zoomIn)
            MapToolButton(symbol: "minus", help: "Zoom out (−)", action: zoomOut)
            MapToolButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit the map (0)", action: fit)
        }
        .padding(3)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge - 2))
    }
}

/// A square icon button on a floating bar, lit on hover.
struct MapToolButton: View {
    let symbol: String
    let help: String
    var pressed = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(pressed ? Color.white : hover ? Color.primary : Color.secondary)
                .background(pressed ? Theme.accent : hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
        .onHover { hover = $0 }
        .animation(Theme.selection, value: hover)
    }
}

extension View {
    /// GridClip's floating control bar: a translucent surface, an inner hairline, a soft shadow.
    func floatingBar<S: InsettableShape>(in shape: S) -> some View {
        background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// What an empty map says.
struct EmptyMap: View {
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("No map yet").font(Theme.title)
            Text("Add text or audio in Context and press Submit,\nor drop a text or audio file here.").font(Theme.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(Theme.Space.l)
        .allowsHitTesting(false)
    }
}

/// The card over a hovered node: its full name, kind and provenance, notes and comments.
struct HoverCard: View {
    let node: Node
    let graph: Graph
    var pinned = false

    var body: some View {
        let kind = node.note(kind: "kind")
        let notes = MapLayout.shownNotes(node)
        let comments = Outline.comments(attachedTo: node.id.name, in: graph)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: IconManifest.fallbackSymbol(kind: kind)).foregroundStyle(Theme.kind(kind)).font(Theme.caption)
                Text(node.id.name).font(Theme.label).lineLimit(3)
            }
            let facts = [kind, node.note(kind: "src").map { "from \($0)" }, pinned ? "pinned" : nil, "\(graph.degree(of: node.id)) links"].compactMap { $0 }
            Text(facts.joined(separator: " · ")).font(Theme.caption).foregroundStyle(.secondary)
            if !notes.isEmpty || !comments.isEmpty {
                Divider()
                ForEach(notes, id: \.self) { Text($0).font(Theme.caption) }
                ForEach(comments, id: \.self) { Text($0).font(Theme.caption).italic().foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .padding(.horizontal, Theme.Space.s + 2)
        .padding(.vertical, Theme.Space.s)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2))
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
        .frame(width: 380)
    }
}

/// Scroll-wheel events: SwiftUI has no modifier, so an NSView reports them. Scrolling moves
/// the map; ⌘-scroll (or a mouse wheel's zoom) zooms about the pointer.
extension View {
    func onScrollWheel(_ action: @escaping (_ delta: CGSize, _ location: CGPoint, _ zooms: Bool) -> Void) -> some View {
        background(ScrollWheelCatcher(action: action))
    }
}

struct ScrollWheelCatcher: NSViewRepresentable {
    let action: (CGSize, CGPoint, Bool) -> Void
    func makeNSView(context: Context) -> ScrollView { let v = ScrollView(); v.action = action; return v }
    func updateNSView(_ nsView: ScrollView, context: Context) { nsView.action = action }

    /// Sits behind the map and takes the wheel events over its frame: SwiftUI's own views
    /// are what the pointer hits, so a local event monitor catches them on their way in.
    final class ScrollView: NSView {
        var action: ((CGSize, CGPoint, Bool) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location), !self.isHiddenOrHasHiddenAncestor else { return event }
                // A mouse wheel moves in lines; a trackpad in points.
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                self.action?(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale), location, event.modifierFlags.contains(.command))
                return nil
            }
        }
    }
}
