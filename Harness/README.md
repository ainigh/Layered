# Harness

Milestone 1 of `SPEC.md`: the whole behaviour of the app as a pure Swift package with no UI import.

```
swift build      # zero warnings
swift test       # 36 tests, under a second
```

| Module | What it does | Spec section |
| --- | --- | --- |
| `Notation/Parser` | Parses lines into `Line` values; accepts everything the GBNF produces and rejects the documented errors with a line number and an actionable message. `Parser.Options.strict` turns scopes off, as the app requires. | notation §1–3, §8 |
| `Notation/Graph` | `Graph.apply(line)` compiles in log order: edges merge by unordered pair, `old = new` renames and merges, `old =` deletes, scopes enter/merge/delete. Also the outline layer: `#` headings and comments attached to the statement before them. | notation §4–5; SPEC “Notation extensions” |
| `Notation/Canonical` | Lossless canonical form, grouped by scope and sorted; `Render` writes statements back as the GBNF would. | notation §4 “Canonical form” |
| `Model/Evidence` | Append-only `EvidenceStore` of `{text, s, sentence, t0?, t1?}` with JSONL round-trip and the sentence splitter that numbers submitted texts. | SPEC “Proof”, “Storage” |
| `Model/Canonicaliser` | Name normal form (lowercase, article-free, singular), resolution against existing names (exact, variant, edit distance ≤ 2), and the cheap duplicate pass. | SPEC “Name stability” |
| `Model/Gate` | The six checks before append: parse, names, proof, duplicates, provenance, budget. Returns the lines to append, the over-budget suggestions, and a `GateEvent` for every change or drop, so nothing is silently altered. | SPEC “Checks before append” |
| `State/MapState` | `MapState` + `Action` → `MapState` via `reduce`. User actions compile to notation (`old = new`, `name =`, `@pos`, `@src user`, comment after statement); model output goes through the gate. The log is append-only by construction: it has no setter and only `appendTurn` adds to it. | SPEC “Development approach”, “Editing, history” |

## Conventions the harness fixes

These are decisions the spec left open or that did not survive contact with the grammar. Each is a one-line change if you disagree.

- **Provenance of an edge line.** `| dog - chases | cat @src guess` puts the note on `cat` by the grammar. The gate moves `@src` and `@text` into the edge (`| dog - chases @src guess | cat`) and declares each new node on its own line with the same provenance, so every node and edge carries its own `@src`.
- **Proof rule.** A `text` line is supported by a sentence that names every node the line *adds*; a line between existing nodes needs the sentence to name at least one of them. Otherwise the gate searches the text, then downgrades to `guess`.
- **`@pos` with negative coordinates.** `@pos 120 -340` cannot be written: a space followed by `-` is an active symbol. The harness writes `@pos 120,-340` (`Position`), and `@pos auto` releases a pin.
- **Single-valued notes.** `src`, `kind`, `icon` and `pos` replace their earlier value in place; other note kinds stay ordered sets as in the base notation.
- **Model deletes.** `| name =` from the model is dropped: deleting is a user action. Merges (`old = new`) are kept.
- **Model-written `@src user`** becomes `guess`: only the user confirms.
- **Cross-scope edges in the canonical form** are listed under the later of their two scopes, so both exist when the file is read back.
- **`@turn` headers** are comments in the log but are not part of the canonical form.
