# Layered — Mindmap Mac App

A macOS menu bar app that turns pasted text or a dropped recording into a living mind map, built by a local Ollama model using the text mind-map notation. `SPEC.md` is the source of truth; `docs/notation-original.md` is the notation contract.

```
Harness/   pure Swift package, no UI: notation, gate, evidence, model layer, storage, history, layout, export
App/       the SwiftUI menu bar app, a thin projection of Harness.MapState
docs/      the notation
```

## Build and test

Harness (Linux or macOS, Swift 6.1):

```bash
cd Harness && swift build && swift test
```

App (macOS 14, Xcode 15 or newer):

```bash
cd App && make app        # builds Mindmap.app into App/build/
open build/Mindmap.app
```

Or open `App/Package.swift` in Xcode for previews and snapshot tests. The app runs with no folder and no model: the menu bar menu offers three demo maps (tiny, typical, large) backed by recorded model responses.

## Where things live

| Behaviour | Harness |
| --- | --- |
| Parse, compile, canonical form, edits, outline | `Notation/` |
| Gate (six checks), name canonicaliser, prompts, grammar, Ollama client, runner | `Model/` |
| `MapState` + `Action` reducer, undo/redo, Optimize, Dedupe, Verify, coverage, proof | `State/` |
| Folder storage, context document, submit modes, persistence | `Storage/` |
| Layout, icons, exports, demo fixtures | `Canvas/` |

See `Harness/README.md` for the conventions the harness fixes where the spec was open or did not survive contact with the grammar.
