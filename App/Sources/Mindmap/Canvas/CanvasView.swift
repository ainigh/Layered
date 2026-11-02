import SwiftUI
import Harness

/// The mind map, drawn the way GridClip draws one: left-to-right trees on a dot grid that
/// travels with the map, each first-level branch in its own colour, cross-links dashed.
/// What the context or the user says is open (its icon above its name); the model's extras
/// are cards in their provenance's colours. Everything drawn comes from `session.displayedLayout`.
///
///   drag empty space      move the map          scroll        move the map
///   pinch, ⌘-scroll       zoom about the pointer double-click  zoom in there (on a node: expand)
///   + − 0, arrows         zoom, fit, move        hover a node  its card, its links drawn heavier
///   drag a node           pin it there (`@pos`)  ⌥-drag        link it to another node
///   ⇧-drag                select a box           right-click   the node's actions
///   click a node          select it: ⓘ beside it opens its details, ✎ renames it, ✦ expands it
///   F, ✦                  fill the view          spacing       the least room between nodes
///
/// The map fits the view when it opens and refits as the window resizes or the map grows,
/// until the user moves or zooms it. Buttons, keys and fit glide; drags follow the hand.
/// Fill the view fits the map, then lets its nodes slide into the room around them and
/// refits as they go, until zooming in gains nothing more (`Spread`); where they end up is
/// pinned in one turn, so one undo puts the map back.
///
/// What the model added and the user has not decided on yet (`session.review`) wears a
/// dashed ring, with ✓ (keep it) and ✕ (delete it) above its top right corner; a link
/// between nodes already there is tinted, with the pair under its label.
struct CanvasView: View {
    @Bindable var session: MapSession
    /// Where panels and bars float over the map (in `MapScroll.space`): the wheel over them is theirs.
    var shields: [CGRect] = []
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
    /// The link under the pointer (when no node is), drawn heavier.
    @State private var hoveredEdge: EdgeKey?
    /// The card of the map's keys (?).
    @State private var showKeys = false
    @State private var labelPrompt: (from: String, to: String)?
    @State private var labelText = ""
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var commentTarget: String?
    @State private var commentText = ""
    @State private var now = Date()
    /// The map while Fill the view rearranges it, and the work doing it.
    @State private var spreading: MapLayout?
    @State private var spreadTask: Task<Void, Never>?
    @State private var spreadFrom: MapLayout?
    /// The least room Fill the view leaves between two nodes, in map points.
    @AppStorage("map.spacing") private var spacing: Double = 24
    /// The map gliding from one layout to the next, and where the next glide starts when the
    /// canvas already shows it (a dropped node, a finished spread).
    @State private var morph: Morph?
    @State private var morphFrom: MapLayout?
    /// Find on the map: the bar is open, what it looks for, and which match is current.
    @State private var finding = false
    @State private var findText = ""
    @State private var findIndex = 0
    /// The overview in the bottom right, while some of the map is out of view.
    @AppStorage("map.minimap") private var minimapOn = true
    /// Redraws while a new node's glow fades (only then: see `onReceive`).
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        let graph = session.displayedGraph
        let live = session.displayedLayout
        let base = spreading ?? live
        // Read here so the canvas redraws when something is accepted or deleted.
        let _ = session.review
        let layout = draggingNode.map { base.moving($0.name, dx: $0.offset.width / view.k, dy: $0.offset.height / view.k) } ?? base
        let found = finding ? live.search(findText, in: graph) : []
        let current = found.isEmpty ? nil : found[min(findIndex, found.count - 1)]

