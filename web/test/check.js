// Checks the web map with Node alone (no packages): node test/check.js
//
//   · every example compiles; notation errors name their line;
//   · Fill the view and Arrange to fit, frame by frame (four steps a frame, as the page runs
//     them), never make a link the spread keeps clear cross another or run through a node,
//     checked from the drawn curves by test/clashes.js, which shares none of the spread's code
//     but the segment test;
//   · both are the same every time, and Arrange to fit fills the view at least as well.
"use strict";
const path = require("path");
for (const f of ["js/notation.js", "js/layout.js", "js/spread.js", "js/arrange.js", "js/examples.js", "test/clashes.js"]) require(path.join(__dirname, "..", f));
const assert = require("assert");
let failures = 0;
function test(name, body) {
  const start = Date.now();
  try { body(); console.log(`ok   ${name} (${((Date.now() - start) / 1000).toFixed(1)} s)`); }
  catch (e) { failures++; console.log(`FAIL ${name}\n     ${e.message.split("\n").join("\n     ")}`); }
}

test("notation errors name their line", () => {
  for (const [text, line, words] of [
    ["| a - b", 1, "needs a target"], ["| a\n| b -", 2, "needs a label"], ["| a @", 1, "needs note text"],
    ["| a = b = c", 1, "nothing may follow"], ["|  | b", 1, "needs a name"],
  ]) {
    assert.throws(() => MM.notation.compile(text), (e) => e.line === line && e.detail.includes(words), text);
  }
  const undirected = MM.notation.compile("| a - x - | b").edge("a", "b");
  assert.ok(!undirected.forward && !undirected.backward && undirected.labels[0] === "x", "`- x - |`: a labelled undirected link");
  const g = MM.notation.compile("| ana - reviews | paper @date 2026-11-03\n| ana - knows - | sam\n| paper = thesis\n| sam =");
  assert.deepStrictEqual([...g.nodes.keys()].sort(), ["ana", "thesis"]);
  const e = g.edge("ana", "thesis");
  assert.ok(e.forward && e.labels[0] === "reviews");
  assert.deepStrictEqual(g.node("thesis").notes, ["date 2026-11-03"]);
});

for (const ex of MM.examples) {
  const graph = MM.notation.compile(ex.text);
  const layout = MM.layout.compute(MM.layout.unpinned(graph));
  const frames = ex.id === "large" ? 40 : Infinity; // the large map: its first 40 frames
  for (const [w, h] of [[1200, 700], [700, 1100]]) {
    for (const mode of ["fill", "arrange"]) {
      test(`${ex.id} ${w}×${h} ${mode === "fill" ? "Fill the view" : "Arrange to fit"} never tangles`, () => {
        const start = mode === "arrange" ? MM.arrange.arranged(layout, w, h, 24) : layout;
        const spread = new MM.Spread(start, w, h, 24);
        const kept = new Set(), ids = start.edges.map((e) => e.id);
        spread.kept.forEach((k, i) => { if (k) kept.add(ids[i]); });
        for (const e of start.edges) if (e.tree) assert.ok(kept.has(e.id), `tree link ${e.id} is kept clear`);
        const before = MM.check.clashes(start.placing(spread.centers), kept);
        for (let frame = 0; !spread.finished && frame < frames; frame++) {
          spread.run(4);
          const now = [...MM.check.clashes(start.placing(spread.centers), kept)].filter((c) => !before.has(c));
          assert.deepStrictEqual(now, [], `frame ${frame + 1}, step ${spread.steps}`);
        }
        if (mode === "arrange") {
          const tangles = MM.Spread.tangles(start).size, plain = MM.Spread.tangles(layout.placing(layout.centers())).size;
          assert.ok(tangles <= plain, `the arrangement crosses no more than the map as drawn (${tangles} vs ${plain})`);
        }
      });
    }
  }
}

test("the same every time, and Arrange to fit fills at least as well", () => {
  for (const id of ["hub", "forest", "typical", "stress-test"]) {
    const layout = MM.layout.compute(MM.layout.unpinned(MM.notation.compile(MM.examples.find((x) => x.id === id).text)));
    const a = MM.arrange.arranged(layout, 1200, 700), b = MM.arrange.arranged(layout, 1200, 700);
    assert.ok(a.sameAs(b), `${id}: arranged twice the same`);
    const plain = new MM.Spread(layout, 1200, 700, 24), shaped = new MM.Spread(a, 1200, 700, 24);
    plain.run(); shaped.run();
    assert.ok(shaped.zoom >= plain.zoom * 0.95, `${id}: ×${(shaped.zoom / plain.zoom).toFixed(2)}`);
    if (id === "hub") assert.ok(shaped.zoom > plain.zoom * 1.2, `the hub rings round its root: ×${(shaped.zoom / plain.zoom).toFixed(2)}`);
  }
});

console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
