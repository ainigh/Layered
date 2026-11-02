# Layered map, on the web

The app's mind map in a web page: write the notation on the left and the map is drawn on the right the way the app draws it, with the app's two auto-arrange buttons. No build step and no server: open `index.html` in a browser (it works straight from disk).

```
index.html        the page
style.css
js/notation.js    the notation: lines in, a graph out           (Harness/Notation)
js/layout.js      left-to-right trees, link routing, placing     (Harness/Canvas/MapLayout.swift)
js/spread.js      Fill the view, never crossing a link          (Harness/Canvas/Spread.swift)
js/arrange.js     Arrange to fit                                 (Harness/Canvas/Arrange.swift)
js/render.js      drawing on a canvas, light and dark            (App/…/Canvas/CanvasView.swift)
js/app.js         the page: editor, pan and zoom, the buttons
js/examples.js    the example maps, bundled from examples/*.mm
examples/         the example maps as notation
test/             checks (below)
tools/            bundle-examples.js
```

## On the map

- **Drag** or **scroll** moves the map; **pinch** (or ⌘/ctrl and scroll) zooms about the pointer. Hovering a node shows all its notes.
- The bar in the bottom right: zoom in and out, **fit** (`0`), **Fill the view** (the wand, `F`) and **Arrange to fit** (`A`) under it, and **undo** (`⌘Z`). The slider above sets the **spacing**, the least room between two nodes; letting go of it runs the last button again.
  - **Fill the view** lays the map out afresh, shows that for a moment, then lets its nodes slide a few points at a time into the room around them while the view refits, until zooming in gains nothing more. No frame ever has two links crossing, a link through a node or a node on a link (a dashed cross-link that already crosses things in the fresh arrangement is left to).
  - **Arrange to fit** does the same from an arrangement shaped to the window: a root's branches split between its right and its left, a root's single branches ringed round it, separate trees side by side. It tries each, checks it link by link, gives it a short trial spread, and spreads from the one that gets furthest (in a near tie, the one with fewer links crossing).
  - Pressing a button while it runs stops it there. The card in the top right compares the two buttons on this map and window: how far each zoomed in, against the plain arrangement fitted.
- **N** shows or hides the notation. The map redraws as you type; a mistake is shown with its line, and the map stays as it was until it is fixed.

## The notation, briefly

See [`docs/notation-original.md`](../docs/notation-original.md) for all of it.

```
| ana - reviews | paper            two nodes, a labelled link from ana to paper
| ana - knows - | sam              `- |` makes a link undirected
| a | b | c                        a chain
| paper @date 2026-11-03           a note on a node (on a link: before its `|`)
| ana @kind person                 its icon: person, place, thing, action, event, idea
| hint @src world                  a card for the model's extras: world, guess, advice
| paper = thesis                   rename (or merge); `| paper =` deletes
# heading                          any line that doesn't start with `|` is a comment
```

## The examples

- **Stress test** (60 nodes): a hub with many single branches, deep branches with long names and notes, every kind of node, the three kinds of card, labelled, two-way and undirected links, cross-links between branches, separate trees and nodes linked to nothing.
- **One hub, 14 branches**: where Arrange to fit's ring shows (about ×2.7 against ×1.8 for Fill the view in a wide window).
- **Five small trees**: trees side by side.
- **The app's demos**: tiny, typical, and large (316 nodes, 515 links, mostly cross-links; Fill the view takes 10–20 s on it in a browser, Arrange to fit about half that).

To change them, edit `examples/*.mm` and run `node tools/bundle-examples.js`.

## Checks

```bash
node web/test/check.js
```

With Node alone: notation errors name their line; on every example, in a wide and a tall window, both buttons are run frame by frame and no link the spread keeps clear comes to cross another or run through a node, checked from the drawn curves; arranging is the same every time and fills at least as well. CI runs it on every push.

```bash
node web/test/browser.js [folder for screenshots]
```

Drives the page in a browser (needs Playwright): every example with both buttons, a notation error, undo.

The JavaScript is a step-for-step port of the Swift. On the tiny, typical and stress-test maps and a 14-branch hub, its layout, its spreads and its arrangements came out identical to the app's, node for node. On the large demo the spreads part after about 50 steps: a coordinate landing exactly on a whole number is cut one way or the other depending on the last bit of the platform's maths library, and the spread is chaotic enough that one point grows from there.
