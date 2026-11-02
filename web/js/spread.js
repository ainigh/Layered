// Fill the view: the map's nodes slide, a few points at a time, toward its middle and into
// whatever room is around them, until fitting it zooms in as far as it can, and no step makes
// two links cross, a link run through a node, or a node sit on a link. A port of
// Harness/Canvas/Spread.swift, step for step, so it moves the map exactly as the app does.
(function (MM) {
  "use strict";
  const { curve } = MM.layout;

  const PIECES = 32, CLEARANCE = 2, PATIENCE = 60, PROGRESS = 0.001, MAX_STEPS = 4000;
  const MOVES_PER_STEP = 2, MAX_BRANCH = 20, CELL = 96;

  // Swift's `rounded()` (halves away from zero) and `rounded(.towardZero)`.
  const round = (v) => (v < 0 ? -Math.round(-v) : Math.round(v));
  const trunc = Math.trunc;
  const hypot = Math.hypot;

  function keys(x, y, w, h, reach) {
    const x0 = Math.floor((x - reach) / CELL), x1 = Math.floor((x + w + reach) / CELL);
    const y0 = Math.floor((y - reach) / CELL), y1 = Math.floor((y + h + reach) / CELL);
    const out = [];
    for (let i = x0; i <= x1; i++) for (let j = y0; j <= y1; j++) out.push(i * 1000003 + j);
    return out;
  }
  const boxKeys = (b, c = 0) => keys(b.x - c, b.y - c, b.w + 2 * c, b.h + 2 * c, 0);
  const lineKeys = (l, c = 0) => keys(l.x0 - c, l.y0 - c, l.x1 - l.x0 + 2 * c, l.y1 - l.y0 + 2 * c, 0);

  // Sorted, each once.
  function ordered(ids) {
    if (ids.length < 2) return ids;
    const sorted = ids.slice().sort((a, b) => a - b), out = [];
    for (const id of sorted) if (out[out.length - 1] !== id) out.push(id);
    return out;
  }
  const sameKeys = (a, b) => a.length === b.length && a.every((k, i) => k === b[i]);

  // Which things (nodes, or links) lie in which cells, kept up to date as they move.
  class Cells {
    constructor(count) { this.cells = new Map(); this.at = new Map(); this.seen = new Uint32Array(count + 1); this.stamp = 0; }
    put(id, ks) {
      const old = this.at.get(id) || [];
      if (sameKeys(old, ks)) return;
      for (const k of old) { const c = this.cells.get(k); if (c) { const i = c.indexOf(id); if (i >= 0) c.splice(i, 1); } }
      for (const k of ks) { let c = this.cells.get(k); if (!c) { c = []; this.cells.set(k, c); } c.push(id); }
      this.at.set(id, ks);
    }
    // What lies in any of these cells, each once, in index order.
    near(ks) {
      const seen = this.seen, stamp = ++this.stamp, out = [];
      for (const k of ks) {
        const c = this.cells.get(k);
        if (c) for (const id of c) if (seen[id] !== stamp) { seen[id] = stamp; out.push(id); }
      }
      return out.length > 1 ? Array.from(Int32Array.from(out).sort()) : out;
    }
  }

  // Which nodes are near which, rebuilt each step.
  class Grid {
    constructor(boxes, reach) {
      this.reach = reach; this.cells = new Map();
      boxes.forEach((b, i) => { for (const k of keys(b.x, b.y, b.w, b.h, reach)) { let c = this.cells.get(k); if (!c) { c = []; this.cells.set(k, c); } c.push(i); } });
    }
    near(b) {
      const out = [];
      for (const k of keys(b.x, b.y, b.w, b.h, this.reach)) { const c = this.cells.get(k); if (c) for (const id of c) out.push(id); }
      return out;
    }
  }

  const cx = (b) => b.x + b.w / 2, cy = (b) => b.y + b.h / 2;
  const endsOf = (b) => ({ x: b.x, y: b.y, w: b.w, h: b.h, anchorY: b.anchorY, anchorInset: b.anchorInset, pinned: true });

  // A link's curve, routed as the canvas routes it between pinned nodes, flattened (its
  // points' coordinates in `xs` and `ys`).
  function lineBetween(from, to) {
    const c = curve(endsOf(from), endsOf(to));
    const xs = new Float64Array(PIECES + 1), ys = new Float64Array(PIECES + 1);
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (let k = 0; k <= PIECES; k++) {
      const t = k / PIECES, u = 1 - t;
      const a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t;
      const x = a * c.p0.x + b * c.p1.x + cc * c.p2.x + d * c.p3.x, y = a * c.p0.y + b * c.p1.y + cc * c.p2.y + d * c.p3.y;
      xs[k] = x; ys[k] = y;
      x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y);
    }
    return { xs, ys, x0, y0, x1, y1 };
  }
  const middle = (l) => ({ x: l.xs[PIECES >> 1], y: l.ys[PIECES >> 1] });

  // Where two segments meet, if they do.
  function meet(a0, a1, b0, b1) {
    const rx = a1.x - a0.x, ry = a1.y - a0.y, sx = b1.x - b0.x, sy = b1.y - b0.y;
    const qx = b0.x - a0.x, qy = b0.y - a0.y;
    const d = rx * sy - ry * sx;
    if (Math.abs(d) < 1e-12) {
      if (!(Math.abs(qx * ry - qy * rx) < 1e-9)) return null;
      const rr = rx * rx + ry * ry;
      if (!(rr > 1e-12)) return hypot(qx, qy) < 1e-9 ? a0 : null;
      const t0 = (qx * rx + qy * ry) / rr, t1 = t0 + (sx * rx + sy * ry) / rr;
      const lo = Math.max(0, Math.min(t0, t1)), hi = Math.min(1, Math.max(t0, t1));
      if (!(lo <= hi)) return null;
      return { x: a0.x + lo * rx, y: a0.y + lo * ry };
    }
    const t = (qx * sy - qy * sx) / d, u = (qx * ry - qy * rx) / d;
    if (!(t >= 0 && t <= 1 && u >= 0 && u <= 1)) return null;
    return { x: a0.x + t * rx, y: a0.y + t * ry };
  }

  // Does the segment from p to q touch the box (Liang–Barsky)?
  function clips(p, q, x0, y0, x1, y1) {
    let lo = 0, hi = 1;
    const dx = q.x - p.x, dy = q.y - p.y;
    const edge = (den, num) => {
      if (Math.abs(den) < 1e-12) return num >= 0;
      const r = num / den;
      if (den < 0) lo = Math.max(lo, r); else hi = Math.min(hi, r);
      return lo <= hi;
    };
    return edge(-dx, p.x - x0) && edge(dx, x1 - p.x) && edge(-dy, p.y - y0) && edge(dy, y1 - p.y);
  }

  // Does the line pass within c of the box?
  function runs(l, b, c) {
    const x0 = b.x - c, y0 = b.y - c, x1 = b.x + b.w + c, y1 = b.y + b.h + c;
    const xs = l.xs, ys = l.ys;
    for (let s = 1; s < xs.length; s++) {
      const px = xs[s - 1], py = ys[s - 1], qx = xs[s], qy = ys[s];
      if (!(Math.max(px, qx) >= x0 && Math.min(px, qx) <= x1 && Math.max(py, qy) >= y0 && Math.min(py, qy) <= y1)) continue;
      if (clips({ x: px, y: py }, { x: qx, y: qy }, x0, y0, x1, y1)) return true;
    }
    return false;
  }

  class Spread {
    // `viewWidth` × `viewHeight` is the room the map is fitted into, in screen points.
    constructor(layout, viewWidth, viewHeight, gap, maxZoom = Infinity) {
      this.names = layout.nodes.map((n) => n.name);
      // Centres on whole points, as the canvas will place them.
      this.boxes = layout.nodes.map((n) => ({
        x: round(n.x + n.w / 2) - n.w / 2, y: round(n.y + n.h / 2) - n.h / 2, w: n.w, h: n.h,
        anchorY: MM.layout.anchorY(n), anchorInset: MM.layout.anchorInset(n),
      }));
      const links = [], tree = [], linksAt = this.boxes.map(() => []);
      for (const e of layout.edges) {
        const lo = layout.index.get(e.lo), hi = layout.index.get(e.hi);
        if (lo === undefined || hi === undefined || lo === hi) continue;
        const a = layout.directions.get(e.id).a === e.hi ? hi : lo;
        linksAt[lo].push(links.length); linksAt[hi].push(links.length);
        links.push({ a, b: a === lo ? hi : lo });
        tree.push(e.tree);
      }
      this.links = links; this.linksAt = linksAt; this.tree = tree;
      const kids = this.boxes.map(() => []);
      for (const [p, cs] of layout.children) { const pi = layout.index.get(p); if (pi !== undefined) kids[pi] = cs.map((c) => layout.index.get(c)).filter((c) => c !== undefined); }
      this.branches = this.boxes.map((_, i) => {
        const out = [i];
        for (let k = 0; k < out.length && out.length <= MAX_BRANCH; k++) out.push(...kids[out[k]]);
        return out.length > 1 && out.length <= MAX_BRANCH ? out : [];
      });
      this.kept = tree.slice();
      this.gap = Math.max(0, gap);
      this.viewWidth = Math.max(1, viewWidth);
      this.viewHeight = Math.max(1, viewHeight);
      this.maxZoom = maxZoom;
      this.steps = 0; this.finished = false; this.sinceBest = 0;
      this.side = this.boxes.map((_, i) => (i % 2 === 0 ? 1 : -1));
      this.stirred = [];
      this.separate();
      this.lines = links.map((_, e) => this.line(e));
      this.nodeCells = new Cells(this.boxes.length); this.lineCells = new Cells(links.length);
      this.boxes.forEach((b, i) => this.nodeCells.put(i, boxKeys(b)));
      links.forEach((_, e) => { if (this.kept[e]) this.lineCells.put(e, lineKeys(this.lines[e])); });
      // Cross-links clear of the trees, the nodes and each other are kept clear too.
      links.forEach((_, e) => {
        if (this.kept[e]) return;
        let clear = true;
        this.clashesOfLink(e, null, () => { clear = false; return false; });
        if (clear) { this.kept[e] = true; this.lineCells.put(e, lineKeys(this.lines[e])); }
      });
      // Clashes among kept links at the start, which may stay.
      this.allowed = new Set();
      links.forEach((_, e) => { if (this.kept[e]) this.clashesOfLink(e, null, (code) => { this.allowed.add(code); return true; }); });
      // The links at each node that are checked as it moves (the others' curves never matter).
      this.keptAt = linksAt.map((es) => es.filter((e) => this.kept[e]));
      this.best = this.zoom;
      this.finished = this.boxes.length < 2;
    }

    // The trees' links that cross one another or run through a node in this layout.
    static tangles(layout) {
      const s = new Spread(layout, 1, 1, 0);
      const L = s.links.length, pairs = L * L, out = new Set();
      for (const code of s.allowed) {
        if (code < pairs ? s.tree[Math.floor(code / L)] && s.tree[code % L] : (code - pairs) % 2 === 1 && s.tree[Math.floor((code - pairs) / 2 / s.boxes.length)]) out.add(code);
      }
      return out;
    }

    get bounds() {
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const n of this.boxes) { x0 = Math.min(x0, n.x); y0 = Math.min(y0, n.y); x1 = Math.max(x1, n.x + n.w); y1 = Math.max(y1, n.y + n.h); }
      return isFinite(x0) ? { x0, y0, x1, y1 } : { x0: 0, y0: 0, x1: 0, y1: 0 };
    }

    // The zoom that fits the nodes in the view.
    get zoom() {
      const b = this.bounds;
      return Math.min(this.viewWidth / Math.max(1, b.x1 - b.x0), this.viewHeight / Math.max(1, b.y1 - b.y0));
    }

    // Each node's centre now.
    get centers() { return new Map(this.names.map((n, i) => [n, { x: round(cx(this.boxes[i])), y: round(cy(this.boxes[i])) }])); }

    run(limit = Infinity) { for (let n = 0; !this.finished && n < limit; n++) this.step(); }

    // One step: every node, the innermost first, moves by at most a few points.
    step() {
      if (this.finished) return;
      this.steps += 1;
      const boxes = this.boxes, b = this.bounds;
      const scale = Math.max((b.x1 - b.x0) / this.viewWidth, (b.y1 - b.y0) / this.viewHeight);
      const fw = this.viewWidth * scale, fh = this.viewHeight * scale;
      const mx = (b.x0 + b.x1) / 2, my = (b.y0 + b.y1) / 2;
      const fit = { x0: mx - fw / 2, y0: my - fh / 2, x1: mx + fw / 2, y1: my + fh / 2 };
      const shortest = boxes.length ? Math.min(...boxes.map((x) => Math.min(x.w, x.h))) : 1;
      const length = Math.min(Math.max(2, 0.005 * Math.max(fw, fh)), Math.max(1, shortest / 3), 10);
      const grid = new Grid(boxes, this.gap + 2 * length);

      // How far out a node sits, in the view's proportions, squared off.
      const pull = (i) => {
        const nx = (mx - cx(boxes[i])) / fw, ny = (my - cy(boxes[i])) / fh;
        return { x: nx * nx * nx / fw, y: ny * ny * ny / fh, far: nx * nx * nx * nx + ny * ny * ny * ny };
      };
      const order = boxes.map((_, i) => [i, pull(i).far]).sort((p, q) => p[1] - q[1] || p[0] - q[0]).map((p) => p[0]);

      let moved = false;
      this.stirred = boxes.map(() => 0);
      for (const i of order) {
        if (this.stirred[i] >= MOVES_PER_STEP) continue;
        const p = pull(i);
        const norm = hypot(p.x, p.y);
        if (!(norm > 0 && hypot(mx - cx(boxes[i]), my - cy(boxes[i])) > length)) continue;
        const ux = p.x / norm, uy = p.y / norm;
        // Straight in, or along the axis it is furthest out on.
        const along = Math.abs(ux) >= Math.abs(uy) ? { x: ux < 0 ? -1 : 1, y: 0 } : { x: 0, y: uy < 0 ? -1 : 1 };
        let blocker = null, done = false;
        for (const [dx, dy] of [[ux, uy], [along.x, along.y]]) {
          const r = this.attempt(i, dx * length, dy * length, fit, grid);
          if (r.moved) done = true; else if (r.at) blocker = blocker || r.at;
          if (done) break;
        }
        // Blocked: slide across, away from what is in the way, then the other way.
        if (!done && blocker) {
          const sx = -along.y, sy = along.x;
          const away = sx * (cx(boxes[i]) - blocker.x) + sy * (cy(boxes[i]) - blocker.y);
          if (Math.abs(away) > 1) this.side[i] = away > 0 ? 1 : -1;
          for (const sign of [this.side[i], -this.side[i]]) {
            if (this.shove(i, sign * sx * length, sign * sy * length, fit, grid).moved) { this.side[i] = sign; done = true; break; }
          }
        }
        // Still blocked: a shorter step in, up to whatever is in the way.
        if (!done && length >= 4) {
          for (const f of [0.5, 0.25]) {
            if (done) break;
            if (this.attempt(i, ux * length * f, uy * length * f, fit, grid).moved) done = true;
          }
        }
        // Still stuck: move it with its branch, which keeps every link inside the branch as it is.
        let movedWithBranch = false;
        const branch = this.branches[i];
        if (!done && branch.length && !branch.some((m) => this.stirred[m] >= MOVES_PER_STEP)) {
          for (const [dx, dy] of [[ux, uy], [along.x, along.y]]) {
            if (this.attemptGroup(branch, dx * length, dy * length, fit, grid)) {
              for (const m of branch) this.stirred[m] += 1;
              done = true; movedWithBranch = true;
              break;
            }
          }
        }
        if (done && !movedWithBranch) this.stirred[i] += 1;
        moved = moved || done;
      }

      const z = this.zoom;
      if (z > this.best * (1 + PROGRESS)) { this.best = z; this.sinceBest = 0; } else this.sinceBest += 1;
      if (!moved || this.sinceBest >= PATIENCE || z >= this.maxZoom || this.steps >= MAX_STEPS) this.finished = true;
    }

    // Moves node i; when a node is too close that way, first tries moving that one the same way.
    shove(i, dx, dy, fit, grid) {
      const first = this.attempt(i, dx, dy, fit, grid);
      if (first.moved || first.by === undefined || first.by === null || first.by === i || this.stirred[first.by] >= MOVES_PER_STEP) return first;
      if (!this.attempt(first.by, dx, dy, fit, grid).moved) return first;
      this.stirred[first.by] += 1;
      return this.attempt(i, dx, dy, fit, grid);
    }

    // Moves node i by (dx, dy), cut to whole points, when that keeps it in `fit`, no closer
    // than `gap` to any node it was not already too close to, and tangles nothing kept clear.
    attempt(i, dx, dy, fit, grid) {
      dx = trunc(dx); dy = trunc(dy);
      if (dx === 0 && dy === 0) return {};
      const boxes = this.boxes;
      const next = { ...boxes[i], x: boxes[i].x + dx, y: boxes[i].y + dy };
      if (!(next.x >= fit.x0 - 0.5 && next.y >= fit.y0 - 0.5 && next.x + next.w <= fit.x1 + 0.5 && next.y + next.h <= fit.y1 + 0.5)) return {};
      for (const j of grid.near(next)) {
        if (j === i) continue;
        const after = this.overlap(next, boxes[j]);
        if (after > 0 && after > this.overlap(boxes[i], boxes[j])) return { at: { x: cx(boxes[j]), y: cy(boxes[j]) }, by: j };
      }
      const was = boxes[i], mine = this.keptAt[i];
      const wasLines = mine.map((e) => this.lines[e]);
      this.place(i, next, mine.map((e) => [e, this.lineMoved(i, next, e)]));
      let hit = null;
      this.clashesOf(i, (code) => { if (this.allowed.has(code)) return true; hit = code; return false; });
      if (hit === null) return { moved: true };
      this.place(i, was, mine.map((e, k) => [e, wasLines[k]]));
      return { at: this.obstacle(hit, i), by: null };
    }

    // Moves a group of nodes together, on the same terms as one node.
    attemptGroup(group, dx, dy, fit, grid) {
      dx = trunc(dx); dy = trunc(dy);
      if (dx === 0 && dy === 0) return false;
      const boxes = this.boxes, inGroup = new Set(group);
      for (const i of group) {
        const next = { ...boxes[i], x: boxes[i].x + dx, y: boxes[i].y + dy };
        if (!(next.x >= fit.x0 - 0.5 && next.y >= fit.y0 - 0.5 && next.x + next.w <= fit.x1 + 0.5 && next.y + next.h <= fit.y1 + 0.5)) return false;
        for (const j of grid.near(next)) {
          if (inGroup.has(j)) continue;
          const after = this.overlap(next, boxes[j]);
          if (after > 0 && after > this.overlap(boxes[i], boxes[j])) return false;
        }
      }
      const was = group.map((i) => boxes[i]);
      const touched = ordered(group.flatMap((i) => this.keptAt[i]));
      const wasLines = touched.map((e) => this.lines[e]);
      for (const i of group) { boxes[i] = { ...boxes[i], x: boxes[i].x + dx, y: boxes[i].y + dy }; this.nodeCells.put(i, boxKeys(boxes[i])); }
      for (const e of touched) { this.lines[e] = this.line(e); this.lineCells.put(e, lineKeys(this.lines[e])); }
      let clear = true;
      for (const i of group) {
        if (!clear) break;
        this.clashesOf(i, (code) => { if (this.allowed.has(code)) return true; clear = false; return false; });
      }
      if (clear) return true;
      group.forEach((i, k) => { boxes[i] = was[k]; this.nodeCells.put(i, boxKeys(was[k])); });
      touched.forEach((e, k) => { this.lines[e] = wasLines[k]; this.lineCells.put(e, lineKeys(wasLines[k])); });
      return false;
    }

    place(i, box, curves) {
      this.boxes[i] = box;
      this.nodeCells.put(i, boxKeys(box));
      for (const [e, l] of curves) { this.lines[e] = l; if (this.kept[e]) this.lineCells.put(e, lineKeys(l)); }
    }

    lineMoved(i, box, e) {
      const L = this.links[e];
      return lineBetween(L.a === i ? box : this.boxes[L.a], L.b === i ? box : this.boxes[L.b]);
    }
    line(e) { const L = this.links[e]; return lineBetween(this.boxes[L.a], this.boxes[L.b]); }

    // A clash as one number: two links crossing, or a link within CLEARANCE of a node
    // (`through`: running through it).
    linkPair(e, f) { return Math.min(e, f) * this.links.length + Math.max(e, f); }
    linkNode(e, k, through) { return this.links.length * this.links.length + 2 * (e * this.boxes.length + k) + (through ? 1 : 0); }

    obstacle(code, i) {
      const L = this.links.length, pairs = L * L;
      if (code >= pairs) {
        const e = Math.floor((code - pairs) / 2 / this.boxes.length), k = Math.floor((code - pairs) / 2) % this.boxes.length;
        return k === i ? middle(this.lines[e]) : { x: cx(this.boxes[k]), y: cy(this.boxes[k]) };
      }
      const e = Math.floor(code / L), f = code % L;
      return middle(this.lines[this.linksAt[i].includes(e) && !this.linksAt[i].includes(f) ? f : e]);
    }

    // Calls visit with each clash node i is part of, until it returns false.
    clashesOf(i, visit) {
      if (!this.links.length) return;
      const mine = this.linksAt[i];
      for (const e of mine) {
        if (!this.kept[e]) continue;
        if (!this.clashesOfLink(e, (f) => f < e && mine.includes(f), visit)) return;
      }
      const b = this.boxes[i], c = CLEARANCE;
      for (const f of this.lineCells.near(boxKeys(b, c))) {
        if (this.links[f].a === i || this.links[f].b === i) continue;
        const lf = this.lines[f];
        if (!(lf.x0 <= b.x + b.w + c && b.x - c <= lf.x1 && lf.y0 <= b.y + b.h + c && b.y - c <= lf.y1)) continue;
        if (runs(lf, b, c)) {
          if (!visit(this.linkNode(f, i, false))) return;
          if (runs(lf, b, 0) && !visit(this.linkNode(f, i, true))) return;
        }
      }
    }

    clashesOfLink(e, skip, visit) {
      const le = this.lines[e];
      for (const f of this.lineCells.near(lineKeys(le))) {
        if (f === e || (skip && skip(f))) continue;
        const lf = this.lines[f];
        if (!(le.x0 <= lf.x1 && lf.x0 <= le.x1 && le.y0 <= lf.y1 && lf.y0 <= le.y1)) continue;
        if (this.cross(e, f) && !visit(this.linkPair(e, f))) return false;
      }
      const c = CLEARANCE;
      for (const k of this.nodeCells.near(lineKeys(le, c))) {
        if (k === this.links[e].a || k === this.links[e].b) continue;
        const b = this.boxes[k];
        if (!(le.x0 <= b.x + b.w + c && b.x - c <= le.x1 && le.y0 <= b.y + b.h + c && b.y - c <= le.y1)) continue;
        if (runs(le, b, c)) {
          if (!visit(this.linkNode(e, k, false))) return false;
          if (runs(le, b, 0) && !visit(this.linkNode(e, k, true))) return false;
        }
      }
      return true;
    }

    // Do links e and f cross? Two links from one node meet there; only a crossing away counts.
    cross(e, f) {
      const Le = this.links[e], Lf = this.links[f];
      const shared = [Le.a, Le.b].find((n) => n === Lf.a || n === Lf.b);
      const le = this.lines[e], lf = this.lines[f];
      const ex = le.xs, ey = le.ys, fx = lf.xs, fy = lf.ys;
      for (let s = 1; s < ex.length; s++) {
        const ax0 = ex[s - 1], ay0 = ey[s - 1], ax1 = ex[s], ay1 = ey[s];
        if (!(Math.max(ax0, ax1) >= lf.x0 && Math.min(ax0, ax1) <= lf.x1 && Math.max(ay0, ay1) >= lf.y0 && Math.min(ay0, ay1) <= lf.y1)) continue;
        for (let t = 1; t < fx.length; t++) {
          const bx0 = fx[t - 1], by0 = fy[t - 1], bx1 = fx[t], by1 = fy[t];
          if (!(Math.max(ax0, ax1) >= Math.min(bx0, bx1) && Math.max(bx0, bx1) >= Math.min(ax0, ax1) &&
                Math.max(ay0, ay1) >= Math.min(by0, by1) && Math.max(by0, by1) >= Math.min(ay0, ay1))) continue;
          const p = meet({ x: ax0, y: ay0 }, { x: ax1, y: ay1 }, { x: bx0, y: by0 }, { x: bx1, y: by1 });
          if (!p) continue;
          if (shared !== undefined) {
            const n = this.boxes[shared], c = CLEARANCE;
            if (p.x >= n.x - c && p.x <= n.x + n.w + c && p.y >= n.y - c && p.y <= n.y + n.h + c) continue;
          }
          return true;
        }
      }
      return false;
    }

    overlap(a, b) {
      const ox = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) + this.gap;
      const oy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y) + this.gap;
      return ox > 1e-6 && oy > 1e-6 ? Math.min(ox, oy) : 0;
    }

    // Pushes apart nodes closer than `gap`, each pair along the way that parts it soonest.
    separate() {
      const boxes = this.boxes;
      for (let round_ = 0; round_ < 200; round_++) {
        let clean = true;
        const grid = new Grid(boxes, this.gap);
        for (let i = 0; i < boxes.length; i++) {
          for (const j of grid.near(boxes[i])) {
            if (j <= i) continue;
            const a = boxes[i], b = boxes[j];
            const ox = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) + this.gap;
            const oy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y) + this.gap;
            if (!(ox > 1e-6 && oy > 1e-6)) continue;
            clean = false;
            if (ox < oy) {
              const d = (cx(a) < cx(b) || (cx(a) === cx(b) && i < j) ? -1 : 1) * Math.ceil(ox / 2 + 0.01);
              boxes[i] = { ...a, x: a.x + d }; boxes[j] = { ...b, x: b.x - d };
            } else {
              const d = (cy(a) < cy(b) || (cy(a) === cy(b) && i < j) ? -1 : 1) * Math.ceil(oy / 2 + 0.01);
              boxes[i] = { ...a, y: a.y + d }; boxes[j] = { ...b, y: b.y - d };
            }
          }
        }
        if (clean) return;
      }
    }
  }

  MM.Spread = Spread;
  MM.spread = { PIECES, CLEARANCE, meet, runs, lineBetween };
})(typeof window !== "undefined" ? (window.MM = window.MM || {}) : (globalThis.MM = globalThis.MM || {}));
