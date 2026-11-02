// The page: the notation on the left, the map on the right, and the bar in its corner with
// zoom, fit, Fill the view and Arrange to fit. Both buttons work as the app's do: the map
// arranged afresh (shaped to the view, for Arrange to fit), shown for a moment, then its
// nodes slide into the room around them while the view refits, never crossing a link.
(function (MM) {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const canvas = $("map"), ctx = canvas.getContext("2d");
  const source = $("source"), problem = $("problem"), example = $("example");
  const FIT_PAD = 8, MIN_ZOOM = 0.1, MAX_ZOOM = 3, ZOOM_STEP = 1.4, GLIDE = 240, SHOW_START = 450;

  const state = {
    graph: null,
    layout: null,       // what is on screen
    view: { x: 0, y: 0, k: 1 },
    size: { w: 0, h: 0 },
    hovered: null,
    glide: null,        // { from, to, start }
    run: null,          // a fill under way: { mode, spread, start, phase, began, from }
    undo: [],
    results: {},        // mode → { zoom, from, seconds, steps } for this map and view
    spacing: 24,
    touched: false,     // the user moved or zoomed the map since it was last fitted
  };
  const dark = window.matchMedia("(prefers-color-scheme: dark)");
  const palette = () => MM.render.PALETTES[dark.matches ? "dark" : "light"];

  // MARK: Map and notation

  function fresh() { return MM.layout.compute(MM.layout.unpinned(state.graph), MM.render.measure); }

  function load(text, { refit = true } = {}) {
    try {
      const graph = MM.notation.compile(text);
      problem.hidden = true;
      stop(false);
      state.graph = graph;
      state.layout = MM.layout.compute(graph, MM.render.measure);
      state.undo = [];
      state.results = {};
      updateCounts();
      showResults();
      if (refit || !state.touched) fit(state.layout, false);
      setStatus("");
      draw();
    } catch (err) {
      if (!(err instanceof MM.notation.NotationError)) throw err;
      problem.hidden = false;
      problem.textContent = `Line ${err.line}: ${err.detail}`;
    }
    updateButtons();
  }

  function updateCounts() {
    const g = state.graph;
    $("counts").textContent = g ? `${g.nodes.size} nodes · ${g.edges.size} links` : "";
  }

  // MARK: View

  function targetFit(layout) {
    const w = Math.max(1, layout.width), h = Math.max(1, layout.height);
    const k = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, Math.min((state.size.w - 2 * FIT_PAD) / w, (state.size.h - 2 * FIT_PAD) / h)));
    return { k, x: state.size.w / 2 - (layout.minX + w / 2) * k, y: state.size.h / 2 - (layout.minY + h / 2) * k };
  }

  function fit(layout, animate) {
    if (!layout || !state.size.w) return;
    state.touched = false;
    const to = targetFit(layout);
    if (animate) state.glide = { from: { ...state.view }, to, start: performance.now() };
    else { state.glide = null; state.view = to; }
    draw();
  }

  function zoomBy(factor, at) {
    const p = at || { x: state.size.w / 2, y: state.size.h / 2 };
    const v = state.view, k = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, v.k * factor));
    state.view = { k, x: p.x - (p.x - v.x) * (k / v.k), y: p.y - (p.y - v.y) * (k / v.k) };
    state.glide = null;
    state.touched = true;
    draw();
  }

  // MARK: Fill the view, and Arrange to fit

  // Starts the fill (`mode` "fill" or "arrange"); pressed again while it runs, it stops there.
  function fill(mode, { restart = false } = {}) {
    if (!state.graph || state.layout.nodes.length < 2) { fit(state.layout, true); return; }
    if (state.run) {
      const same = state.run.mode === mode;
      stop(true);
      if (same && !restart) return;
    }
    const before = state.layout;
    const viewW = state.size.w - 2 * FIT_PAD, viewH = state.size.h - 2 * FIT_PAD, gap = state.spacing;
    const plain = fresh();
    setStatus(mode === "arrange" ? "Arranging to fit…" : "Filling the view…");
    state.run = { mode, phase: "arranging", from: before, began: performance.now(), plainZoom: new MM.Spread(plain, viewW, viewH, gap).zoom };
    updateButtons();
    // Let the status paint before the (synchronous) arranging.
    setTimeout(() => {
      const run = state.run;
      if (!run || run.mode !== mode || run.phase !== "arranging") return;
      const start = mode === "arrange" ? MM.arrange.arranged(plain, viewW, viewH, gap) : plain;
      run.start = start;
      run.spread = new MM.Spread(start, viewW, viewH, gap, MAX_ZOOM);
      run.phase = "showing";
      run.shownAt = performance.now();
      state.layout = start;
      fit(start, true);
      loop();
    }, 30);
  }

  // Ends a fill: with `keep`, the map stays where it got to (one step back with undo).
  function stop(keep) {
    const run = state.run;
    if (!run) return;
    state.run = null;
    if (keep && run.spread) {
      state.undo.push(run.from);
      const seconds = (performance.now() - run.began) / 1000;
      state.results[run.mode] = { zoom: run.spread.zoom / run.plainZoom, steps: run.spread.steps, seconds, finished: run.spread.finished };
      showResults();
      setStatus(`${run.mode === "arrange" ? "Arranged to fit" : "Filled the view"}: ${run.spread.steps} steps, ${seconds.toFixed(1)} s`);
    } else {
      // Stopped before it began to move (or let go): the map as it was.
      state.layout = run.from;
      setStatus("");
    }
    updateButtons();
    draw();
  }

  function loop() {
    const run = state.run;
    if (!run || !run.spread) return;
    const now = performance.now();
    if (run.phase === "showing") {
      if (now - run.shownAt < SHOW_START) { requestAnimationFrame(loop); return; }
      run.phase = "spreading";
    }
    // As many steps as fit in a frame, at least one.
    const until = now + 14;
    do { run.spread.step(); } while (!run.spread.finished && performance.now() < until);
    state.layout = run.start.placing(run.spread.centers);
    fit(state.layout, false);
    if (run.spread.finished) stop(true); else requestAnimationFrame(loop);
  }

  function undo() {
    if (state.run) { stop(false); return; }
    const last = state.undo.pop();
    if (!last) return;
    state.layout = last;
    fit(last, true);
    setStatus("Put back");
    updateButtons();
  }

  // MARK: Readouts

  function setStatus(text) { $("status").textContent = text; }

  function showResults() {
    const box = $("results"), r = state.results;
    const rows = [["fill", "Fill the view"], ["arrange", "Arrange to fit"]].filter(([m]) => r[m]);
    box.hidden = rows.length === 0;
    if (!rows.length) return;
    const best = rows.length === 2 ? (r.fill.zoom >= r.arrange.zoom ? "fill" : "arrange") : null;
    box.innerHTML = "<table>" + rows.map(([m, title]) =>
      `<tr class="${m === best ? "best" : ""}"><th>${title}</th><td>×${r[m].zoom.toFixed(2)}</td><td>${r[m].seconds.toFixed(1)} s</td></tr>`).join("") + "</table>" +
      `<div class="note">Zoom against the plain arrangement fitted to this view${rows.length < 2 ? "; try the other button to compare" : ""}.</div>`;
  }

  function updateButtons() {
    $("fill").classList.toggle("pressed", !!state.run && state.run.mode === "fill");
    $("arrange").classList.toggle("pressed", !!state.run && state.run.mode === "arrange");
    $("undo").disabled = !state.run && state.undo.length === 0;
  }

  // MARK: Drawing

  function resize() {
    const r = canvas.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    const was = { ...state.size };
    state.size = { w: r.width, h: r.height };
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (state.layout && (!state.touched || !was.w)) fit(state.layout, false); else draw();
    if (was.w && (was.w !== state.size.w || was.h !== state.size.h)) { state.results = {}; showResults(); }
  }

  let queued = false;
  function draw() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      if (state.glide) {
        const t = Math.min(1, (performance.now() - state.glide.start) / GLIDE), e = 1 - Math.pow(1 - t, 3);
        const { from, to } = state.glide;
        state.view = { k: from.k + (to.k - from.k) * e, x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e };
        if (t >= 1) state.glide = null; else draw();
      }
      MM.render.draw(ctx, state.layout, state.view, state.size.w, state.size.h, { palette: palette(), hovered: state.hovered });
    });
  }

  // MARK: Pointer and keys

  function mapPoint(e) {
    const r = canvas.getBoundingClientRect();
    return { sx: e.clientX - r.left, sy: e.clientY - r.top, x: (e.clientX - r.left - state.view.x) / state.view.k, y: (e.clientY - r.top - state.view.y) / state.view.k };
  }
  function hit(p) {
    const nodes = state.layout ? state.layout.nodes : [];
    for (let i = nodes.length - 1; i >= 0; i--) { const n = nodes[i]; if (p.x >= n.x && p.x <= n.x + n.w && p.y >= n.y && p.y <= n.y + n.h) return n; }
    return null;
  }

  let drag = null;
  canvas.addEventListener("pointerdown", (e) => {
    drag = { x: e.clientX, y: e.clientY, view: { ...state.view } };
    canvas.setPointerCapture(e.pointerId);
    canvas.classList.add("panning");
    hideCard();
  });
  canvas.addEventListener("pointermove", (e) => {
    if (drag) {
      state.view = { ...drag.view, x: drag.view.x + e.clientX - drag.x, y: drag.view.y + e.clientY - drag.y };
      state.glide = null;
      state.touched = true;
      draw();
      return;
    }
    const p = mapPoint(e), n = hit(p);
    const name = n ? n.name : null;
    canvas.classList.toggle("over-node", !!n);
    if (name !== state.hovered) { state.hovered = name; draw(); }
    if (n) showCard(n, p); else hideCard();
  });
  const endDrag = () => { drag = null; canvas.classList.remove("panning"); };
  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);
  canvas.addEventListener("pointerleave", () => { if (state.hovered) { state.hovered = null; draw(); } hideCard(); });
  // Scrolling moves the map; pinching (or ⌘/ctrl and scrolling) zooms about the pointer.
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    hideCard();
    const p = mapPoint(e);
    if (e.ctrlKey || e.metaKey) zoomBy(Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002)), { x: p.sx, y: p.sy });
    else {
      state.view = { ...state.view, x: state.view.x - e.deltaX, y: state.view.y - e.deltaY };
      state.glide = null;
      state.touched = true;
      draw();
    }
  }, { passive: false });

  function showCard(n, p) {
    const card = $("hover-card");
    if (!n.cut && !n.allNotes.length && !n.kind && !n.src) { hideCard(); return; }
    const meta = [n.kind, n.src && n.src !== "text" ? n.src : null].filter(Boolean).join(" · ");
    card.innerHTML = `<div class="name"></div>${meta ? '<div class="meta"></div>' : ""}${n.allNotes.length ? "<ul></ul>" : ""}`;
    card.querySelector(".name").textContent = n.name;
    if (meta) card.querySelector(".meta").textContent = meta;
    const ul = card.querySelector("ul");
    for (const note of n.allNotes) { const li = document.createElement("li"); li.textContent = note; ul.appendChild(li); }
    card.hidden = false;
    const x = Math.min(p.sx + 14, state.size.w - card.offsetWidth - 8), y = Math.min(p.sy + 16, state.size.h - card.offsetHeight - 8);
    card.style.left = `${Math.max(8, x)}px`;
    card.style.top = `${Math.max(8, y)}px`;
  }
  function hideCard() { $("hover-card").hidden = true; }

  document.addEventListener("keydown", (e) => {
    if (e.target === source || e.target === example) return;
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") { e.preventDefault(); undo(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    switch (e.key) {
      case "f": case "F": fill("fill"); break;
      case "a": case "A": fill("arrange"); break;
      case "0": fit(state.layout, true); break;
      case "+": case "=": zoomBy(ZOOM_STEP); break;
      case "-": case "_": zoomBy(1 / ZOOM_STEP); break;
      case "n": case "N": toggleDrawer(); break;
      case "Escape": if (state.run) stop(true); break;
      default: return;
    }
    e.preventDefault();
  });

  // MARK: Controls

  $("zoom-in").onclick = () => zoomBy(ZOOM_STEP);
  $("zoom-out").onclick = () => zoomBy(1 / ZOOM_STEP);
  $("fit").onclick = () => fit(state.layout, true);
  $("fill").onclick = () => fill("fill");
  $("arrange").onclick = () => fill("arrange");
  $("undo").onclick = undo;

  const spacing = $("spacing");
  spacing.addEventListener("input", () => { $("spacing-value").textContent = spacing.value; });
  // Letting go fills the view again with the new spacing, the same way as last time.
  spacing.addEventListener("change", () => {
    state.spacing = Number(spacing.value);
    state.results = {};
    showResults();
    const last = state.run ? state.run.mode : state.lastMode;
    if (last) fill(last, { restart: true });
  });
  // Remember which button was used last, for the spacing slider.
  for (const m of ["fill", "arrange"]) $(m).addEventListener("click", () => { state.lastMode = m; });
  document.addEventListener("keydown", (e) => { if (e.target !== source && !e.metaKey && !e.ctrlKey) { if (/^[fF]$/.test(e.key)) state.lastMode = "fill"; if (/^[aA]$/.test(e.key)) state.lastMode = "arrange"; } });

  function toggleDrawer() {
    $("app").classList.toggle("drawer-closed");
    requestAnimationFrame(resize);
  }
  $("toggle-drawer").onclick = toggleDrawer;

  for (const ex of MM.examples) {
    const o = document.createElement("option");
    o.value = ex.id; o.textContent = ex.title;
    example.appendChild(o);
  }
  example.onchange = () => {
    const ex = MM.examples.find((x) => x.id === example.value);
    source.value = ex.text;
    state.lastMode = null;
    load(ex.text);
    try { history.replaceState(null, "", "#" + ex.id); } catch (_) { /* file:// */ }
  };

  let typing = null;
  source.addEventListener("input", () => {
    clearTimeout(typing);
    typing = setTimeout(() => load(source.value, { refit: false }), 350);
  });

  dark.addEventListener("change", draw);
  new ResizeObserver(resize).observe(canvas);

  // Start on the example in the address (#large), or the stress test.
  const first = MM.examples.find((x) => x.id === location.hash.slice(1)) || MM.examples[0];
  example.value = first.id;
  source.value = first.text;
  resize();
  load(first.text);
  updateButtons();

  // For tests and the console.
  MM.app = { state, fill, stop, undo, load, fit };
})(window.MM);
