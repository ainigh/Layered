// An independent check, from the drawn curves themselves: two links crossing away from a node
// they share, or a link running through a node it doesn't join. Used by test/check.js and by
// test/browser.js (inside the page).
(function (MM) {
  "use strict";
  function point(e, t) {
    const u = 1 - t, a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    return { x: a * e.p0.x + b * e.p1.x + c * e.p2.x + d * e.p3.x, y: a * e.p0.y + b * e.p1.y + c * e.p2.y + d * e.p3.y };
  }
  // `only`: the links to look at (a Set of edge ids), all when left out.
  function clashes(layout, only) {
    const edges = layout.edges.filter((e) => !only || only.has(e.id));
    const pieces = MM.spread.PIECES, clear = MM.spread.CLEARANCE;
    const lines = edges.map((e) => Array.from({ length: pieces + 1 }, (_, k) => point(e, k / pieces)));
    const fine = edges.map((e) => Array.from({ length: 65 }, (_, k) => point(e, k / 64)));
    const box = (l) => ({ x0: Math.min(...l.map((p) => p.x)), y0: Math.min(...l.map((p) => p.y)), x1: Math.max(...l.map((p) => p.x)), y1: Math.max(...l.map((p) => p.y)) });
    const around = lines.map(box);
    const meets = (a, b) => a.x0 <= b.x1 && b.x0 <= a.x1 && a.y0 <= b.y1 && b.y0 <= a.y1;
    const inside = (p, n, g) => p.x > n.x - g && p.x < n.x + n.w + g && p.y > n.y - g && p.y < n.y + n.h + g;
    const out = new Set();
    edges.forEach((e, i) => {
      for (const n of layout.nodes) {
        if (n.name === e.lo || n.name === e.hi) continue;
        if (meets(around[i], { x0: n.x, y0: n.y, x1: n.x + n.w, y1: n.y + n.h }) && fine[i].some((p) => inside(p, n, -0.5))) out.add(`${e.lo}–${e.hi} through ${n.name}`);
      }
      for (let j = i + 1; j < edges.length; j++) {
        const f = edges[j];
        if (!meets(around[i], around[j])) continue;
        const shared = [e.lo, e.hi].find((x) => x === f.lo || x === f.hi);
        let found = false;
        for (let s = 1; s < lines[i].length && !found; s++) {
          for (let t = 1; t < lines[j].length && !found; t++) {
            const p = MM.spread.meet(lines[i][s - 1], lines[i][s], lines[j][t - 1], lines[j][t]);
            if (!p) continue;
            if (shared !== undefined && inside(p, layout.get(shared), clear + 0.5)) continue;
            found = true;
          }
        }
        if (found) out.add(`${e.lo}–${e.hi} crosses ${f.lo}–${f.hi}`);
      }
    });
    return out;
  }
  MM.check = { clashes };
})(typeof window !== "undefined" ? (window.MM = window.MM || {}) : (globalThis.MM = globalThis.MM || {}));