        GeometryReader { geo in
            ZStack {
                TimelineView(.animation(paused: glide == nil && morph == nil)) { timeline in
                    let v = shown(at: timeline.date)
                    let t = morph.map { $0.progress(at: timeline.date) } ?? 1
                    let drawn = morph.map { layout.morphed(from: $0.from, t: t) } ?? layout
                    let marks = Marks(arrivals: morph?.arrivals ?? [], fade: t, found: Set(found), current: current)
                    Canvas(rendersAsynchronously: layout.nodes.count > 500) { ctx, size in
                        draw(graph: graph, layout: drawn, marks: marks, in: &ctx, size: size, v: v)
                    }
                }
                .gesture(canvasDrag(layout: layout))
                .simultaneousGesture(pinch)
                .onTapGesture(count: 2) { location in
                    if let b = hitButton(location, layout) { press(b); return }
                    if let name = hit(location, layout) { session.expand(name) } else { zoom(by: Theme.Map.zoomStep, at: location, animate: true) }
                }
                .onTapGesture(count: 1) { location in
                    select(at: location, layout: layout, additive: NSEvent.modifierFlags.contains(.shift))
                }
                .contextMenu { contextMenu(graph: graph) }
                .onContinuousHover { phase in
                    guard draggingNode == nil, panStart == nil else { return }
                    guard case .active(let p) = phase else { hovered = nil; hoveredEdge = nil; return }
                    // On the hovered node's fold button, the node stays hovered so the button stays.
                    if let name = hit(p, layout) { hovered = name } else if let b = hitButton(p, layout), b.kind == .fold, b.node == hovered {} else { hovered = nil }
                    let edge = hovered == nil ? hitEdge(p, layout) : nil
                    if edge != hoveredEdge { hoveredEdge = edge }
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in key(press) ? .handled : .ignored }

                if let hovered, draggingNode == nil, linkDrag == nil, let p = layout[hovered], let node = graph.nodes[NodeID(name: hovered)] {
                    let top = view.screen(MapLayout.Point(x: p.x + p.w / 2, y: p.y))
                    HoverCard(node: node, graph: graph, pinned: p.pinned, hidden: p.hiddenCount)
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
                if showKeys {
                    MapKeysCard { withAnimation(Theme.slide) { showKeys = false } }
                        .shieldsMapScroll()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                // Bottom centre, above the capture bar: the top of the map holds the action bar.
                VStack(spacing: Theme.Space.s) {
                    Spacer()
                    if finding {
                        FindBar(text: $findText, count: found.count, index: min(findIndex, max(0, found.count - 1)),
                                step: { stepFind($0, found) }, close: closeFind)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let turn = session.viewingTurn {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text("Turn \(turn), read-only").font(Theme.label)
                            Button("Back to now") { session.viewingTurn = nil }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                        .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.xs).padding(.vertical, Theme.Space.xs)
                        .floatingBar(in: Capsule())
                    }
                }
                .padding(Theme.Space.m)
                .padding(.bottom, 52)
                if minimapOn, live.nodes.count > 1, !inView(live) {
                    Minimap(layout: live, view: view, viewSize: size) { point, animate in centre(on: point, animate: animate) }
                        .shieldsMapScroll()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        // Left of the zoom column, above the Model log's pill.
                        .padding(.trailing, Theme.Space.m + ZoomBar.width + Theme.Space.s)
                        .padding(.bottom, Theme.Space.m + 30 + Theme.Space.s)
                        .transition(.opacity)
                }
                // The Model log's button sits to their left (`ModelLogDrawer`).
                VStack(spacing: Theme.Space.s) {
                    SpacingBar(spacing: $spacing) { fillView(restart: true) }
                    ZoomBar(zoomIn: { zoom(by: Theme.Map.zoomStep) }, zoomOut: { zoom(by: 1 / Theme.Map.zoomStep) }, fit: refit,
                            fill: { fillView() }, filling: spreadTask != nil, minimap: $minimapOn)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(Theme.Space.m)
            }
            .background(Theme.Map.background)
            .clipped()
            .animation(Theme.selection, value: hovered)
            .animation(Theme.slide, value: finding)
            .animation(Theme.slide, value: showKeys)
            .onScrollWheel(shields: shields) { delta, location, zooms in
                if zooms {
                    zoom(by: exp(delta.height * 0.01), at: location, animate: false)
                } else {
                    touched = true
                    go(Viewport(x: view.x + delta.width, y: view.y + delta.height, k: view.k), animate: false)
                }
            }
            .onAppear { size = geo.size; fit(layout: base, animate: false) }
            .onChange(of: geo.size) { _, s in size = s; if !touched { fit(layout: base, animate: false) } }
            .onChange(of: live) { old, next in
                // The map changed under a spread: what it was arranging is gone.
                if next != spreadFrom { finishSpread(commit: false) }
                startMorph(from: morphFrom ?? onScreen(old), to: next)
                morphFrom = nil
                if !touched { fit(layout: next, animate: true) }
            }
            .onChange(of: session.findRequests) { _, _ in openFind() }
            .onChange(of: session.focusRequests) { _, _ in if let name = session.focused { bringIntoView(name) } }
            .onChange(of: findText) { _, _ in
                findIndex = 0
                if let first = live.search(findText, in: graph).first { show(found: first) }
            }
            .onDisappear { finishSpread(commit: false) }
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
                if let old = renameTarget {
                    RenamePrompt(old: old, text: renameText, exists: { session.state.graph.node($0) != nil }) { new in
                        session.dispatch(.rename(old, to: new))
                        session.selection = [Canonicaliser.canonical(new)]
                        renameTarget = nil
                    }
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

    /// The whole map in view, centred, zoomed in until its widest or tallest side meets the
    /// view's edges (less `fitPad`): any further zoom would push a node out of view.
    private func fit(layout: MapLayout, animate: Bool) {
        guard size.width > 0, !layout.nodes.isEmpty else { return }
        let pad = Theme.Map.fitPad
        let w = CGFloat(layout.width), h = CGFloat(layout.height)
        let k = max(Theme.Map.minZoom, min(Theme.Map.maxZoom, (size.width - 2 * pad) / max(1, w), (size.height - 2 * pad) / max(1, h)))
        let x: CGFloat = (size.width - w * k) / 2 - CGFloat(layout.minX) * k
        let y: CGFloat = max(pad, (size.height - h * k) / 2) - CGFloat(layout.minY) * k
        go(Viewport(x: x, y: y, k: k), animate: animate)
    }

    private func refit() {
        touched = false
        fit(layout: session.displayedLayout, animate: true)
    }

    /// Is the whole map on screen at the current view?
    private func inView(_ layout: MapLayout) -> Bool {
        guard size.width > 0 else { return true }
        let a = view.screen(MapLayout.Point(x: layout.minX, y: layout.minY))
        let b = view.screen(MapLayout.Point(x: layout.maxX, y: layout.maxY))
        return a.x >= -1 && a.y >= -1 && b.x <= size.width + 1 && b.y <= size.height + 1
    }

    /// Moves the view so the map point `p` is at its centre, at the same zoom.
    private func centre(on p: MapLayout.Point, animate: Bool) {
        touched = true
        go(Viewport(x: size.width / 2 - CGFloat(p.x) * view.k, y: size.height / 2 - CGFloat(p.y) * view.k, k: view.k), animate: animate)
    }

    /// Brings a node into view (gliding as little as it takes), unless it already is.
    private func bringIntoView(_ name: String) {
        guard let p = session.displayedLayout[name], size.width > 0 else { return }
        let margin: CGFloat = 60
        let a = view.screen(MapLayout.Point(x: p.x, y: p.y)), b = view.screen(MapLayout.Point(x: p.x + p.w, y: p.y + p.h))
        var dx: CGFloat = 0, dy: CGFloat = 0
        if b.x - a.x > size.width - 2 * margin || b.y - a.y > size.height - 2 * margin {
            centre(on: p.center, animate: true)
            return
        }
        if a.x < margin { dx = margin - a.x } else if b.x > size.width - margin { dx = size.width - margin - b.x }
        if a.y < margin { dy = margin - a.y } else if b.y > size.height - margin { dy = size.height - margin - b.y }
        guard dx != 0 || dy != 0 else { return }
        touched = true
        go(Viewport(x: view.x + dx, y: view.y + dy, k: view.k), animate: true)
    }

    /// Zooms to the selection: its nodes fill the view, no closer than 1.5×.
    private func focusSelection() {
        let nodes = session.selection.compactMap { session.displayedLayout[$0] }
        guard !nodes.isEmpty, size.width > 0 else { return }
        let x0 = nodes.map(\.x).min()!, y0 = nodes.map(\.y).min()!
        let x1 = nodes.map { $0.x + $0.w }.max()!, y1 = nodes.map { $0.y + $0.h }.max()!
        let pad: CGFloat = 80
        let k = max(Theme.Map.minZoom, min(1.5, (size.width - 2 * pad) / max(1, CGFloat(x1 - x0)), (size.height - 2 * pad) / max(1, CGFloat(y1 - y0))))
        touched = true
        go(Viewport(x: size.width / 2 - CGFloat(x0 + x1) / 2 * k, y: size.height / 2 - CGFloat(y0 + y1) / 2 * k, k: k), animate: true)
    }

    // MARK: - Moving between layouts

    /// What is on screen of `layout` now: itself, or a point on the glide toward it.
    private func onScreen(_ layout: MapLayout) -> MapLayout {
        guard let morph else { return layout }
        return layout.morphed(from: morph.from, t: morph.progress(at: Date()))
    }

    /// The map glides from what was on screen to its new layout: nodes slide to their new
    /// places, new ones grow out of their parents and fade in.
    private func startMorph(from old: MapLayout, to next: MapLayout) {
        guard !reduceMotion, spreading == nil, next.nodes.count <= Morph.maxNodes, old != next else { morph = nil; return }
        let m = Morph(from: old, arrivals: next.arrivals(since: old), start: Date())
        morph = m
        DispatchQueue.main.asyncAfter(deadline: .now() + Morph.duration + 0.05) { if morph == m { morph = nil } }
    }

    // MARK: - Find on the map

    private func openFind() {
        withAnimation(Theme.slide) { finding = true }
    }

    private func closeFind() {
        withAnimation(Theme.slide) { finding = false }
        findText = ""
        findIndex = 0
    }

    /// The next match (`by` 1) or the one before (−1), wrapping round.
    private func stepFind(_ by: Int, _ found: [String]) {
        guard !found.isEmpty else { return }
        findIndex = ((min(findIndex, found.count - 1) + by) % found.count + found.count) % found.count
        show(found: found[findIndex])
    }

    /// A match selected and in view, its fold opened if one hides it.
    private func show(found name: String) {
        session.reveal(name)
        withAnimation(Theme.selection) {
            session.selection = [name]
            session.selectedEdge = nil
        }
        bringIntoView(name)
    }

    /// Fill the view: the map arranged afresh (its pins ignored) and fitted, then its nodes
    /// slide into the room around them while it refits, until zooming in gains nothing more.
    /// Pressed again while it runs, it stops there; `restart` starts it over (the spacing changed).
    private func fillView(restart: Bool = false) {
        if spreadTask != nil {
            finishSpread(commit: true)
            if !restart { return }
        }
        let live = session.displayedLayout
        guard size.width > 0, session.viewingTurn == nil, live.nodes.count > 1 else { refit(); return }
        let start = session.autoArranged()
        let pad = Theme.Map.fitPad
        let first = Spread(layout: start, viewWidth: Double(size.width - 2 * pad), viewHeight: Double(size.height - 2 * pad),
                           gap: spacing, maxZoom: Double(Theme.Map.maxZoom))
        touched = false
        spreadFrom = live
        spreadTask = Task { @MainActor in
            var spread = first
            // The fresh arrangement first, for a moment, then the spread from there.
            spreading = start
            fit(layout: start, animate: true)
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            show(spread, from: start)
            while !spread.finished {
                let now = spread
                spread = await Task.detached(priority: .userInitiated) { var next = now; next.run(limit: 4); return next }.value
                guard !Task.isCancelled else { return }
                show(spread, from: start)
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            finishSpread(commit: true)
        }
    }

    private func show(_ spread: Spread, from start: MapLayout) {
        let shown = start.placing(spread.centers)
        spreading = shown
        fit(layout: shown, animate: false)
    }

    /// Ends a spread: with `commit`, the nodes are pinned where it got them to (one turn).
    private func finishSpread(commit: Bool) {
        spreadTask?.cancel()
        spreadTask = nil
        spreadFrom = nil
        if commit, let shown = spreading {
            spreading = nil
            touched = false
            // The map is already where the spread left it: no glide from the old arrangement.
            morphFrom = shown
            session.dispatch(.arrange(Dictionary(uniqueKeysWithValues: shown.nodes.map {
                ($0.id.name, Position(x: $0.center.x.rounded(), y: $0.center.y.rounded()))
            })))
        }
        spreading = nil
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

    /// Keys on the map. With one node selected: the arrows go from node to node (left to its
    /// parent, right to a child, up and down along its column), ↩ renames it, space opens its
    /// details, / folds or opens its branch; ⌫ deletes the selection (⌘Z brings it back), Z zooms
    /// to it, esc lets it go. Otherwise (or with ⇧) the arrows move the map. M shows or hides
    /// the overview.
    private func key(_ press: KeyPress) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        let one = session.selection.count == 1 ? session.selection.first : nil
        let live = session.viewingTurn == nil
        switch press.characters {
        case "+", "=": zoom(by: Theme.Map.zoomStep); return true
        case "-", "_": zoom(by: 1 / Theme.Map.zoomStep); return true
        case "0": refit(); return true
        case "f", "F": fillView(); return true
        case "m", "M": withAnimation(Theme.slide) { minimapOn.toggle() }; return true
        case "?": withAnimation(Theme.slide) { showKeys.toggle() }; return true
        case "z", "Z":
            guard !session.selection.isEmpty else { return false }
            focusSelection(); return true
        case "/":
            guard live, let one, let p = session.displayedLayout[one], p.childCount > 0 else { return false }
            withAnimation(Theme.selection) { session.toggleFold(one) }
            return true
        default: break
        }
        switch press.key {
        case .escape:
            if showKeys { withAnimation(Theme.slide) { showKeys = false }; return true }
            if finding { closeFind(); return true }
            guard !session.selection.isEmpty || session.selectedEdge != nil else { return false }
            withAnimation(Theme.selection) { session.selection = []; session.selectedEdge = nil }
            return true
        case .return:
            guard live, let one else { return false }
            renameText = one; renameTarget = one
            return true
        case .space:
            guard let one else { return false }
            session.selection = [one]
            session.detailsRequests += 1
            return true
        case .delete, .deleteForward:
            guard live, !session.selection.isEmpty else { return false }
            for name in session.selection.sorted() { session.dispatch(.delete(name)) }
            session.selection = []
            return true
        default: break
        }
        if let one, !press.modifiers.contains(.shift) {
            let direction: MapLayout.Direction?
            switch press.key {
            case .leftArrow: direction = .left
            case .rightArrow: direction = .right
            case .upArrow: direction = .up
            case .downArrow: direction = .down
            default: direction = nil
            }
            if let direction {
                if let next = session.displayedLayout.neighbour(of: one, direction) {
                    withAnimation(Theme.selection) { session.selection = [next]; session.selectedEdge = nil }
                    bringIntoView(next)
                }
                return true
            }
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

    private func draw(graph: Graph, layout: MapLayout, marks: Marks, in ctx: inout GraphicsContext, size: CGSize, v: Viewport) {
        drawDots(&ctx, size: size, v: v)
        let detail = Detail(zoom: v.k)

        // The hovered node's links draw a little heavier; nothing else changes.
        var litEdges = Set<EdgeKey>()
        if let hovered, draggingNode == nil {
            for e in layout.edges where e.key.lo.name == hovered || e.key.hi.name == hovered { litEdges.insert(e.key) }
        }
        if let hoveredEdge, draggingNode == nil { litEdges.insert(hoveredEdge) }

        var world = ctx
        world.translateBy(x: v.x, y: v.y)
        world.scaleBy(x: v.k, y: v.k)
        // Only what is on screen is drawn (with a margin for icons, rings and labels).
        let seen = CGRect(x: -v.x / v.k, y: -v.y / v.k, width: size.width / v.k, height: size.height / v.k).insetBy(dx: -60 / v.k, dy: -40 / v.k)

        for e in layout.edges {
            let box = CGRect(x: min(e.p0.x, e.p3.x), y: min(e.p0.y, e.p3.y), width: abs(e.p3.x - e.p0.x), height: abs(e.p3.y - e.p0.y))
                .union(CGRect(x: min(e.p1.x, e.p2.x), y: min(e.p1.y, e.p2.y), width: abs(e.p2.x - e.p1.x), height: abs(e.p2.y - e.p1.y)))
            guard box.insetBy(dx: -2, dy: -2).intersects(seen) else { continue }
            var layer = world
            layer.opacity = marks.opacity(e.key.lo.name, e.key.hi.name)
            drawEdge(e, graph.edges[e.key], depth: layout.depth(of: e), lit: litEdges.contains(e.key), in: &layer)
        }
        // A node being dragged leaves a ghost where it was.
        if let d = draggingNode, let from = session.displayedLayout[d.name] {
            let ghost = Path(roundedRect: CGRect(x: from.x, y: from.y, width: from.w, height: from.h).insetBy(dx: -3, dy: -3), cornerRadius: Theme.Map.corner + 3)
            world.stroke(ghost, with: .color(Theme.Map.tertiary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        // What a box being drawn would select, lit as the box grows.
        let boxed: CGRect? = boxSelect.map { box in
            let a = v.map(box.start), b = v.map(box.end)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
        for p in layout.nodes {
            let rect = CGRect(x: p.x, y: p.y, width: p.w, height: p.h)
            guard let node = graph.nodes[p.id], rect.intersects(seen) else { continue }
            var layer = world
            layer.opacity = marks.opacity(p.id.name)
            if draggingNode?.name == p.id.name {
                layer.addFilter(.shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4))
            }
            if let boxed, boxed.intersects(rect) {
                layer.fill(Path(roundedRect: rect.insetBy(dx: -3.5, dy: -3.5), cornerRadius: Theme.Map.corner + 3.5), with: .color(Theme.accent.opacity(0.12)))
            }
            if marks.found.contains(p.id.name) { drawFound(p, current: marks.current == p.id.name, in: &layer) }
            drawNode(p, node, detail: detail, in: &layer)
        }
        // Labels last, so no curve runs through them; too small to read, they are left out.
        if detail == .full {
            for e in layout.edges where (!e.label.isEmpty || !e.note.isEmpty) && seen.contains(CGPoint(e.labelAt)) {
                var layer = world
                layer.opacity = marks.opacity(e.key.lo.name, e.key.hi.name)
                drawLabel(e, in: &layer)
            }
        }
        // Zoomed far out, the trees' roots and first branches are named at a size to read.
        if detail == .shapes { drawOverviewNames(graph: graph, layout: layout, marks: marks, in: &ctx, size: size, v: v) }
        // Buttons on top, the same size at any zoom.
        for b in mapButtons(layout, v) { drawMapButton(b, in: &ctx) }

        if let linkDrag, let p = layout[linkDrag.from] {
            // The node it would link to is ringed; the line ends on it.
            let target = hit(linkDrag.to, layout).flatMap { $0 == linkDrag.from ? nil : layout[$0] }
            let start = v.screen(MapLayout.Point(x: p.x + p.w, y: p.y + p.h / 2))
            var end = linkDrag.to
            if let t = target {
                let r = CGRect(origin: v.screen(MapLayout.Point(x: t.x, y: t.y)), size: CGSize(width: t.w * v.k, height: t.h * v.k)).insetBy(dx: -4, dy: -4)
                ctx.fill(Path(roundedRect: r, cornerRadius: (Theme.Map.corner + 4) * v.k), with: .color(Theme.accent.opacity(0.12)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: (Theme.Map.corner + 4) * v.k), with: .color(Theme.accent), lineWidth: 1.5)
                end = CGPoint(x: r.minX, y: r.midY)
            }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            ctx.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
            arrow(&ctx, tip: MapLayout.Point(x: end.x, y: end.y), from: MapLayout.Point(x: start.x, y: start.y), colour: Theme.accent, scale: 1.4)
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

    private func drawNode(_ p: MapLayout.PlacedNode, _ node: Node, detail: Detail, in ctx: inout GraphicsContext) {
        let rect = CGRect(x: p.x, y: p.y, width: p.w, height: p.h)
        let src = node.note(kind: "src")
        let selected = session.selection.contains(p.id.name)
        // What just arrived glows, fading over a few seconds.
        let age = session.highlighted[p.id.name].map { now.timeIntervalSince($0) } ?? .infinity

        if src == "guess" { ctx.opacity *= Theme.provenance(src).opacity }
        if age < Theme.highlightSeconds {
            let glow = 0.24 * (1 - age / Theme.highlightSeconds)
            ctx.fill(Path(roundedRect: rect.insetBy(dx: -6, dy: -6), cornerRadius: Theme.Map.corner + 6), with: .color(Theme.accent.opacity(glow)))
        }
        if !p.boxed {
            // A tree's root sits on a plate; a hovered node is lit on one.
            let root = p.depth == 0 && p.childCount > 0
            if root || hovered == p.id.name || draggingNode?.name == p.id.name {
                let plate = Path(roundedRect: rect.insetBy(dx: -4, dy: -2), cornerRadius: Theme.Map.corner + 2)
                ctx.fill(plate, with: .color(Theme.Map.primary.opacity(root ? 0.05 : 0.04)))
                if root { ctx.stroke(plate, with: .color(Theme.Map.primary.opacity(0.1)), lineWidth: 0.75) }
            }
        }
        if selected {
            let ring = Path(roundedRect: rect.insetBy(dx: -3.5, dy: -3.5), cornerRadius: Theme.Map.corner + 3.5)
            // A hairline: the tint shows what is selected, the line only edges it.
            ctx.fill(ring, with: .color(Theme.accent.opacity(0.1)))
            ctx.stroke(ring, with: .color(Theme.accent), lineWidth: 0.5)
        }
        if session.viewingTurn == nil, session.review.nodes.contains(p.id.name) {
            let ring = Path(roundedRect: rect.insetBy(dx: -6, dy: -6), cornerRadius: Theme.Map.corner + 6)
            ctx.fill(ring, with: .color(Theme.accent.opacity(0.06)))
            ctx.stroke(ring, with: .color(Theme.accent.opacity(0.8)), style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
        }
        if p.boxed { drawCard(p, node, rect: rect, src: src, detail: detail, in: &ctx) } else { drawOpen(p, node, detail: detail, in: &ctx) }
    }

    /// A match of Find on the map: a warm ring, filled for the current one.
    private func drawFound(_ p: MapLayout.PlacedNode, current: Bool, in ctx: inout GraphicsContext) {
        let ring = Path(roundedRect: CGRect(x: p.x, y: p.y, width: p.w, height: p.h).insetBy(dx: -5, dy: -5), cornerRadius: Theme.Map.corner + 5)
        let ink = Color(nsColor: .systemYellow)
        ctx.fill(ring, with: .color(ink.opacity(current ? 0.32 : 0.14)))
        ctx.stroke(ring, with: .color(ink.opacity(current ? 1 : 0.7)), lineWidth: current ? 2 : 1)
    }

    /// Text too small to read drawn as a soft bar as long as it, so the map keeps its shape.
    private func drawGreek(_ line: String, x: Double, y: Double, anchor: UnitPoint, maxWidth: Double, ink: Color, in ctx: inout GraphicsContext) {
        let w = min(maxWidth, Double(line.count) * 6.6)
        let h = 7.0
        let x0 = anchor == .center ? x - w / 2 : x
        ctx.fill(Path(roundedRect: CGRect(x: x0, y: y - h / 2, width: w, height: h), cornerRadius: h / 2), with: .color(ink.opacity(0.3)))
    }

    /// Zoomed far out: each tree's root and first-level branches named on a chip, at a size
    /// to read, the roots first; a name that would cover one already drawn is left out.
    private func drawOverviewNames(graph: Graph, layout: MapLayout, marks: Marks, in ctx: inout GraphicsContext, size: CGSize, v: Viewport) {
        var taken: [CGRect] = []
        let screen = CGRect(origin: .zero, size: size)
        let order = layout.nodes.filter { $0.depth <= 1 && ($0.depth == 1 || $0.childCount > 0) }.sorted { ($0.depth, -$0.childCount) < ($1.depth, -$1.childCount) }
        for p in order.prefix(120) {
            let at = v.screen(p.center)
            guard screen.contains(at) else { continue }
            let root = p.depth == 0
            let ink = root ? Theme.Map.primary : Theme.Map.branch(p.branch) ?? Theme.Map.primary
            let text = ctx.resolve(Text(p.name).font(.system(size: root ? 13 : 11.5, weight: root ? .bold : .semibold)).foregroundStyle(ink))
            let s = text.measure(in: CGSize(width: 220, height: 40))
            let chip = CGRect(x: at.x - s.width / 2 - 6, y: at.y - s.height / 2 - 2, width: s.width + 12, height: s.height + 4)
            guard !taken.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(chip) }) else { continue }
            taken.append(chip)
            var layer = ctx
            layer.opacity = marks.opacity(p.id.name)
            layer.fill(Path(roundedRect: chip, cornerRadius: chip.height / 2), with: .color(Theme.Map.background.opacity(0.9)))
            layer.stroke(Path(roundedRect: chip, cornerRadius: chip.height / 2), with: .color(ink.opacity(0.35)), lineWidth: 1)
            layer.draw(text, in: chip.insetBy(dx: 6, dy: 2))
        }
    }

    /// A round button drawn on the map: ✓ or ✕ for something waiting for review, or ⓘ
    /// (details on the right), ✎ (rename) and ✦ (expand, staying on the map) beside a
    /// selected node.
    private struct MapButton {
        enum Kind { case accept, reject, details, rename, expand, fold, unfold }
        let at: CGPoint
        let kind: Kind
        var node: String?
        var edge: EdgeKey?
        var enabled = true
        /// Unfold: how many nodes the fold hides (its button reads “+n”).
        var count = 0
        /// The branch's colour, for fold buttons.
        var tint: Color?
        static let radius: CGFloat = 9

        /// Round, or a pill wide enough for “+n”.
        var width: CGFloat { kind == .unfold ? Self.foldWidth(count) : 2 * Self.radius }
        static func foldWidth(_ count: Int) -> CGFloat { max(2 * radius, CGFloat("+\(count)".count) * 6.2 + 10) }
    }

    /// ✓ ✕ above a node's top right corner, or under a link's label (on its curve when it
    /// has none); ⓘ ✎ ✦ down the right side of each selected node.
    private func mapButtons(_ layout: MapLayout, _ v: Viewport) -> [MapButton] {
        guard session.viewingTurn == nil else { return [] }
        let r = MapButton.radius
        var out: [MapButton] = []
        for name in session.review.nodes.sorted() {
            guard let p = layout[name] else { continue }
            let corner = v.screen(MapLayout.Point(x: p.x + p.w, y: p.y))
            let y = corner.y - r - 4
            out.append(MapButton(at: CGPoint(x: corner.x - r - 1, y: y), kind: .accept, node: name))
            out.append(MapButton(at: CGPoint(x: corner.x + r + 1, y: y), kind: .reject, node: name))
        }
        for key in session.review.edges.sorted() {
            guard let e = layout.edges.first(where: { $0.key == key }) else { continue }
            let at = v.screen(e.labelAt)
            let lines = [e.label, e.note].filter { !$0.isEmpty }.count
            let y = at.y + (lines == 0 ? 0 : CGFloat(Double(lines) * MapLayout.Metrics.labelLine / 2) * v.k + r + 2)
            out.append(MapButton(at: CGPoint(x: at.x - r - 1, y: y), kind: .accept, edge: key))
            out.append(MapButton(at: CGPoint(x: at.x + r + 1, y: y), kind: .reject, edge: key))
        }
        // Where a branch leaves its node: “+n” to open a folded one; on the hovered or
        // selected node, − to fold it.
        var foldRight: [String: CGFloat] = [:]
        if draggingNode == nil {
            for p in layout.nodes where p.hiddenCount > 0 || (p.childCount > 0 && (p.id.name == hovered || session.selection.contains(p.id.name))) {
                let folded = p.hiddenCount > 0
                let anchor = v.screen(MapLayout.Point(x: p.x + p.w - p.anchorInset, y: p.y + p.anchorY))
                let w = folded ? MapButton.foldWidth(p.hiddenCount) : 2 * r
                out.append(MapButton(at: CGPoint(x: anchor.x + 3 + w / 2, y: anchor.y), kind: folded ? .unfold : .fold, node: p.id.name,
                                     count: p.hiddenCount, tint: Theme.Map.branch(p.branch)))
                foldRight[p.id.name] = anchor.x + 3 + w
            }
        }
        if draggingNode == nil {
            for name in session.selection.sorted().prefix(24) {
                guard let p = layout[name] else { continue }
                let side = v.screen(MapLayout.Point(x: p.x + p.w, y: p.y + p.h / 2))
                let x = max(side.x, foldRight[name] ?? side.x) + r + 6
                out.append(MapButton(at: CGPoint(x: x, y: side.y - 2 * r - 2), kind: .details, node: name))
                out.append(MapButton(at: CGPoint(x: x, y: side.y), kind: .rename, node: name))
                out.append(MapButton(at: CGPoint(x: x, y: side.y + 2 * r + 2), kind: .expand, node: name, enabled: session.running == nil))
            }
        }
        return out
    }

    private func drawMapButton(_ b: MapButton, in ctx: inout GraphicsContext) {
        let r = MapButton.radius
        let rect = CGRect(x: b.at.x - b.width / 2, y: b.at.y - r, width: b.width, height: 2 * r)
        let shape = Path(roundedRect: rect, cornerRadius: r)
        let ink: Color, symbol: String
        switch b.kind {
        case .accept: ink = .green; symbol = "checkmark"
        case .reject: ink = .red; symbol = "xmark"
        case .details: ink = Theme.accent; symbol = "info"
        case .rename: ink = Theme.accent; symbol = "pencil"
        case .expand: ink = Theme.accent; symbol = "sparkles"
        case .fold: ink = b.tint ?? Theme.Map.secondary; symbol = "minus"
        case .unfold: ink = b.tint ?? Theme.Map.secondary; symbol = ""
        }
        var layer = ctx
        if !b.enabled { layer.opacity = 0.4 }
        layer.fill(Path(roundedRect: rect.offsetBy(dx: 0, dy: 1), cornerRadius: r), with: .color(.black.opacity(0.12)))
        layer.fill(shape, with: .color(Theme.Map.background))
        if b.kind == .unfold {
            // A folded branch: its count on a tint of the branch's colour.
            layer.fill(shape, with: .color(ink.opacity(0.14)))
            layer.stroke(shape, with: .color(ink.opacity(0.8)), lineWidth: 1)
            layer.draw(Text("+\(b.count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(ink), at: b.at, anchor: .center)
            return
        }
        layer.stroke(shape, with: .color(ink.opacity(0.7)), lineWidth: 1)
        layer.draw(Text(Image(systemName: symbol)).font(.system(size: 8.5, weight: .bold)).foregroundStyle(ink), at: b.at, anchor: .center)
    }

    /// The map button under a click, if any.
    private func hitButton(_ point: CGPoint, _ layout: MapLayout) -> MapButton? {
        mapButtons(layout, view).last { abs($0.at.x - point.x) <= $0.width / 2 + 2 && abs($0.at.y - point.y) <= MapButton.radius + 2 }
    }

    private func press(_ b: MapButton) {
        guard b.enabled else { return }
        withAnimation(Theme.selection) {
            switch (b.kind, b.node, b.edge) {
            case (.accept, let name?, _): session.accept(node: name)
            case (.reject, let name?, _): session.reject(node: name)
            case (.accept, nil, let key?): session.accept(edge: key)
            case (.reject, nil, let key?): session.reject(edge: key)
            case (.details, let name?, _): session.selection = [name]; session.detailsRequests += 1
            case (.rename, let name?, _): renameText = name; renameTarget = name
            case (.expand, let name?, _): session.expand(name)
            case (.fold, let name?, _): session.setFolded(name, true)
            case (.unfold, let name?, _): session.setFolded(name, false)
            default: break
            }
        }
    }


    /// From the context or the user: the icon above the name, no card.
    private func drawOpen(_ p: MapLayout.PlacedNode, _ node: Node, detail: Detail, in ctx: inout GraphicsContext) {
        typealias M = MapLayout.Metrics
        let kind = node.note(kind: "kind")
        let cx = p.x + p.w / 2
        let iconY = p.y + p.anchorY
        let ink = IconTint.of(p.id.name).map(Theme.tint) ?? (kind == nil ? Theme.Map.branch(p.branch) ?? Theme.Map.secondary : Theme.kind(kind))
        let nameY = p.y + M.openPadY + M.iconLine + M.iconGap + M.nameLine / 2
        if detail == .shapes {
            // Far out: a dot of the icon's colour, the name as a bar.
            let d = M.iconBox - 8
            ctx.fill(Path(ellipseIn: CGRect(x: cx - d / 2, y: iconY - d / 2, width: d, height: d)), with: .color(ink.opacity(0.85)))
            for (i, line) in p.nameLines.enumerated() {
                drawGreek(line, x: cx, y: nameY + Double(i) * M.nameLine, anchor: .center, maxWidth: p.w, ink: Theme.Map.primary, in: &ctx)
            }
            return
        }
        let symbols = session.symbols(for: node)
        let stack = M.iconStack(symbols.count)
        drawStack(symbols, from: cx - stack / 2 + M.iconBox / 2, y: iconY, step: M.iconStep, disc: M.iconBox - 2,
                  font: Theme.Map.icon, ink: ink, behind: Theme.Map.background, in: &ctx)
        if symbols.count > M.maxIcons {
            ctx.draw(Text("+\(symbols.count - M.maxIcons)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Map.secondary),
                     at: CGPoint(x: cx + stack / 2 - M.moreIcons / 2, y: iconY), anchor: .center)
        }
        if p.badge, let badge = Theme.provenance(node.note(kind: "src")).badge {
            ctx.draw(Text(Image(systemName: badge)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.Map.tertiary),
                     at: CGPoint(x: cx + stack / 2 + 3, y: iconY - M.iconLine / 2 + 5), anchor: .center)
        }
        for (i, line) in p.nameLines.enumerated() {
            ctx.draw(Text(line).font(p.depth == 0 ? Theme.Map.rootName : Theme.Map.name).foregroundStyle(Theme.Map.primary),
                     at: CGPoint(x: cx, y: nameY + Double(i) * M.nameLine), anchor: .center)
        }
        guard detail == .full else { return }
        for (i, note) in p.notes.enumerated() {
            let y = nameY + (Double(p.nameLines.count) - 0.5) * M.nameLine + (Double(i) + 0.5) * M.noteLine
            ctx.draw(noteText(note), at: CGPoint(x: cx, y: y), anchor: .center)
        }
    }

    /// A node's icons side by side, each overlapping the next and drawn over it (the first on
    /// top), on a disc of what is behind so the one under it is hidden there and a part of
    /// each shows. Up to `maxIcons`; one icon is drawn as it always was, with no disc.
    private func drawStack(_ symbols: [String], from x: Double, y: Double, step: Double, disc: Double,
                           font: Font, ink: Color, behind: Color, in ctx: inout GraphicsContext) {
        typealias M = MapLayout.Metrics
        let shown = Array(symbols.prefix(M.maxIcons))
        for (i, symbol) in shown.enumerated().reversed() {
            let center = CGPoint(x: x + Double(i) * step, y: y)
            if shown.count > 1 {
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - disc / 2, y: center.y - disc / 2, width: disc, height: disc)), with: .color(behind))
            }
            ctx.draw(Text(Image(systemName: symbol)).font(font).foregroundStyle(ink), at: center, anchor: .center)
        }
    }

    /// The model's extras: a card in the colours of its provenance (world, guess, advice).
    private func drawCard(_ p: MapLayout.PlacedNode, _ node: Node, rect: CGRect, src: String?, detail: Detail, in ctx: inout GraphicsContext) {
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
        if detail == .shapes {
            for (i, line) in p.nameLines.enumerated() {
                drawGreek(line, x: x, y: nameY + Double(i) * M.nameLine, anchor: .leading, maxWidth: p.w - 2 * M.padX, ink: Theme.Map.primary, in: &ctx)
            }
            return
        }
        if p.glyph {
            let kind = node.note(kind: "kind")
            let symbols = Array(session.symbols(for: node).prefix(M.maxIcons))
            drawStack(symbols, from: x + 6, y: nameY, step: M.glyphStep, disc: 14,
                      font: .system(size: 10.5, weight: .semibold), ink: IconTint.of(p.id.name).map(Theme.tint) ?? Theme.kind(kind), behind: colours.fill, in: &ctx)
            x += M.glyphRoom(symbols.count)
        }
        // Wrapped lines start where the first does, after the glyphs.
        for (i, line) in p.nameLines.enumerated() {
            ctx.draw(Text(line).font(p.depth == 0 ? Theme.Map.rootName : Theme.Map.name).foregroundStyle(Theme.Map.primary),
                     at: CGPoint(x: x, y: nameY + Double(i) * M.nameLine), anchor: .leading)
        }
        if p.badge, let badge = style.badge {
            ctx.draw(Text(Image(systemName: badge)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(colours.ink),
                     at: CGPoint(x: p.x + p.w - M.padX - M.badge / 2 + 3, y: nameY), anchor: .center)
        }
        guard detail == .full else { return }
        for (i, note) in p.notes.enumerated() {
            let y = p.y + M.padY + Double(p.nameLines.count) * M.nameLine + (Double(i) + 0.5) * M.noteLine
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

    /// A tree's links are heavier near its root and taper toward its leaves, so the main
    /// branches read first; cross-links stay hairlines.
    static func linkWidth(tree: Bool, depth: Int) -> CGFloat {
        CGFloat(MapLayout.linkWidth(tree: tree, depth: depth))
    }

    private func drawEdge(_ e: MapLayout.PlacedEdge, _ edge: Edge?, depth: Int, lit: Bool, in ctx: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(e.p0))
        path.addCurve(to: CGPoint(e.p3), control1: CGPoint(e.p1), control2: CGPoint(e.p2))
        let src = edge?.note(kind: "src")
        let selected = session.selectedEdge == e.key
        let colour = selected ? Theme.accent : Theme.Map.branch(e.branch) ?? Theme.Map.tertiary
        let dash: [CGFloat] = src == "guess" ? [2, 3] : src == "world" ? [6, 4] : e.tree ? [] : [5, 4]
        let width: CGFloat = Self.linkWidth(tree: e.tree, depth: depth) + (lit || selected ? 0.75 : 0)
        if src == "guess" { ctx.opacity *= 0.75 }
        if selected {
            ctx.stroke(path, with: .color(Theme.accent.opacity(0.2)), style: StrokeStyle(lineWidth: width + 6, lineCap: .round))
        }
        if session.viewingTurn == nil, session.review.edges.contains(e.key) {
            ctx.stroke(path, with: .color(Theme.accent.opacity(0.25)), style: StrokeStyle(lineWidth: width + 5, lineCap: .round))
        }
        ctx.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        let head = Double(max(1, width / 1.25))
        if e.arrowEnd { arrow(&ctx, tip: e.p3, from: e.p2.x == e.p3.x && e.p2.y == e.p3.y ? e.p0 : e.p2, colour: colour, scale: head) }
        if e.arrowStart { arrow(&ctx, tip: e.p0, from: e.p1.x == e.p0.x && e.p1.y == e.p0.y ? e.p3 : e.p1, colour: colour, scale: head) }
    }

    /// An arrowhead at `tip`, pointing away from `from`; `scale` grows it with a heavier line.
    private func arrow(_ ctx: inout GraphicsContext, tip: MapLayout.Point, from: MapLayout.Point, colour: Color, scale: Double = 1) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let d = max(hypot(dx, dy), 0.001)
        let ux = dx / d, uy = dy / d
        let length = 6.0 * scale, half = 2.4 * scale
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
        if let b = hitButton(point, layout) { press(b); return }
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
                // The first movement decides what this drag is; a spread stops where it is.
                if spreadTask != nil { finishSpread(commit: true) }
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
                        // It is already where it was dropped: no glide back from where it was.
                        morphFrom = session.displayedLayout.moving(d.name, dx: d.offset.width / view.k, dy: d.offset.height / view.k)
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
            if session.review.nodes.contains(name) {
                Button("Accept the model's addition") { session.accept(node: name) }
                Button("Delete the model's addition") { session.reject(node: name) }
                Divider()
            }
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
                // Symbols its name could match, then the project's own icons.
                ForEach(session.iconChoices(for: name), id: \.self) { icon in
                    Button { session.dispatch(.applyLines(["| \(name) @icon \(icon)"], what: "icon \(name)")) } label: { Label(icon, systemImage: icon) }
                }
                if !session.icons.entries.isEmpty { Divider() }
                ForEach(Array(session.icons.entries.keys.sorted().prefix(30)), id: \.self) { icon in
                    Button(icon) { session.dispatch(.applyLines(["| \(name) @icon \(icon)"], what: "icon \(name)")) }
                }
                if session.iconChoices(for: name).isEmpty && session.icons.entries.isEmpty { Text("No icon matches this name") }
            }
            if session.layout[name]?.pinned == true { Button("Release pin") { session.dispatch(.release(name)) } }
            if let p = session.layout[name], p.childCount > 0 {
                Button(p.hiddenCount > 0 ? "Open branch (\(p.hiddenCount) hidden)" : "Fold branch") { session.toggleFold(name) }
            }
            Button("Show details") { session.selection = [name]; session.detailsRequests += 1 }
            Button("Copy name") { Clipboard.copy(name) }
            Divider()
            Button("Delete", role: .destructive) { session.dispatch(.delete(name)); session.selection = [] }
        } else if names.count > 1 {
            Button("Expand \(names.count) nodes") { names.forEach { session.expand($0) } }
            Button("Copy \(names.count) names") { Clipboard.copy(names.joined(separator: "\n")) }
            Divider()
            Button("Delete \(names.count) nodes", role: .destructive) { names.forEach { session.dispatch(.delete($0)) }; session.selection = [] }
        } else if let key = session.selectedEdge, let edge = graph.edges[key] {
            if session.review.edges.contains(key) {
                Button("Accept the model's link") { session.accept(edge: key) }
                Divider()
            }
            Button("Edit label…") { labelText = edge.labels.first ?? ""; labelPrompt = (edge.a.name, edge.b.name) }
            if ["world", "guess", "advice"].contains(edge.note(kind: "src") ?? "") {
                Button("Confirm") { session.dispatch(.applyLines(["| \(edge.a.name) @src user - | \(edge.b.name)"], what: "confirm edge")) }
            }
            Button("Add comment…") { commentTarget = edge.a.name }
            Button("Copy link") { Clipboard.copy([edge.a.name, edge.labels.joined(separator: ", "), edge.b.name].filter { !$0.isEmpty }.joined(separator: " – ")) }
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
            Button("Fill the view") { fillView() }
            Button("Find on the map…") { openFind() }
            Button("Keys on the map") { showKeys = true }
            if !session.ui.collapsed.isEmpty { Button("Open every branch") { session.unfoldAll() } }
            Button(minimapOn ? "Hide the overview" : "Show the overview") { minimapOn.toggle() }
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

/// The map gliding from the layout it had to the one it has now (`MapLayout.morphed`).
struct Morph: Equatable {
    let from: MapLayout
    /// Nodes the old layout did not have: they fade in as they grow out of their parents.
    let arrivals: Set<String>
    let start: Date
    static let duration: TimeInterval = 0.42
    /// Past this many nodes the map changes at once: a glide would stutter.
    static let maxNodes = 1500

    /// How far along at `date`, eased out (quick at first, settling gently).
    func progress(at date: Date) -> Double {
        let x = min(1, max(0, date.timeIntervalSince(start) / Self.duration))
        return 1 - pow(1 - x, 3)
    }
}

/// What the canvas marks as it draws: nodes fading in, and Find on the map's matches (the
/// rest of the map dims while there are some).
struct Marks {
    var arrivals: Set<String> = []
    var fade: Double = 1
    var found: Set<String> = []
    var current: String?

    /// How opaque a node (or a link between two) is drawn.
    func opacity(_ names: String...) -> Double {
        var o = 1.0
        if names.contains(where: { arrivals.contains($0) }) { o *= fade }
        if !found.isEmpty, !names.contains(where: { found.contains($0) }) { o *= 0.25 }
        return o
    }
}

/// How much the canvas draws at a zoom: everything; names without notes or link labels
/// (too small to read); or, far out, shapes alone with the trees' main names over them.
enum Detail {
    case full, names, shapes

    init(zoom k: CGFloat) {
        self = k >= 0.5 ? .full : k >= 0.28 ? .names : .shapes
    }
}

/// Find on the map (⌘F), at the bottom of the map: matches light up as you type (the rest
/// dims), ↩ goes to the next, ⇧↩ to the one before, esc closes it.
struct FindBar: View {
    @Binding var text: String
    let count: Int
    let index: Int
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find on the map", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .frame(width: 220)
                .focused($focused)
                .onSubmit { step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onKeyPress(.escape) { close(); return .handled }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(count == 0 ? "No match" : "\(index + 1) of \(count)")
                    .font(Theme.caption).monospacedDigit()
                    .foregroundStyle(count == 0 ? Color.orange : Color.secondary)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            MapToolButton(symbol: "chevron.up", help: "Previous match (⇧↩)") { step(-1) }.disabled(count < 2)
            MapToolButton(symbol: "chevron.down", help: "Next match (↩)") { step(1) }.disabled(count < 2)
            MapToolButton(symbol: "xmark", help: "Close (esc)", action: close)
        }
        .padding(.leading, Theme.Space.m - 4)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, 3)
        .floatingBar(in: Capsule())
        .shieldsMapScroll()
        .onAppear { focused = true }
    }
}

/// The whole map, small, in the bottom right corner, with the part on screen outlined in
/// the accent: click or drag on it to go there.
struct Minimap: View {
    let layout: MapLayout
    let view: Viewport
    let viewSize: CGSize
    /// Centres the view on a map point (gliding unless dragged).
    let go: (MapLayout.Point, Bool) -> Void
    /// The most room it takes, and the margin inside it.
    static let roomWidth = 180.0, roomHeight = 120.0, pad = 8.0

    var body: some View {
        let w = max(1, layout.width), h = max(1, layout.height)
        let scale = min(Self.roomWidth / w, Self.roomHeight / h)
        let width = max(48, w * scale) + 2 * Self.pad, height = max(32, h * scale) + 2 * Self.pad
        let size = CGSize(width: width, height: height)
        // Map points to the minimap's, and back.
        let ox = (width - w * scale) / 2 - layout.minX * scale
        let oy = (height - h * scale) / 2 - layout.minY * scale
        Canvas { ctx, _ in
            for e in layout.edges where e.tree {
                var path = Path()
                path.move(to: CGPoint(x: e.p0.x * scale + ox, y: e.p0.y * scale + oy))
                path.addCurve(to: CGPoint(x: e.p3.x * scale + ox, y: e.p3.y * scale + oy),
                              control1: CGPoint(x: e.p1.x * scale + ox, y: e.p1.y * scale + oy),
                              control2: CGPoint(x: e.p2.x * scale + ox, y: e.p2.y * scale + oy))
                ctx.stroke(path, with: .color((Theme.Map.branch(e.branch) ?? Theme.Map.tertiary).opacity(0.55)), lineWidth: 0.75)
            }
            for p in layout.nodes {
                let r = CGRect(x: p.x * scale + ox, y: p.y * scale + oy, width: max(2, p.w * scale), height: max(2, p.h * scale))
                let ink = Theme.Map.branch(p.branch) ?? Theme.Map.secondary
                ctx.fill(Path(roundedRect: r, cornerRadius: min(2, r.height / 2)), with: .color(ink.opacity(p.depth == 0 ? 0.9 : 0.6)))
            }
            // What is on screen.
            let a = view.map(.zero), b = view.map(CGPoint(x: viewSize.width, y: viewSize.height))
            let seen = CGRect(x: a.x * scale + ox, y: a.y * scale + oy, width: (b.x - a.x) * scale, height: (b.y - a.y) * scale)
                .intersection(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            if !seen.isNull {
                ctx.fill(Path(roundedRect: seen, cornerRadius: 3), with: .color(Theme.accent.opacity(0.1)))
                ctx.stroke(Path(roundedRect: seen, cornerRadius: 3), with: .color(Theme.accent), lineWidth: 1.25)
            }
        }
        .frame(width: size.width, height: size.height)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusSmall + 2))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let moved = hypot(g.translation.width, g.translation.height) > 2
                go(MapLayout.Point(x: (Double(g.location.x) - ox) / scale, y: (Double(g.location.y) - oy) / scale), !moved)
            })
        .help("The whole map: click or drag to go there (M hides it)")
        .accessibilityElement()
        .accessibilityLabel("Overview of the map")
        .accessibilityHint("Click to move the view there")
    }
}

extension CGPoint {
    init(_ p: MapLayout.Point) { self.init(x: p.x, y: p.y) }
}

/// Zoom in, zoom out, fit and fill: a small bar in the bottom right corner.
struct ZoomBar: View {
    /// Five 28 pt buttons, 2 pt apart, in 3 pt of padding: 5 × 28 + 4 × 2 + 2 × 3.
    static let width: CGFloat = 34
    static let height: CGFloat = 154
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let fit: () -> Void
    let fill: () -> Void
    var filling = false
    /// The overview in the corner is wanted (it shows while some of the map is out of view).
    @Binding var minimap: Bool

    var body: some View {
        VStack(spacing: 2) {
            MapToolButton(symbol: "plus", help: "Zoom in (+)", action: zoomIn)
            MapToolButton(symbol: "minus", help: "Zoom out (−)", action: zoomOut)
            MapToolButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit the map (0)", action: fit)
            MapToolButton(symbol: "wand.and.stars", help: filling ? "Stop filling the view here (F)" : "Fill the view: nodes move into the room around them until the map can zoom in no further (F; undo puts them back)",
                          pressed: filling, action: fill)
            MapToolButton(symbol: "map", help: minimap ? "Hide the overview of the whole map (M)" : "Show an overview of the whole map while some of it is out of view (M)",
                          pressed: minimap) { withAnimation(Theme.slide) { minimap.toggle() } }
        }
        .padding(3)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge - 2))
    }
}

/// Spacing: the least room Fill the view leaves between two nodes, a vertical slider
/// standing on the zoom bar (up is more room). Letting go fills the view again with it.
struct SpacingBar: View {
    static let height: CGFloat = 150
    static let range: ClosedRange<Double> = 0...120
    @Binding var spacing: Double
    let changed: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            Text("\(Int(spacing))").font(Theme.caption).monospacedDigit().foregroundStyle(.secondary)
            VerticalSlider(value: $spacing, in: Self.range, step: 2, onEnded: changed)
            Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Space.s)
        .frame(width: ZoomBar.width, height: Self.height)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge - 2))
        .help("Spacing between nodes: the least room Fill the view leaves between two nodes (\(Int(spacing)) pt)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spacing between nodes")
        .accessibilityValue("\(Int(spacing)) points")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: spacing = min(spacing + 2, Self.range.upperBound)
            case .decrement: spacing = max(spacing - 2, Self.range.lowerBound)
            @unknown default: return
            }
            changed()
        }
    }
}

/// A slider standing up: drag or click the track; the bottom is the least.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onEnded: () -> Void
    @State private var dragging = false
    private let knob: CGFloat = 12

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, onEnded: @escaping () -> Void) {
        _value = value
        self.range = range
        self.step = step
        self.onEnded = onEnded
    }

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.height - knob, 1)
            let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
            let top = travel * CGFloat(1 - fraction)
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 4)
                Capsule().fill(Theme.accent)
                    .frame(width: 4, height: max(geo.size.height - top - knob / 2, 0))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Circle().fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dragging ? 0.3 : 0.2), radius: dragging ? 2 : 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(y: top)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    let f = 1 - Double(min(max((g.location.y - knob / 2) / travel, 0), 1))
                    let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    value = (raw / step).rounded() * step
                }
                .onEnded { _ in
                    dragging = false
                    onEnded()
                })
        }
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

