// Draws a layout on a canvas the way the app's canvas does (App/Sources/Mindmap/Canvas/CanvasView.swift):
// open nodes (an icon above the name), cards for the model's extras, branch colours, links that
// taper from the root, dashed cross-links, labels on chips, and a dot grid that moves with the map.
(function (MM) {
  "use strict";
  const { M, linkWidth, anchorY } = MM.layout;
  const { splitNote } = MM.notation;

  const FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';
  const FONTS = { name: `500 13px ${FONT}`, root: `600 13px ${FONT}`, note: `500 11.5px ${FONT}`, label: `400 10px ${FONT}` };

  // The map's colours (Harness/Canvas/MapPalette.swift).
  const PALETTES = {
    light: {
      hues: [["#2c5fc0", "#d9e5f7"], ["#6a45c9", "#e4dcf6"], ["#137a70", "#d3ece8"], ["#9a5b00", "#f4e6cd"], ["#b8355e", "#f5dbe2"],
             ["#2b7a3d", "#d7eedb"], ["#ad4f19", "#f7e0d0"], ["#9e3898", "#f1d9f0"], ["#5a6a10", "#e8edcc"], ["#4d5b6e", "#dfe3e8"]],
      background: "#f4f5f8", dot: "#d3d6dd", primary: "#151821", secondary: "#454c5c", tertiary: "#6b7282",
      world: "#e3edfb", worldInk: "#3d6fc4", guess: "#eef0f3", guessInk: "#8a909c", advice: "#fdf1dc", adviceInk: "#b7791f",
      accent: "#0a84ff",
    },
    dark: {
      hues: [["#8db4ff", "#0f1a2e"], ["#b9a1ff", "#1a1430"], ["#5fd3c4", "#0b2320"], ["#f2b75a", "#281d0b"], ["#ff9cb8", "#2a121a"],
             ["#6fd58a", "#0d2414"], ["#ffa36b", "#2a170b"], ["#f08ee8", "#26112a"], ["#c4d65a", "#1d200a"], ["#a9b6c8", "#161a20"]],
      background: "#16181d", dot: "#2e313a", primary: "#f3f4f7", secondary: "#c0c5d0", tertiary: "#9aa1ae",
      world: "#172338", worldInk: "#8db4ff", guess: "#25272d", guessInk: "#7d8493", advice: "#3a2c14", adviceInk: "#f2b75a",
      accent: "#3b9bff",
    },
  };
  const KIND_COLOURS = { person: "#3b7dd9", place: "#299e8f", thing: "#6b5ce8", action: "#e07a1f", event: "#d63a6b", idea: "#c9a326" };
  const TINTS = { red: "#ff3b30", orange: "#ff9500", yellow: "#ffcc00", green: "#34c759", blue: "#007aff", purple: "#af52de", pink: "#ff2d55", gray: "#8e8e93" };
  // Words in a name that colour its icon (Harness/Canvas/IconTint.swift), most pressing first.
  const TINT_WORDS = {
    red: "red crimson scarlet urgent urgency danger dangerous critical emergency error fail failure failed fatal severe blocker blocked blocking bug crash broken incident outage crisis threat hazard stop asap fire panic alarm attack breach",
    orange: "orange amber warning warn caution risk risky important priority deadline overdue late delay delayed issue problem concern escalation escalate attention",
    yellow: "yellow gold golden idea maybe draft wip tentative pending todo review progress question unsure unknown highlight",
    green: "green done complete completed finished success successful approved approve ok okay good great healthy safe resolved fixed pass passed win won profit growth ready launched shipped eco sustainable",
    blue: "blue navy info information note fyi plan planned calm trust water ocean sky cold reference doc documentation",
    purple: "purple violet lilac creative creativity magic dream vision royal mystery experiment experimental ai research",
    pink: "pink rose love loved heart favorite favourite romance romantic sweet cute",
    gray: "gray grey silver archived archive deprecated obsolete cancelled canceled inactive paused hold parked dormant retired legacy someday",
  };
  const tintSets = Object.fromEntries(Object.entries(TINT_WORDS).map(([k, v]) => [k, new Set(v.split(" "))]));
  const singular = (w) => (w.length > 3 && w.endsWith("ies") ? w.slice(0, -3) + "y" : w.length > 3 && w.endsWith("s") && !w.endsWith("ss") ? w.slice(0, -1) : w);
  function tintOf(name) {
    const tokens = new Set(name.toLowerCase().split(/[^\p{L}]+/u).filter(Boolean).map(singular));
    for (const [k, words] of Object.entries(tintSets)) for (const t of tokens) if (words.has(t)) return TINTS[k];
    return null;
  }

  // Icons in the spirit of the app's SF Symbols, drawn in a 24-unit box.
  const ICONS = {
    person: "M12 12a4.2 4.2 0 1 0 0-8.4 4.2 4.2 0 0 0 0 8.4Z M4.5 20.5c.6-4 3.6-6.3 7.5-6.3s6.9 2.3 7.5 6.3",
    place: "M12 21.5s-6.5-6.4-6.5-11.3a6.5 6.5 0 0 1 13 0c0 4.9-6.5 11.3-6.5 11.3Z M12 12.4a2.3 2.3 0 1 0 0-4.6 2.3 2.3 0 0 0 0 4.6Z",
    thing: "M12 2.8 20 7.2v9.6l-8 4.4-8-4.4V7.2Z M4 7.2l8 4.4 8-4.4 M12 11.6v9.6",
    action: "M13.5 2.5 5 13.5h6.5L10.5 21.5 19 10.5h-6.5Z",
    event: "M4.5 6.5h15v13.5h-15Z M4.5 10.5h15 M8.5 4v4 M15.5 4v4",
    idea: "M9 18h6 M9.8 21h4.4 M12 3a6 6 0 0 0-3.6 10.8c.6.5 1 1.3 1 2.1V16h5.2v-.1c0-.8.4-1.6 1-2.1A6 6 0 0 0 12 3Z",
    circle: "M12 20a8 8 0 1 0 0-16 8 8 0 0 0 0 16Z",
    globe: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z M3 12h18 M12 3c2.5 2.6 3.7 5.6 3.7 9s-1.2 6.4-3.7 9c-2.5-2.6-3.7-5.6-3.7-9S9.5 5.6 12 3Z",
    question: "M8.6 8.7a3.5 3.5 0 1 1 5 3.2c-1 .5-1.6 1.3-1.6 2.4v.7 M12 18.5v.5",
    bulb: "M9 18h6 M9.8 21h4.4 M12 3a6 6 0 0 0-3.6 10.8c.6.5 1 1.3 1 2.1V16h5.2v-.1c0-.8.4-1.6 1-2.1A6 6 0 0 0 12 3Z",
    pencil: "M15.5 4.5l4 4L8 20H4v-4Z",
  };
  const paths = {};
  const icon = (name) => (paths[name] = paths[name] || new Path2D(ICONS[name] || ICONS.circle));
  const BADGES = { world: "globe", guess: "question", advice: "bulb", user: "pencil" };

  function drawIcon(ctx, name, cx, cy, size, ink, weight = 1.6) {
    ctx.save();
    ctx.translate(cx - size / 2, cy - size / 2);
    ctx.scale(size / 24, size / 24);
    // `weight` points of stroke per 20 points of icon, as SF Symbols' regular weight.
    ctx.strokeStyle = ink; ctx.lineWidth = weight * 1.2; ctx.lineJoin = "round"; ctx.lineCap = "round";
    ctx.stroke(icon(name));
    ctx.restore();
  }

  // Widths as the canvas sets the text, so open nodes and cards fit their names exactly.
  const measureCtx = typeof document !== "undefined" ? document.createElement("canvas").getContext("2d") : null;
  const widths = new Map();
  function measure(text, role) {
    const key = role + "\u0001" + text;
    let w = widths.get(key);
    if (w === undefined) {
      measureCtx.font = FONTS[role === "name" ? "name" : role === "label" ? "label" : "note"];
      w = Math.ceil(measureCtx.measureText(text).width);
      if (widths.size > 20000) widths.clear();
      widths.set(key, w);
    }
    return w;
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.roundRect ? ctx.roundRect(x, y, w, h, r) : ctx.rect(x, y, w, h);
  }

  function arrow(ctx, tip, from, colour, scale) {
    const dx = tip.x - from.x, dy = tip.y - from.y, d = Math.max(Math.hypot(dx, dy), 0.001);
    const ux = dx / d, uy = dy / d, length = 6 * scale, half = 2.4 * scale;
    ctx.beginPath();
    ctx.moveTo(tip.x, tip.y);
    ctx.lineTo(tip.x - ux * length - uy * half, tip.y - uy * length + ux * half);
    ctx.lineTo(tip.x - ux * length + uy * half, tip.y - uy * length - ux * half);
    ctx.closePath();
    ctx.fillStyle = colour;
    ctx.fill();
  }

  const hue = (pal, branch) => (branch > 0 ? pal.hues[(branch - 1) % pal.hues.length][0] : null);

  // `date 2026-11-03`: the kind set quieter than what it says.
  function drawNote(ctx, pal, note, x, y, align) {
    ctx.font = FONTS.note;
    const s = splitNote(note);
    const parts = s.kind.length <= 12 && s.value ? [[s.kind + " ", pal.tertiary], [s.value, pal.secondary]] : [[note, pal.secondary]];
    const total = parts.reduce((w, [t]) => w + ctx.measureText(t).width, 0);
    let at = align === "center" ? x - total / 2 : x;
    ctx.textAlign = "left";
    for (const [t, c] of parts) { ctx.fillStyle = c; ctx.fillText(t, at, y); at += ctx.measureText(t).width; }
  }

  function drawEdge(ctx, pal, layout, e, lit) {
    const colour = hue(pal, e.branch) || pal.tertiary;
    const width = linkWidth(e.tree, layout.depthOf(e)) + (lit ? 0.75 : 0);
    ctx.save();
    if (e.src === "guess") ctx.globalAlpha *= 0.75;
    ctx.setLineDash(e.src === "guess" ? [2, 3] : e.src === "world" ? [6, 4] : e.tree ? [] : [5, 4]);
    ctx.beginPath();
    ctx.moveTo(e.p0.x, e.p0.y);
    ctx.bezierCurveTo(e.p1.x, e.p1.y, e.p2.x, e.p2.y, e.p3.x, e.p3.y);
    ctx.strokeStyle = colour; ctx.lineWidth = width; ctx.lineCap = "round";
    ctx.stroke();
    ctx.setLineDash([]);
    const head = Math.max(1, width / 1.25);
    const same = (a, b) => a.x === b.x && a.y === b.y;
    if (e.arrowEnd) arrow(ctx, e.p3, same(e.p2, e.p3) ? e.p0 : e.p2, colour, head);
    if (e.arrowStart) arrow(ctx, e.p0, same(e.p1, e.p0) ? e.p3 : e.p1, colour, head);
    ctx.restore();
  }

  function drawLabel(ctx, pal, e) {
    const lines = [[e.label, true], [e.note, false]].filter(([t]) => t);
    lines.forEach(([text, main], i) => {
      ctx.font = (e.tree ? "" : "italic ") + FONTS.label;
      const w = ctx.measureText(text).width, h = 12;
      const x = e.labelAt.x, y = e.labelAt.y + (i - (lines.length - 1) / 2) * M.labelLine;
      ctx.globalAlpha = 0.92;
      ctx.fillStyle = pal.background;
      roundRect(ctx, x - w / 2 - 4, y - h / 2 - 1, w + 8, h + 2, (h + 2) / 2);
      ctx.fill();
      ctx.globalAlpha = 1;
      ctx.fillStyle = main ? pal.secondary : pal.tertiary;
      ctx.textAlign = "center";
      ctx.fillText(text, x, y);
    });
  }

  // Text too small to read, as a soft bar as long as it.
  function greek(ctx, line, x, y, center, maxWidth, ink) {
    const w = Math.min(maxWidth, line.length * 6.6), h = 7;
    ctx.globalAlpha = 0.3; ctx.fillStyle = ink;
    roundRect(ctx, center ? x - w / 2 : x, y - h / 2, w, h, h / 2);
    ctx.fill();
    ctx.globalAlpha = 1;
  }

  function iconFor(n) { return ICONS[n.kind] ? n.kind : "circle"; }

  // From the context or the user: the icon above the name, no card.
  function drawOpen(ctx, pal, n, full) {
    const cx = n.x + n.w / 2, iconY = n.y + anchorY(n);
    const ink = tintOf(n.name) || (n.kind ? KIND_COLOURS[n.kind] || pal.secondary : hue(pal, n.branch) || pal.secondary);
    const nameY = n.y + M.openPadY + M.iconLine + M.iconGap + M.nameLine / 2;
    if (!full) {
      const d = M.iconBox - 8;
      ctx.globalAlpha = 0.85; ctx.fillStyle = ink;
      ctx.beginPath(); ctx.arc(cx, iconY, d / 2, 0, 2 * Math.PI); ctx.fill();
      ctx.globalAlpha = 1;
      n.nameLines.forEach((l, i) => greek(ctx, l, cx, nameY + i * M.nameLine, true, n.w, pal.primary));
      return;
    }
    drawIcon(ctx, iconFor(n), cx, iconY, 26, ink);
    if (n.badge && BADGES[n.src]) drawIcon(ctx, BADGES[n.src], cx + M.iconBox / 2 + 3, iconY - M.iconLine / 2 + 5, 10, pal.tertiary, 2);
    ctx.font = n.depth === 0 ? FONTS.root : FONTS.name;
    ctx.fillStyle = pal.primary; ctx.textAlign = "center";
    n.nameLines.forEach((l, i) => ctx.fillText(l, cx, nameY + i * M.nameLine));
    n.notes.forEach((note, i) => drawNote(ctx, pal, note, cx, nameY + (n.nameLines.length - 0.5) * M.nameLine + (i + 0.5) * M.noteLine, "center"));
  }

  // The model's extras: a card in the colours of its provenance.
  function drawCard(ctx, pal, n, full) {
    const [fill, ink] = n.src === "world" ? [pal.world, pal.worldInk] : n.src === "advice" ? [pal.advice, pal.adviceInk] : [pal.guess, pal.guessInk];
    ctx.save();
    if (n.src === "guess") ctx.globalAlpha *= 0.65;
    ctx.fillStyle = "rgba(0,0,0,0.06)";
    roundRect(ctx, n.x, n.y + 1, n.w, n.h, 8); ctx.fill();
    ctx.fillStyle = fill;
    roundRect(ctx, n.x, n.y, n.w, n.h, 8); ctx.fill();
    ctx.setLineDash(n.src === "world" ? [6, 4] : n.src === "guess" ? [2, 3] : []);
    ctx.strokeStyle = ink; ctx.lineWidth = 1.5; ctx.stroke();
    ctx.setLineDash([]);
    if (n.src === "advice") { roundRect(ctx, n.x + 3, n.y + 3, n.w - 6, n.h - 6, 5); ctx.lineWidth = 1; ctx.stroke(); }
    const nameY = n.y + M.padY + M.nameLine / 2;
    let x = n.x + M.padX;
    if (!full) {
      n.nameLines.forEach((l, i) => greek(ctx, l, x, nameY + i * M.nameLine, false, n.w - 2 * M.padX, pal.primary));
      ctx.restore();
      return;
    }
    if (n.glyph) {
      drawIcon(ctx, iconFor(n), x + 6, nameY, 13, tintOf(n.name) || KIND_COLOURS[n.kind] || pal.secondary, 2);
      x += M.glyphRoom(1);
    }
    ctx.font = n.depth === 0 ? FONTS.root : FONTS.name;
    ctx.fillStyle = pal.primary; ctx.textAlign = "left";
    n.nameLines.forEach((l, i) => ctx.fillText(l, x, nameY + i * M.nameLine));
    if (n.badge && BADGES[n.src]) drawIcon(ctx, BADGES[n.src], n.x + n.w - M.padX - M.badge / 2 + 3, nameY, 11, ink, 2);
    n.notes.forEach((note, i) => drawNote(ctx, pal, note, n.x + M.padX, n.y + M.padY + n.nameLines.length * M.nameLine + (i + 0.5) * M.noteLine, "left"));
    ctx.restore();
  }

  function drawNode(ctx, pal, n, full, hovered) {
    if (!n.boxed) {
      // A tree's root sits on a plate; a hovered node is lit on one.
      const root = n.depth === 0 && n.childCount > 0;
      if (root || hovered) {
        roundRect(ctx, n.x - 4, n.y - 2, n.w + 8, n.h + 4, 10);
        ctx.fillStyle = pal.primary; ctx.globalAlpha = root ? 0.05 : 0.04; ctx.fill(); ctx.globalAlpha = 1;
        if (root) { ctx.strokeStyle = pal.primary; ctx.globalAlpha = 0.1; ctx.lineWidth = 0.75; ctx.stroke(); ctx.globalAlpha = 1; }
      }
      drawOpen(ctx, pal, n, full);
    } else drawCard(ctx, pal, n, full);
  }

  // A faint dot grid that moves with the map.
  function drawDots(ctx, pal, width, height, view) {
    let gap = 20 * view.k;
    while (gap < 14) gap *= 2;
    const r = Math.min(1.4, Math.max(0.7, view.k));
    ctx.fillStyle = pal.dot;
    ctx.beginPath();
    for (let x = ((view.x % gap) + gap) % gap; x < width; x += gap) {
      for (let y = ((view.y % gap) + gap) % gap; y < height; y += gap) { ctx.moveTo(x + r, y); ctx.arc(x, y, r, 0, 2 * Math.PI); }
    }
    ctx.fill();
  }

  // Zoomed far out: each tree's root and first branches named on a chip, at a size to read.
  function drawOverviewNames(ctx, pal, layout, view, width, height) {
    const taken = [];
    const on = (n) => { const x = (n.x + n.w / 2) * view.k + view.x, y = (n.y + n.h / 2) * view.k + view.y; return x >= 0 && y >= 0 && x <= width && y <= height ? { x, y } : null; };
    const order = layout.nodes.filter((n) => n.depth <= 1 && (n.depth === 1 || n.childCount > 0) && on(n)).sort((a, b) => a.depth - b.depth || b.childCount - a.childCount);
    for (const n of order.slice(0, 120)) {
      const at = on(n), root = n.depth === 0;
      const ink = root ? pal.primary : hue(pal, n.branch) || pal.primary;
      ctx.font = `${root ? 700 : 600} ${root ? 13 : 11.5}px ${FONT}`;
      const w = Math.min(220, ctx.measureText(n.name).width), h = root ? 16 : 14;
      const chip = { x: at.x - w / 2 - 6, y: at.y - h / 2 - 2, w: w + 12, h: h + 4 };
      if (taken.some((t) => t.x - 2 < chip.x + chip.w && chip.x < t.x + t.w + 2 && t.y - 2 < chip.y + chip.h && chip.y < t.y + t.h + 2)) continue;
      taken.push(chip);
      ctx.globalAlpha = 0.9; ctx.fillStyle = pal.background;
      roundRect(ctx, chip.x, chip.y, chip.w, chip.h, chip.h / 2); ctx.fill();
      ctx.globalAlpha = 0.35; ctx.strokeStyle = ink; ctx.lineWidth = 1; ctx.stroke();
      ctx.globalAlpha = 1; ctx.fillStyle = ink; ctx.textAlign = "center";
      ctx.fillText(n.name, at.x, at.y, 220);
    }
  }

  // The whole map, in a canvas `width` × `height` (CSS pixels) with this view.
  function draw(ctx, layout, view, width, height, options = {}) {
    const pal = options.palette || PALETTES.light;
    ctx.fillStyle = pal.background;
    ctx.fillRect(0, 0, width, height);
    drawDots(ctx, pal, width, height, view);
    if (!layout) return;
    const full = view.k >= 0.45;
    ctx.save();
    ctx.translate(view.x, view.y);
    ctx.scale(view.k, view.k);
    ctx.textBaseline = "middle";
    // What is on screen, in map points.
    const seen = { x0: -view.x / view.k, y0: -view.y / view.k, x1: (width - view.x) / view.k, y1: (height - view.y) / view.k };
    const hovered = options.hovered;
    for (const e of layout.edges) {
      const x0 = Math.min(e.p0.x, e.p1.x, e.p2.x, e.p3.x), x1 = Math.max(e.p0.x, e.p1.x, e.p2.x, e.p3.x);
      const y0 = Math.min(e.p0.y, e.p3.y), y1 = Math.max(e.p0.y, e.p3.y);
      if (x1 < seen.x0 || x0 > seen.x1 || y1 < seen.y0 || y0 > seen.y1) continue;
      drawEdge(ctx, pal, layout, e, hovered && (e.lo === hovered || e.hi === hovered));
    }
    for (const n of layout.nodes) {
      if (n.x + n.w < seen.x0 || n.x > seen.x1 || n.y + n.h < seen.y0 || n.y > seen.y1) continue;
      drawNode(ctx, pal, n, full, n.name === hovered);
    }
    // Labels last, so no curve runs through them; too small to read, they are left out.
    if (full) {
      for (const e of layout.edges) {
        if (!(e.label || e.note)) continue;
        if (e.labelAt.x < seen.x0 - M.maxColumnGap / 2 || e.labelAt.x > seen.x1 + M.maxColumnGap / 2 || e.labelAt.y < seen.y0 - 20 || e.labelAt.y > seen.y1 + 20) continue;
        drawLabel(ctx, pal, e);
      }
    }
    ctx.restore();
    if (!full) { ctx.textBaseline = "middle"; drawOverviewNames(ctx, pal, layout, view, width, height); }
  }

  MM.render = { draw, measure, PALETTES, FONT };
})(typeof window !== "undefined" ? (window.MM = window.MM || {}) : (globalThis.MM = globalThis.MM || {}));
