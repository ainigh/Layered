// Arrange to fit: the same trees rearranged to the view's shape, in ways that never cross a
// link (a root's branches on both sides, or round it in a ring; trees side by side), the one
// a short trial spread gets furthest with. A port of Harness/Canvas/Arrange.swift.
(function (MM) {
  "use strict";
  const { M } = MM.layout;
  const round = (v) => (v < 0 ? -Math.round(-v) : Math.round(v));
  const TRIAL_NODES = 150, TRIAL_STEPS = 150, RING_FROM = 5;

  // Each tree as a block: its nodes' centres from the block's top left corner, and its size.
  function toBlock(layout, centers) {
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    for (const [n, c] of centers) {
      const p = layout.get(n);
      x0 = Math.min(x0, c.x - p.w / 2); x1 = Math.max(x1, c.x + p.w / 2);
      y0 = Math.min(y0, c.y - p.h / 2); y1 = Math.max(y1, c.y + p.h / 2);
    }
    const moved = new Map();
    for (const [n, c] of centers) moved.set(n, { x: c.x - x0, y: c.y - y0 });
    return { centers: moved, width: x1 - x0, height: y1 - y0 };
  }

  // A root with its single-node branches round it, clockwise from the top, on an ellipse
  // `aspect` times as wide as it is tall, just big enough that neighbours keep apart.
  function ringBlock(layout, root, kids, aspect) {
    const n = kids.length, boxes = kids.map((k) => layout.get(k));
    const turn = 2 * Math.PI / n;
    const angles = kids.map((_, k) => (k + 0.5) * turn - Math.PI / 2);
    const room = M.minColumnGap;
    const tallest = Math.max(0, ...boxes.map((b) => b.h)), widest = Math.max(0, ...boxes.map((b) => b.w));
    let ry = Math.max(root.h / 2 + room + tallest / 2, (root.w / 2 + room + widest / 2) / aspect);
    const at = (k, r) => ({ x: aspect * r * Math.cos(angles[k]), y: r * Math.sin(angles[k]) });
    const clear = (r) => {
      for (let k = 0; k < n; k++) {
        const j = (k + 1) % n;
        if (j === k) continue;
        const a = at(k, r), b = at(j, r);
        const dx = Math.abs(a.x - b.x) - (boxes[k].w + boxes[j].w) / 2;
        const dy = Math.abs(a.y - b.y) - (boxes[k].h + boxes[j].h) / 2;
        if (Math.max(dx, dy) < M.siblingGap * 2) return false;
      }
      return true;
    };
    while (!clear(ry)) ry *= 1.05;
    const centers = new Map([[root.name, { x: 0, y: 0 }]]);
    kids.forEach((k, i) => centers.set(k, at(i, ry)));
    return toBlock(layout, centers);
  }

  // Every tree as a block, in drawing order; `bothSides` splits a root's branches between its
  // right and its (mirrored) left; `ring` sets a root's single-node branches round it.
  function trees(layout, bothSides, ring = null) {
    const columnX = new Map();
    for (const n of layout.nodes) columnX.set(n.depth, Math.min(columnX.has(n.depth) ? columnX.get(n.depth) : Infinity, n.x));
    const kidsOf = (name) => layout.children.get(name) || [];
    const span = new Map();
    const measure = (name) => {
      const kids = kidsOf(name);
      const total = Math.max(layout.get(name).h, kids.reduce((s, k) => s + measure(k), 0) + M.siblingGap * Math.max(0, kids.length - 1));
      span.set(name, total);
      return total;
    };
    const height = (kids) => kids.reduce((s, k) => s + span.get(k), 0) + M.siblingGap * Math.max(0, kids.length - 1);
    const blocks = [];
    for (const root of layout.nodes) {
      if (layout.parent.has(root.name)) continue;
      const name = root.name;
      measure(name);
      const kids = kidsOf(name);
      if (ring !== null && kids.length >= RING_FROM && kids.every((k) => kidsOf(k).length === 0)) {
        blocks.push(ringBlock(layout, root, kids, ring));
        continue;
      }
      let split = kids.length;
      if (bothSides && kids.length > 1) {
        let bestGap = Infinity;
        for (let k = 1; k < kids.length; k++) {
          const g = Math.max(height(kids.slice(0, k)), height(kids.slice(k)));
          if (g < bestGap) { bestGap = g; split = k; }
        }
      }
      const right = kids.slice(0, split), left = kids.slice(split).reverse();
      const tall = Math.max(root.h, height(right), height(left));
      const centers = new Map(), mid = tall / 2, axis = root.x + root.w / 2;
      const place = (n, top, side) => {
        const p = layout.get(n);
        const x = p.depth === 0 ? p.x : columnX.get(p.depth);
        centers.set(n, { x: side > 0 ? x + p.w / 2 : 2 * axis - (x + p.w / 2), y: top + span.get(n) / 2 });
        const ks = kidsOf(n);
        let y = top + (span.get(n) - height(ks)) / 2;
        for (const k of ks) { place(k, y, side); y += span.get(k) + M.siblingGap; }
      };
      centers.set(name, { x: axis, y: mid });
      for (const [side_, ks] of [[1, right], [-1, left]]) {
        let y = mid - height(ks) / 2;
        for (const k of ks) { place(k, y, side_); y += span.get(k) + M.siblingGap; }
      }
      blocks.push(toBlock(layout, centers));
    }
    return blocks;
  }

  // The blocks in `columns` columns, each going to the shortest column so far.
  function pack(blocks, columns) {
    const gap = M.treeGap;
    const heights = Array(columns).fill(0), widths = Array(columns).fill(0), placed = [];
    blocks.forEach((b, i) => {
      let c = 0;
      for (let k = 1; k < columns; k++) if (heights[k] < heights[c]) c = k;
      placed.push({ block: i, column: c, y: heights[c] === 0 ? 0 : heights[c] + gap });
      heights[c] = (heights[c] === 0 ? 0 : heights[c] + gap) + b.height;
      widths[c] = Math.max(widths[c], b.width);
    });
    const lefts = [];
    let x = 0;
    for (const w of widths) { lefts.push(x); x += w + (w > 0 ? 2 * gap : 0); }
    const centers = new Map();
    for (const p of placed) for (const [n, c] of blocks[p.block].centers) centers.set(n, { x: round(lefts[p.column] + c.x), y: round(p.y + c.y) });
    const used = widths.filter((w) => w > 0);
    return { centers, width: used.reduce((s, w) => s + w, 0) + 2 * gap * Math.max(0, used.length - 1), height: Math.max(0, ...heights) };
  }

  const subset = (a, b) => { for (const x of a) if (!b.has(x)) return false; return true; };

  // The arrangement to spread from, for a view `viewWidth` × `viewHeight` and spacing `gap`.
  function arranged(layout, viewWidth, viewHeight, gap = 24) {
    if (layout.nodes.length < 2) return layout;
    const plain = layout.placing(layout.centers());
    const already = MM.Spread.tangles(plain);
    const options = [trees(layout, false), trees(layout, true)];
    for (const aspect of [0.7, 1.0, 1.4, 2.0]) options.push(trees(layout, true, aspect));
    const candidates = [plain];
    for (const blocks of options) {
      let best = null;
      for (let columns = 1; columns <= Math.max(1, Math.min(blocks.length, 8)); columns++) {
        const packed = pack(blocks, columns);
        const zoom = Math.min(viewWidth / Math.max(1, packed.width), viewHeight / Math.max(1, packed.height));
        if (best === null || zoom > best.zoom * 1.01) best = { zoom, centers: packed.centers };
      }
      const laid = layout.placing(best.centers);
      if (!candidates.some((c) => c.sameAs(laid)) && subset(MM.Spread.tangles(laid), already)) candidates.push(laid);
    }
    const score = (l) => {
      const s = new MM.Spread(l, viewWidth, viewHeight, gap);
      if (layout.nodes.length <= TRIAL_NODES) s.run(TRIAL_STEPS);
      return s.zoom;
    };
    // In a near tie (within 2%) the one with fewer links crossing wins, then the plainer.
    let best = { layout: plain, score: score(plain), tangles: already.size };
    for (const c of candidates.slice(1)) {
      const s = score(c), t = MM.Spread.tangles(c).size;
      if (s > best.score * 1.02 || (s >= best.score / 1.02 && t < best.tangles)) best = { layout: c, score: Math.max(s, best.score), tangles: t };
    }
    return best.layout;
  }

  MM.arrange = { arranged, trees, pack };
})(typeof window !== "undefined" ? (window.MM = window.MM || {}) : (globalThis.MM = globalThis.MM || {}));