/// Every key the map answers to, in a card over it (? opens and closes it).
struct MapKeysCard: View {
    let close: () -> Void

    struct Key: Hashable { let key: String; let what: String }
    struct Group: Hashable { let title: String; let keys: [Key] }

    static let groups: [Group] = [
        Group(title: "Moving", keys: [Key(key: "drag, scroll", what: "move the map"), Key(key: "pinch, ⌘-scroll", what: "zoom about the pointer"),
                                      Key(key: "+  −", what: "zoom in, out"), Key(key: "0", what: "fit the map"), Key(key: "F", what: "fill the view"),
                                      Key(key: "M", what: "overview on or off"), Key(key: "⇧ arrows", what: "move the map")]),
        Group(title: "A selected node", keys: [Key(key: "← →", what: "its parent, its child"), Key(key: "↑ ↓", what: "the node above, below"),
                                               Key(key: "↩", what: "rename"), Key(key: "space", what: "details"), Key(key: "/", what: "fold or open its branch"),
                                               Key(key: "Z", what: "zoom to the selection"), Key(key: "⌫", what: "delete (⌘Z brings it back)"), Key(key: "esc", what: "let go")]),
        Group(title: "On the map", keys: [Key(key: "⌘F", what: "find on the map"), Key(key: "double-click", what: "expand a node"),
                                          Key(key: "⌥-drag", what: "link two nodes"), Key(key: "⇧-drag", what: "select with a box"),
                                          Key(key: "drag a node", what: "pin it there"), Key(key: "?", what: "this card")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Keys on the map").font(Theme.title)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Close (esc)")
                    .accessibilityLabel("Close")
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                ForEach(Self.groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(group.title).font(Theme.label).foregroundStyle(.secondary)
                        ForEach(group.keys, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text(item.key)
                                    .font(Theme.caption.monospaced().weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                                    .frame(minWidth: 96, alignment: .leading)
                                Text(item.what).font(Theme.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: 820)
        .floatingBar(in: RoundedRectangle(cornerRadius: Theme.radiusLarge))
        .padding(Theme.Space.l)
    }
}

/// What an empty map says.
struct EmptyMap: View {
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text("No map yet").font(Theme.title)
            Text("Add text or audio below, then send it from Context,\nor drop a text or audio file here.").font(Theme.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Press ? for the map's keys.").font(Theme.caption).foregroundStyle(.tertiary)
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
    /// How many nodes its fold hides (0: not folded).
    var hidden = 0

    var body: some View {
        let kind = node.note(kind: "kind")
        let notes = MapLayout.shownNotes(node)
        let comments = Outline.comments(attachedTo: node.id.name, in: graph)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: IconManifest.fallbackSymbol(kind: kind)).foregroundStyle(Theme.kind(kind)).font(Theme.caption)
                Text(node.id.name).font(Theme.label).lineLimit(3)
            }
            let degree = graph.degree(of: node.id)
            let facts = [kind, node.note(kind: "src").map { "from \($0)" }, pinned ? "pinned" : nil, degree == 1 ? "1 link" : "\(degree) links",
                         hidden > 0 ? "\(hidden) folded away" : nil].compactMap { $0 }
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

/// Rename a node. A name another node already has would merge the two, so it asks first.
struct RenamePrompt: View {
    let old: String
    @State var text: String
    let exists: (String) -> Bool
    let rename: (String) -> Void
    /// The taken name the user was warned about; OK again merges.
    @State private var clash: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Rename “\(old)”").font(Theme.title)
            TextField("new name", text: $text).textFieldStyle(.roundedBorder).onSubmit(commit)
            if let clash {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("“\(clash)” is already on the map. Renaming merges the two into one node, with the links and notes of both. Rename anyway?")
                        .font(Theme.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(clash == nil ? "Rename" : "Rename and merge", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 380)
        .onChange(of: text) { _, _ in clash = nil }
    }

    private func commit() {
        let target = Canonicaliser.canonical(text)
        guard !target.isEmpty, target != old else { dismiss(); return }
        if exists(target), clash != target { clash = target; return }
        rename(text)
        dismiss()
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
/// the map; ⌘-scroll (or a mouse wheel's zoom) zooms about the pointer. Over a panel or bar
/// floating on the map (`shields`), the wheel is left to it, so its list scrolls.
extension View {
    func onScrollWheel(shields: [CGRect] = [], _ action: @escaping (_ delta: CGSize, _ location: CGPoint, _ zooms: Bool) -> Void) -> some View {
        background(ScrollWheelCatcher(shields: shields, action: action))
    }

    /// Marks a view floating over the map: the wheel over it scrolls it, not the map.
    func shieldsMapScroll() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: MapScroll.Shields.self, value: [geo.frame(in: .named(MapScroll.space))])
        })
    }
}

/// The map's frame, which the panels and bars over it report their frames in.
enum MapScroll {
    static let space = "map"

    struct Shields: PreferenceKey {
        static let defaultValue: [CGRect] = []
        static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
    }
}

struct ScrollWheelCatcher: NSViewRepresentable {
    let shields: [CGRect]
    let action: (CGSize, CGPoint, Bool) -> Void
    func makeNSView(context: Context) -> ScrollView { let v = ScrollView(); v.action = action; v.shields = shields; return v }
    func updateNSView(_ nsView: ScrollView, context: Context) { nsView.action = action; nsView.shields = shields }

    /// Sits behind the map and takes the wheel events over its frame: SwiftUI's own views
    /// are what the pointer hits, so a local event monitor catches them on their way in.
    final class ScrollView: NSView {
        var action: ((CGSize, CGPoint, Bool) -> Void)?
        var shields: [CGRect] = []
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
                // Over a panel, a bar or an overlay: its own lists and text scroll.
                guard !self.shields.contains(where: { $0.contains(location) }) else { return event }
                // A mouse wheel moves in lines; a trackpad in points.
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                self.action?(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale), location, event.modifierFlags.contains(.command))
                return nil
            }
        }
    }
}
