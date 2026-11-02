// The mind map's geometry: the graph laid out as left-to-right trees, stacked top to bottom.
// A port of Harness/Canvas/MapLayout.swift (compute, routing, placing). Text is measured by a
// function the caller passes, so the same code runs in the page and in tests.
(function (MM) {
  "use strict";
  const { splitNote, noteOf, cmp, edgeKey } = MM.notation;

  // Line heights, paddings and gaps, in points.
  const M = {
    nameLine: 18, noteLine: 16, labelLine: 15, padX: 12, padY: 7, glyph: 20, badge: 18,
    maxText: 240, wrapWords: 3, maxNameLines: 3, siblingGap: 12, treeGap: 28, unlinkedFirst: 3,
    minColumnGap: 56, maxColumnGap: 260, maxNotes: 3,
    iconLine: 30, iconBox: 32, iconStep: 18, maxIcons: 3, moreIcons: 18, glyphStep: 8, iconGap: 2, openPadX: 6, openPadY: 4,
    iconStack(n) { return M.iconBox + Math.max(0, Math.min(n, M.maxIcons) - 1) * M.iconStep + (n > M.maxIcons ? M.moreIcons : 0); },
    glyphRoom(n) { return M.glyph + Math.max(0, Math.min(n, M.maxIcons) - 1) * M.glyphStep; },
  };

  // Note kinds not printed under a name: drawn another way, or proof.
  const HIDDEN_NOTES = new Set(["src", "kind", "icon", "pos", "text"]);

  // A rough measure for when no renderer is at hand (tests).
  const estimate = (text, role) => Array.from(text).length * (role === "name" ? 7.2 : 6.4);

  const words = (text) => text.split(/\s+/).filter(Boolean);

  // Swift's `rounded()`: to nearest, halves away from zero.
  const round = (v) => (v < 0 ? -Math.round(-v) : Math.round(v));

  function defaultGlyph(node) { return noteOf(node.notes, "kind") !== null || noteOf(node.notes, "icon") !== null; }
  function isBoxed(node) { return ["world", "guess", "advice"].includes(noteOf(node.notes, "src") || ""); }
  function hasBadge(src) { return ["world", "guess", "advice", "user"].includes(src || ""); }
  function shownNotes(notes) { return notes.filter((n) => !HIDDEN_NOTES.has(splitNote(n).kind)); }

  // `@pos x,y`: a node's pinned centre (a minus sign − reads as -).
  function position(value) {
    if (value === null) return null;
    const parts = value.replace(/−/g, "-").split(",");
    if (parts.length !== 2) return null;
    const x = Number(parts[0].trim()), y = Number(parts[1].trim());
    if (parts[0].trim() === "" || parts[1].trim() === "" || !isFinite(x) || !isFinite(y) || Math.abs(x) >= 1e9 || Math.abs(y) >= 1e9) return null;
    return { x, y };
  }

  // `text` cut with an ellipsis to fit `max` points.
  function fit(text, role, max, measure) {
    if (measure(text, role) <= max) return text;
    const chars = Array.from(text);
    let lo = 0, hi = chars.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi + 1) / 2);
      if (measure(chars.slice(0, mid).join("") + "…", role) <= max) lo = mid; else hi = mid - 1;
    }
    return chars.slice(0, lo).join("").trim() + "…";
  }

  // A name broken into lines of at most `wrapWords` words once it has more, as evenly as they go.
  function nameLines(name, max, measure) {
    const parts = words(name);
    if (parts.length <= M.wrapWords) return [fit(name, "name", max, measure)];
    const count = Math.min(M.maxNameLines, Math.floor((parts.length + M.wrapWords - 1) / M.wrapWords));
    const lines = [];
    let rest = parts.slice();
    for (let i = 0; i < count; i++) {
      const even = Math.floor((rest.length + (count - i) - 1) / (count - i));
      const take = i === count - 1 ? rest.length : Math.min(M.wrapWords, even);
      lines.push(rest.slice(0, take).join(" "));
      rest = rest.slice(take);
    }
    return lines.map((l) => fit(l, "name", max, measure));
  }

  function anchorY(n) { return n.boxed ? n.h / 2 : M.openPadY + M.iconLine / 2; }
  function anchorInset(n) { return n.boxed ? 0 : Math.max(0, (n.w - M.iconStack(n.icons)) / 2); }

  // The cubic an edge from `a` to `b` is drawn as, and whether it leaves from `a`. Each end is
  // { x, y, w, h, anchorY, anchorInset, pinned }.
  function curve(a, b) {
    const [s, t] = a.x <= b.x ? [a, b] : [b, a];
    const sy = s.y + s.anchorY, ty = t.y + t.anchorY;
    const sRight = s.x + s.w - s.anchorInset, tLeft = t.x + t.anchorInset, tRight = t.x + t.w - t.anchorInset;
    const [u, d] = a.y <= b.y ? [a, b] : [b, a];
    if (sRight >= tLeft && a.pinned && b.pinned && u.y + u.h + M.siblingGap < d.y) {
      // Stacked: top to bottom, leaving from the upper node.
      const p0 = { x: u.x + u.w / 2, y: u.y + u.h }, p3 = { x: d.x + d.w / 2, y: d.y };
      const dy = (p3.y - p0.y) / 2;
      return { p0, p1: { x: p0.x, y: p0.y + dy }, p2: { x: p3.x, y: p3.y - dy }, p3, fromA: a.y <= b.y };
    } else if (sRight < tLeft) {
      const p0 = { x: sRight, y: sy }, p3 = { x: tLeft, y: ty };
      const dx = (p3.x - p0.x) / 2;
      return { p0, p1: { x: p0.x + dx, y: sy }, p2: { x: p3.x - dx, y: ty }, p3, fromA: a.x <= b.x };
    } else {
      // Overlapping columns: right side to right side, around the outside.
      const p0 = { x: sRight, y: sy }, p3 = { x: tRight, y: ty };
      const out = Math.max(p0.x, p3.x) + 40 + Math.abs(ty - sy) * 0.15;
      return { p0, p1: { x: out, y: sy }, p2: { x: out, y: ty }, p3, fromA: a.x <= b.x };
    }
  }

  function ends(n) { return { x: n.x, y: n.y, w: n.w, h: n.h, anchorY: anchorY(n), anchorInset: anchorInset(n), pinned: n.pinned }; }

  // How heavy a link is drawn: a tree's taper from its root, cross-links hairlines.
  function linkWidth(tree, depth) { return !tree ? 1 : depth <= 1 ? 2.25 : depth === 2 ? 1.6 : 1.25; }

  class Layout {
    constructor() {
      this.nodes = []; this.index = new Map(); this.edges = [];
      this.parent = new Map(); this.children = new Map(); this.directions = new Map();
      this.minX = 0; this.minY = 0; this.maxX = 0; this.maxY = 0;
      this.measure = estimate;
    }
    get width() { return this.maxX - this.minX; }
    get height() { return this.maxY - this.minY; }
    get(name) { const i = this.index.get(name); return i === undefined ? null : this.nodes[i]; }
    depthOf(e) { return Math.max(this.get(e.lo).depth, this.get(e.hi).depth); }

    clone() {
      const l = Object.assign(new Layout(), this);
      l.nodes = this.nodes.map((n) => ({ ...n }));
      l.edges = this.edges.map((e) => ({ ...e }));
      return l;
    }

    // The layout with nodes moved to these centres (pinned there) and every edge re-routed.
    placing(centers) {
      const next = this.clone();
      for (const [name, c] of centers) {
        const i = next.index.get(name);
        if (i === undefined) continue;
        const n = next.nodes[i];
        n.x = c.x - n.w / 2; n.y = c.y - n.h / 2; n.pinned = true;
      }
      next.reroute();
      next.fitBounds();
      return next;
    }

    centers() { return new Map(this.nodes.map((n) => [n.name, { x: n.x + n.w / 2, y: n.y + n.h / 2 }])); }

    sameAs(other) {
      if (this.nodes.length !== other.nodes.length) return false;
      return this.nodes.every((n, i) => { const o = other.nodes[i]; return n.name === o.name && n.x === o.x && n.y === o.y && n.pinned === o.pinned; });
    }

    reroute() {
      for (const e of this.edges) {
        const dir = this.directions.get(e.id);
        const a = this.get(dir.a), b = this.get(dir.a === e.lo ? e.hi : e.lo);
        route(e, dir, a, b);
      }
    }

    fitBounds() {
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const n of this.nodes) { x0 = Math.min(x0, n.x); y0 = Math.min(y0, n.y); x1 = Math.max(x1, n.x + n.w); y1 = Math.max(y1, n.y + n.h); }
      for (const e of this.edges) {
        for (const p of [e.p1, e.p2]) { x1 = Math.max(x1, p.x); x0 = Math.min(x0, p.x); }
        if (e.label || e.note) {
          const half = Math.max(this.measure(e.label, "label"), this.measure(e.note, "label")) / 2;
          x0 = Math.min(x0, e.labelAt.x - half); x1 = Math.max(x1, e.labelAt.x + half);
        }
      }
      if (isFinite(x0)) { this.minX = x0; this.minY = y0; this.maxX = x1; this.maxY = y1; }
    }
  }

  // A cubic from one node's side to the other's, with the label at its middle.
  function route(placed, dir, a, b) {
    const c = curve(ends(a), ends(b));
    placed.p0 = c.p0; placed.p1 = c.p1; placed.p2 = c.p2; placed.p3 = c.p3;
    placed.labelAt = { x: round((c.p0.x + 3 * c.p1.x + 3 * c.p2.x + c.p3.x) / 8), y: round((c.p0.y + 3 * c.p1.y + 3 * c.p2.y + c.p3.y) / 8) };
    placed.arrowEnd = c.fromA ? dir.forward : dir.backward;
    placed.arrowStart = c.fromA ? dir.backward : dir.forward;
  }

  // The graph laid out: roots are the nodes nothing points at (the best-connected first); a
  // breadth-first walk hangs every other node under the first node that reaches it. Edges the
  // trees do not use are cross-links. A node with `@pos` keeps that place.
  function compute(graph, measure = estimate, options = {}) {
    const glyph = options.glyph || defaultGlyph;
    const iconsOf = options.icons || (() => 1);
    const layout = new Layout();
    layout.measure = measure;
    const ids = [...graph.nodes.keys()];
    if (!ids.length) return layout;
    const all = [...graph.edges.values()].filter((e) => e.a !== e.b && graph.nodes.has(e.a) && graph.nodes.has(e.b))
      .map((e) => ({ e, k: edgeKey(e.a, e.b) }))
      .sort((x, y) => cmp(x.k.lo, y.k.lo) || cmp(x.k.hi, y.k.hi));

    // Trees: roots by degree (the hub first), children by name.
    const degree = new Map(), out = new Map(), pointedAt = new Set();
    const push = (m, k, v) => { if (!m.has(k)) m.set(k, []); m.get(k).push(v); };
    for (const { e, k } of all) {
      degree.set(e.a, (degree.get(e.a) || 0) + 1);
      degree.set(e.b, (degree.get(e.b) || 0) + 1);
      const undirected = !e.forward && !e.backward;
      const id = k.lo + "\u0000" + k.hi;
      if (e.forward || undirected) push(out, e.a, { to: e.b, id });
      if (e.backward || undirected) push(out, e.b, { to: e.a, id });
      if (e.forward) pointedAt.add(e.b);
      if (e.backward) pointedAt.add(e.a);
    }
    for (const list of out.values()) list.sort((x, y) => cmp(x.to, y.to));
    const order = ids.slice().sort((x, y) => (degree.get(y) || 0) - (degree.get(x) || 0) || cmp(x, y));

    const children = new Map(), depth = new Map(), treeEdges = new Set(), roots = [];
    function grow(root) {
      depth.set(root, 0);
      const queue = [root];
      for (let i = 0; i < queue.length; i++) {
        const parent = queue[i];
        for (const { to, id } of out.get(parent) || []) {
          if (depth.has(to)) continue;
          depth.set(to, depth.get(parent) + 1);
          treeEdges.add(id);
          push(children, parent, to);
          queue.push(to);
        }
      }
      roots.push({ id: root, size: queue.length });
    }
    for (const id of order) if (!pointedAt.has(id) && !depth.has(id)) grow(id);
    for (const id of order) if (!depth.has(id)) grow(id);
    // Larger trees first; the first few nodes linked to nothing at all go at the very top.
    let sortedRoots = roots.map((r, i) => ({ ...r, i })).sort((x, y) => y.size - x.size || x.i - y.i).map((r) => r.id);
    const unlinked = sortedRoots.filter((r) => !degree.has(r)).sort(cmp).slice(0, M.unlinkedFirst);
    sortedRoots = unlinked.concat(sortedRoots.filter((r) => !unlinked.includes(r)));
    const branch = new Map();
    let branches = 0;
    function paint(id, b) {
      branch.set(id, b);
      for (const c of children.get(id) || []) {
        if (depth.get(id) === 0) { branches += 1; paint(c, branches); } else paint(c, b);
      }
    }
    for (const r of sortedRoots) paint(r, 0);

    // Size every node.
    const sized = new Map();
    for (const id of ids) {
      const node = graph.nodes.get(id);
      const lines = nameLines(id, M.maxText, measure);
      const nameW = Math.max(0, ...lines.map((l) => measure(l, "name")));
      const nameH = lines.length * M.nameLine;
      const allNotes = shownNotes(node.notes);
      const notes = allNotes.slice(0, M.maxNotes).map((n) => fit(n, "note", M.maxText, measure));
      const boxed = isBoxed(node);
      const src = noteOf(node.notes, "src");
      const hasGlyph = !boxed || glyph(node), badge = hasBadge(src);
      const iconCount = hasGlyph ? Math.max(1, iconsOf(node)) : 0;
      const pin = position(noteOf(node.notes, "pos"));
      let w, h;
      if (boxed) {
        const rowW = nameW + (hasGlyph ? M.glyphRoom(iconCount) : 0) + (badge ? M.badge : 0);
        const textW = Math.max(rowW, ...notes.map((n) => measure(n, "note")));
        w = Math.ceil(textW + 2 * M.padX);
        h = nameH + notes.length * M.noteLine + 2 * M.padY;
      } else {
        const textW = Math.max(M.iconStack(iconCount), nameW, ...notes.map((n) => measure(n, "note")));
        w = Math.ceil(textW + 2 * M.openPadX);
        h = M.openPadY + M.iconLine + M.iconGap + nameH + notes.length * M.noteLine + M.openPadY;
      }
      const cut = lines.join(" ") !== words(id).join(" ") || notes.length < allNotes.length || notes.some((n, i) => n !== allNotes[i]);
      sized.set(id, {
        name: id, nameLines: lines, notes, allNotes, cut, depth: depth.get(id) || 0, branch: branch.get(id) || 0,
        glyph: hasGlyph, icons: Math.max(1, iconCount), badge, src, kind: noteOf(node.notes, "kind"),
        childCount: (children.get(id) || []).length, hiddenCount: 0, pinned: pin !== null, boxed, x: 0, y: 0, w, h,
      });
    }

    // Columns: as wide as their widest node, apart by enough room for the labels between.
    const columns = [], gaps = [];
    for (const p of sized.values()) {
      while (columns.length <= p.depth) { columns.push(0); gaps.push(0); }
      columns[p.depth] = Math.max(columns[p.depth], p.w);
    }
    const label = (e) => e.labels.join(" · ");
    const note = (e) => shownNotes(e.notes).join(" · ");
    for (const { e, k } of all) {
      if (!treeEdges.has(k.lo + "\u0000" + k.hi)) continue;
      const d = Math.min(sized.get(e.a).depth, sized.get(e.b).depth);
      gaps[d] = Math.max(gaps[d], Math.max(measure(label(e), "label"), measure(note(e), "label")) + 2 * M.padX);
    }
    const columnX = [];
    let x = 0;
    for (let d = 0; d < columns.length; d++) {
      columnX.push(x);
      x += columns[d] + Math.min(M.maxColumnGap, Math.max(M.minColumnGap, gaps[d]));
    }

    // Rows: each subtree is as tall as its children (or itself); a parent is centred on them.
    const span = new Map();
    function measureTree(id) {
      const kids = children.get(id) || [];
      const total = Math.max(sized.get(id).h, kids.reduce((s, c) => s + measureTree(c), 0) + M.siblingGap * Math.max(0, kids.length - 1));
      span.set(id, total);
      return total;
    }
    function assign(id, y) {
      const kids = children.get(id) || [];
      const n = sized.get(id);
      n.x = columnX[n.depth];
      n.y = y + (span.get(id) - n.h) / 2;
      const kidsH = kids.reduce((s, c) => s + span.get(c), 0) + M.siblingGap * Math.max(0, kids.length - 1);
      let cy = y + (span.get(id) - kidsH) / 2;
      for (const c of kids) { assign(c, cy); cy += span.get(c) + M.siblingGap; }
    }
    let y = 0;
    const drawn = [];
    const collect = (id) => { drawn.push(id); (children.get(id) || []).forEach(collect); };
    for (const r of sortedRoots) { measureTree(r); assign(r, y); y += span.get(r) + M.treeGap; collect(r); }

    // Pins keep their place (the note holds the centre).
    for (const id of ids) {
      const pos = position(noteOf(graph.nodes.get(id).notes, "pos"));
      if (pos) { const n = sized.get(id); n.x = round(pos.x - n.w / 2); n.y = round(pos.y - n.h / 2); }
    }

    layout.nodes = drawn.map((id) => sized.get(id));
    layout.nodes.forEach((n, i) => layout.index.set(n.name, i));
    for (const [p, kids] of children) {
      if (!kids.length) continue;
      layout.children.set(p, kids.slice());
      for (const k of kids) layout.parent.set(k, p);
    }
    const maxLabel = M.maxColumnGap - 2 * M.padX;
    layout.edges = all.map(({ e, k }) => {
      const id = k.lo + "\u0000" + k.hi;
      const tree = treeEdges.has(id);
      const a = sized.get(e.a), b = sized.get(e.b);
      const placed = {
        id, lo: k.lo, hi: k.hi, tree, branch: tree ? (a.depth > b.depth ? a.branch : b.branch) : 0,
        src: noteOf(e.notes, "src"), label: fit(label(e), "label", maxLabel, measure), note: fit(note(e), "label", maxLabel, measure),
      };
      layout.directions.set(id, { a: e.a, forward: e.forward, backward: e.backward });
      route(placed, layout.directions.get(id), a, b);
      return placed;
    });
    layout.fitBounds();
    return layout;
  }

  // The graph with every `@pos` pin left out: what the map looks like arranged afresh.
  function unpinned(graph) {
    const out = new MM.notation.Graph();
    for (const [name, n] of graph.nodes) out.nodes.set(name, { ...n, notes: n.notes.filter((x) => splitNote(x).kind !== "pos") });
    out.edges = graph.edges;
    return out;
  }

  MM.layout = { M, compute, unpinned, curve, ends, anchorY, anchorInset, linkWidth, estimate, round, Layout, shownNotes, position };
})(typeof window !== "undefined" ? (window.MM = window.MM || {}) : (globalThis.MM = globalThis.MM || {}));
