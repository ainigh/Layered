// Drives the page in a real browser (Playwright): node test/browser.js [screenshot folder]
// Each example: both buttons run to the end with no page errors and nothing new tangled on
// screen; a notation error is reported with its line; undo puts the map back.
"use strict";
const path = require("path");
const { chromium } = require("playwright");
const shots = process.argv[2];
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1400, height: 860 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  await page.goto("file://" + path.join(__dirname, "..", "index.html"));
  await page.addScriptTag({ path: path.join(__dirname, "clashes.js") });
  let failed = 0;
  const ids = await page.evaluate(() => MM.examples.map((x) => x.id));
  const settle = () => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300)))));
  for (const id of ids) {
    await page.selectOption("#example", id);
    await settle();
    const drawn = await page.evaluate(() => MM.app.state.layout.nodes.map((n) => [n.x, n.y]));
    if (shots) await page.screenshot({ path: path.join(shots, `${id}-0.png`) });
    for (const [key, mode] of [["f", "fill"], ["a", "arrange"]]) {
      const result = await page.evaluate(async ([k, m]) => {
        const st = MM.app.state, plainEdges = st.layout.edges;
        document.dispatchEvent(new KeyboardEvent("keydown", { key: k }));
        const began = performance.now();
        while (!st.run || !st.run.spread) { await new Promise((r) => setTimeout(r, 20)); if (!st.run && st.results[m]) break; }
        const run = st.run, start = run && run.start;
        const kept = new Set();
        if (run) run.spread.kept.forEach((on, i) => { if (on) kept.add(start.edges[i].id); });
        const before = run ? MM.check.clashes(start.placing(start.centers()), kept) : new Set();
        let worst = [];
        while (st.run) {
          await new Promise((r) => setTimeout(r, 120));
          if (!st.run && !st.layout) break;
          const now = [...MM.check.clashes(st.layout, kept)].filter((c) => !before.has(c));
          if (now.length > worst.length) worst = now;
        }
        const after = [...MM.check.clashes(st.layout, kept)].filter((c) => !before.has(c));
        void plainEdges;
        return { seconds: (performance.now() - began) / 1000, gain: st.results[m] && st.results[m].zoom, tangled: worst.concat(after) };
      }, [key, mode]);
      const ok = result.tangled.length === 0 && result.gain >= 1;
      if (!ok) failed++;
      console.log(`${ok ? "ok  " : "FAIL"} ${id.padEnd(12)} ${mode.padEnd(8)} ×${(result.gain || 0).toFixed(2)} in ${result.seconds.toFixed(1)} s${result.tangled.length ? " tangled: " + result.tangled.slice(0, 3).join("; ") : ""}`);
      await settle();
      if (shots) await page.screenshot({ path: path.join(shots, `${id}-${mode}.png`) });
    }
    // Undo twice: back to the map as drawn.
    await page.keyboard.press("Control+z");
    await page.keyboard.press("Control+z");
    await settle();
    const back = await page.evaluate((was) => MM.app.state.undo.length === 0 &&
      MM.app.state.layout.nodes.every((n, i) => n.x === was[i][0] && n.y === was[i][1]), drawn);
    if (!back) { failed++; console.log(`FAIL ${id} undo did not put the map back`); }
  }
  // A notation error is shown with its line, and the map stays as it was.
  await page.selectOption("#example", "typical");
  await page.fill("#source", "| ana - reviews | paper\n| sam - writes");
  await page.waitForTimeout(600);
  const problem = await page.textContent("#problem");
  const visible = await page.isVisible("#problem");
  const ok = visible && problem.startsWith("Line 2:");
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} notation error shown: ${problem}`);
  await page.fill("#source", "| ana - reviews | paper\n| sam - writes | paper");
  await page.waitForTimeout(600);
  const fixed = await page.evaluate(() => MM.app.state.graph.nodes.size === 3 && document.getElementById("problem").hidden);
  if (!fixed) failed++;
  console.log(`${fixed ? "ok  " : "FAIL"} fixed notation redraws the map`);
  if (errors.length) { failed++; console.log("FAIL page errors:\n  " + errors.join("\n  ")); }
  await browser.close();
  console.log(failed ? `\n${failed} failed` : "\nall passed");
  process.exit(failed ? 1 : 0);
})();
