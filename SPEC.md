# Mindmap Mac App — High-Level Spec

Oct 28, 2026 · @nigh

## Overview

The app lives in the macOS menu bar and turns pasted text, or a dropped audio file, into a living mind map, drawn on an infinite canvas and built by a local Ollama model using the text mind-map notation. The map is the memory: text can change or disappear, and the graph keeps what it learned. Everything the model writes is an append-only log on the user’s disk, so every state is replayable.

Core promises:

- Paste text or drop a recording, answer a few clarifying questions, and see people, places, things and actions as nodes.
- The same text gives the same node names, whichever model or run produced them.
- Clicking a node asks the model for more; what it adds from the text, from world knowledge, or as a guess is visibly different.
- The user is always in charge: delete, rename, comment, undo, redo, and everything lives in a folder they picked.
- The notation is the only contract between the UI and the model, so the model prompt and the file format are the same thing.

## Core concepts

**Map.** One map = one folder on disk = one notation log (`map.mm`). A map uses only the root scope: a name is global, so the same name anywhere in the map is the same node. Grouping comes from outline headings, not scopes.

**Text window.** The Context panel holds the current text: pasted, typed, transcribed from audio, or added during clarification. It is not the source of truth; it is the latest input. Edits save to disk as you type; Submit is the only thing that sends them to the model. Submit has two modes. All at once: the harness diffs against the last submitted version and sends the changed paragraphs with the node list. One sentence at a time: the harness walks the text sentence by sentence, and each call shows the model only the latest complete map and that one sentence, so every fact is read against everything already known. New facts append; nothing is removed just because its sentence vanished. Removal is a user action (delete, or “forget everything from text #3”).

**Provenance.** Every node and edge carries a provenance note written by the model and enforced by the harness:

| Kind | Meaning | Rendering |
| --- | --- | --- |
| `src text` | stated in the pasted text; always has proof sentences | solid border, full colour |
| `src world` | model’s general knowledge, not in the text | dashed border, muted fill, globe badge |
| `src guess` | inference the model is not sure of | dotted border, question-mark badge, lower opacity |
| `src advice` | a recommendation, next step or warning the model adds | double border, lightbulb badge, warm tint |
| `src user` | typed or edited by the user | solid, with a pencil badge |

Only `text` nodes come from the text; the other four are *extra* nodes and are drawn so they can never be mistaken for it. The set is closed; the harness rewrites any other kind to `guess`.

Provenance is a note, so it is plain notation and survives export. A `world` or `guess` node that the user confirms becomes `src user`.

**Proof.** Every `src text` node and edge carries `@text` notes pointing at sentence ids (`@text 3 s12` = text 3, sentence 12). Sentences live in an append-only evidence store in the folder; editing or clearing the text window never touches it. Clicking a node shows the exact sentences it came from; selecting several nodes shows the union, each sentence once, with chips for the nodes it supports. A node with no proof is by definition not a `text` node.

**Coverage.** “Check coverage” asks the model to read the text against the current map and list facts the text states that the map lacks, each as proposed lines with the sentence they come from; the user applies them one by one. Nodes with no sentence support and sentences with no node are shown as two counts on the status bar.

**Audio.** A dropped audio file (m4a, mp3, wav, or a voice memo) is transcribed on the machine with whisper.cpp and lands in the Context panel as a transcript with timestamps. Speaker diarization runs after transcription, so each sentence carries a speaker label (Speaker 1, Speaker 2) that clarification can turn into a name. The audio file is kept in the folder, and each transcript sentence keeps its start time, so proof for a node can also play the few seconds of audio it came from.

**Clarification.** When the user presses “Ask me”, and only then, the model reads the context and asks questions that close gaps: who is speaking in a transcript, who “he” is, where and when this happened, what an abbreviation means. The user answers in the Clarify panel; each answer is appended to the context as a labelled paragraph (`[clarification] Speaker 1 is Ana`). The user can also add context by hand the same way: who said what, the setting, anything the text assumes. Nothing in the context is overwritten; the context is itself an append-only document, and extraction reads all of it.

**Expansion.** Clicking a node runs an expansion prompt: the model sees the text, the node’s one-hop neighbourhood, and the node list, and appends lines about that node, including links between two existing nodes when the text supports them. Its answers are tagged `world` or `guess` unless they quote the text.

**Outline and comments.** Comment lines (no leading `|`) are the outline layer. A comment immediately after a statement attaches to that statement’s node or edge in the UI; a comment starting with `#` is a section heading that groups the statements under it until the next heading. See Notation extensions.

**History.** The log is append-only. Undo appends an inverse line rather than deleting; the UI shows a timeline the user can scrub. Compaction is explicit and keeps the archive.

## Notation extensions

The grammar is unchanged. Everything below is a convention on note kinds and comment lines, so any plain parser still reads the log.

**Note kinds the harness recognises**

| Kind | On | Example | Purpose |
| --- | --- | --- | --- |
| `src` | node, edge | `@src text`, `@src world`, `@src guess`, `@src advice`, `@src user` | provenance (required; harness adds `src text` if the model omits it in Extract) |
| `kind` | node | `@kind person`, `@kind place`, `@kind thing`, `@kind action`, `@kind event`, `@kind idea` | shape, colour family, icon fallback |
| `icon` | node | `@icon dog`, `@icon house` | explicit icon override; otherwise icons come from the name |
| `pos` | node | `@pos 120 -340` | canvas position after the user drags it (layout is otherwise automatic) |
| `text` | node, edge | `@text 3 s12` | proof: text id and sentence id in the evidence store; written by the harness, never by the model, one note per supporting sentence |
| `date` `todo` `ref` | node, edge | as in the base notation | passed through, shown as chips |
| `turn` | comment | `@turn 12 2026-10-28T14:02` | written by the harness before each model append |

**Outline via comments**

```
# people
| ana - reviews | paper
ana is the second author
| sam | paper
# timeline
| paper @date 2026-11-03 review by ana
```

- A comment line starting with `#` is a **heading**: statements until the next heading belong to it. Headings nest with `##`. The UI shows headings as collapsible groups and as a sidebar outline.
- A comment line directly after a statement is a **note on that statement**: it attaches to the last node of the path (or the edge, if the statement had exactly one link). It renders as a hover card and in the outline under the node.
- Any other comment is a free note in the current scope and heading.

Headings and attached comments are moved and deleted by the same edit rules as the base notation (rename affects comments equal to the old name; `old =` removes them).

**Reserved scope and names**

- `| @ _ui` is a scope the harness owns for canvas state (viewport, panel layout, collapsed headings). The model never sees it.
- Names are lowercase, singular, article-free (`dog`, not `the dogs`). The harness normalises; the prompt instructs. Names are global: the extension never writes name@scope, and the parser rejects it.

**Query blocks (`mmq`)** are used unchanged from the base notation for expansion: clicking a node runs the harness query `| node | x`, `| x | node`, `| node @x` to build the neighbourhood sent to the model.

## Model layer

**Connection.** The app talks to Ollama at `http://localhost:11434` (configurable) and can start it if it is installed and not running. Settings: model picker (from `/api/tags`), temperature (default 0), context size, and a “test connection” button. On a 64 GB M1 Max the picker shows which installed models fit in memory; a 30B-class model at 4-bit is comfortable and gives much better extraction than 3B, so the default is the largest installed model that fits with room for the OS.

**Transcription** runs in-process with whisper.cpp (Metal), model `large-v3-turbo` by default, downloaded on first use to the app’s support folder. Output is sentences with start and end times. **Diarization** then assigns a speaker label to each sentence using a local speaker-embedding model (a pyannote-style segmentation and clustering pipeline exported to Core ML, or whisper.cpp’s tinydiarize for two-speaker audio as a fallback). Labels are `Speaker 1…n`; mapping labels to names is a clarification answer, and a wrong split can be corrected in the Context panel by relabelling a sentence.

**Stateless requests.** The model keeps no conversation history. Every request is built from scratch: the prompt, the canonical mind map, the context, and the one thing the request is about (a sentence, a node, a message). Clarify sends the context and the map by default; a toggle next to “Ask me” lets the user send the context alone, which is useful when the map is large or when they want questions purely about the text. Nothing from an earlier reply is replayed; if the model needs to know what it said before, it is in the map or the context already. This keeps outputs reproducible (temperature 0 plus the same inputs gives the same lines) and makes every request independently re-runnable from the folder.

**Decoding.** Requests use Ollama’s structured output with the GBNF grammar from the notation (section 8), tightened to one label per link and two notes per path. The `name` rule is rebuilt per request as an alternation of the current node names plus one free branch. If the running model rejects grammars, fall back to post-validation (workflow steps 5–9).

**Six prompts, one notation**

| Prompt | Input | Output | Trigger |
| --- | --- | --- | --- |
| Clarify | the context, numbered by sentence, with speaker labels, plus the map by default; a toggle sends the context alone | up to 5 questions, each tied to a sentence number and a reason (unnamed speaker, pronoun, place, time, abbreviation) | “Ask me” pressed by the user; never automatic |
| Extract | map, context, and the changed paragraphs (or the one sentence) | new lines, every node with `@src text` and `@kind`; the harness attaches `@text` proof | Submit pressed |
| Expand | map, context, and the node with its one-hop canonical lines | new lines about that node (edges to or between existing nodes allowed), each `@src text`, `world`, `guess` or `advice` | node clicked (or “expand” in context menu) |
| Chat | map, context, and the one user message | prose answer in the chat panel; the user’s message is appended to the context as a new paragraph and extracted; a \`\`\`mm block in the reply is applied as `advice` or `world` lines | message sent from the chat panel |
| Dedupe | map only, with each node’s notes and degree | `old = new` lines for nodes that look like the same thing, each with a one-line reason as a comment | “Find duplicates” pressed; the user confirms each merge |
| Verify | map and context, numbered by sentence | for each sentence that states a fact the map lacks: the sentence number and the lines that would add it; and any `text` node the model cannot find in the context, flagged for review | “Check coverage” pressed; the user applies proposals one by one |

**Name stability.** The goal that two models on the same text produce the same names is met by rules, not by hoping:

1. The prompt fixes the normal form: lowercase, singular, no articles, the shortest noun phrase that is still unique in the text, a person by first name unless two share it, a place by its common name.
2. The harness canonicalises again after the model: trims, lowercases, strips leading `the/a/an`, singularises with a small rule set, and resolves near matches to existing nodes (edit distance ≤ 2, or plural/article variants).
3. Existing names are passed in the prompt and, when grammars work, in the decoder, so reuse beats invention.
4. Entity types get fixed shapes of name: an action is the base verb (`review`, not `reviewing`); an event is `noun-verb` only when the text names it.
5. The prompt ships a worked example that shows the same sentence producing the same lines twice.

**Extraction rules in the prompt** (the full prompt lives in the Prompt panel and is editable):

- Nodes are people, places, things, actions, events and ideas actually named in the text. One line per fact.
- Edges read as a short phrasal verb left to right, four words or fewer.
- Everything from the text is `@src text`; nothing else is allowed in Extract.
- In Expand and Chat, mark each line `text`, `world`, `guess` or `advice`; if unsure, `guess`. `advice` is for what the user should do, consider or avoid; it is never stated as a fact about the text.
- Never rename or delete existing nodes unless two names clearly mean one thing; then write `old = new`.
- In Extract, end each line with `@s n` naming the sentence number it came from; the harness turns it into the `@text` proof note. In sentence mode the harness does this itself.

**Submit modes.** Submitted texts get ids (`text 1`, `text 2`). In *all at once* mode paragraphs are hashed and only new or changed ones are sent. In *one sentence at a time* mode the harness splits the text, sends sentence n with the canonical map as it stands after sentence n−1, applies the lines, and continues; a progress bar shows the sentence under consideration and the user can pause. A node’s `@text` notes list every text and paragraph that supports it, so “forget text 2” removes only nodes whose sole support was text 2.

**Duplicates.** Because names are global, a near-duplicate is a real error, not a scoping choice. “Find duplicates” runs the Dedupe prompt; proposed `old = new` lines appear as a checklist, and only confirmed ones are appended. The harness also runs its own cheap pass first (plural, article, case, edit distance ≤ 2) and shows those without asking the model.

**Checks before append.** The harness gates every model line before it reaches the log, without asking the model:

1. Parse: the line must compile; a failing line is sent back once with the error, then dropped.
2. Names: canonical form, then exact or near match against existing nodes; a near match is rewritten, not added.
3. Proof: a `text` line must cite a sentence that contains the node name (or a known alias from clarification); if not, the harness searches the context for a sentence that does, else downgrades the line to `guess`.
4. Duplicates: a new edge equal to an existing one, or a note already present, is dropped.
5. Provenance: an unknown `@src` becomes `guess`; a line from Extract with any `@src` other than `text` is rejected.
6. Budget: Expand and Chat appends are capped per call; the rest are shown as “more suggestions” for the user to apply.

Everything the gate changes or drops is listed in a small “what was held back” drawer on the status bar, so the model’s raw output is never silently altered.

## Canvas and UI

The app runs as a menu bar item. Clicking the icon opens or focuses one main window with the canvas filling it; a menu on the icon lists recent maps, “New map from clipboard”, and “Transcribe audio file”. A global shortcut sends the current selection from any app into the Context panel. The window remembers its size and position; closing it keeps the app in the menu bar.

**Canvas**

- Infinite pan and zoom (wheel, pinch, drag on empty space), rendered in SVG for up to \~500 nodes and switched to Canvas 2D above that.
- Layout draws the map as GridClip does: left-to-right trees of rounded cards, roots being the nodes nothing points at (the best-connected first, larger trees above smaller ones), with a breadth-first walk hanging every other node under the first node that reaches it. Edges the trees do not use (cycles, second parents) are dashed cross-links. Each first-level branch takes its own colour for its links and outlines; roots are filled. A faint dot grid travels with the map; hovering a node shows its card and draws its links a little heavier, and dims nothing. Links are hairlines (1.25 pt in a tree, 1 pt across) and their labels are set light. The map fits the view when it opens and refits as it grows until the user moves or zooms it; a small bar in the bottom right zooms in, out, fits and **fills the view**. Fill the view fits the map, then lets its nodes slide a few points at a time toward the middle into whatever room is around them (never jumping over another node, never closer than the spacing) while the view keeps refitting, until zooming in gains nothing more; where they end up is pinned in one turn, so one undo puts the map back. A **spacing** slider beside the bar sets that least distance between nodes; letting go of it fills the view again. A dragged node gets an `@pos` note (its centre) and is pinned until “release”.
- Edge labels sit on the curve’s midpoint, on a chip of the map’s background; undirected edges have no arrowhead; two-way edges have both.
- Headings from the outline are shown in the Outline panel (on the canvas they would split each tree, since headings group nodes by kind rather than by topic).
- New lines from the model animate in and are highlighted for a few seconds so the user sees what changed.

**Node rendering**

| Property | Driven by |
| --- | --- |
| Shape | a rounded card sized to its text; `@kind` sets the glyph before the name (person, place, thing, action, event, idea) |
| Border and fill | `@src`: text solid, world dashed and muted, guess dotted and faded, advice double border with warm tint, user solid with pencil badge |
| Icon | name tokens matched against the icon set, or `@icon` |
| Size | its name and notes (names past 240 pt are cut with an ellipsis; the hover card has the whole text) |
| Notes | up to three notes under the name (`date`, `todo`, `ref`…), the kind set quieter than the value; provenance, kind, position and proof are drawn another way |

**Icons.** The icon set is a folder of SVGs with a `manifest.json` mapping keywords and synonyms to files (`dog: [dog, puppy, hound]`). Name tokens are matched after singularising; every match yields an icon. One match fills the node badge. Two or three are stacked with a 40% overlap, the first on top; more than three show the first three and a “+n”. No match falls back to the `@kind` glyph, and the Settings panel lets the user add their own SVGs to the folder.

**Interactions on a node**

- Click: select and open the Proof panel with the node’s sentences; the detail card shows notes and provenance. Shift-click or drag a box to select several; Proof shows the union.
- Double-click or “Expand”: run the Expand prompt.
- Right-click: rename, delete, confirm (world/guess/advice → user), add comment, set icon, set kind, pin/release, “show in text”.
- Drag from a node’s edge handle to another node: create an edge; type the label inline.
- Clicking a sentence in the Proof panel highlights every node it supports on the canvas.

**Panels.** The window has a pane on each side of the map; each shows one panel at a time, picked from the pane’s tab strip. A panel can move to the other pane (its menu, or right-click its tab), a pane’s inner edge drags to resize it, and both are remembered in `ui.json`. The toolbar shows and hides each pane.

| Panel | Contents |
| --- | --- |
| Context | the append-only context: pasted text, transcripts and clarifications as labelled paragraphs; saves as you type; audio drop zone; Submit with a mode switch (all at once / one sentence at a time); “Check coverage”; list of sources with “forget” and “show nodes from this source” |
| Clarify | “Ask me” button (the only way Clarify runs) with a “context only / context + map” toggle, then the model’s questions, each with the sentence it refers to and an answer box; answers append to the context; a speaker map (Speaker 1 → name) that also appends as a clarification |
| Proof | the exact sentences behind the selected node or nodes, each once, with node chips, the source they came from and a play button for transcript sentences; works even after the context is cleared |
| Chat | message input and model replies; each sent message is appended to the context as a paragraph and extracted |
| Outline | headings and attached comments as a tree; drag to reorder; click to focus on canvas; “Find duplicates” button with its confirm checklist |
| Prompt | the six prompts, editable, with “reset to default” and a diff against default |
| Settings | Ollama host and model picker, whisper model, icon folder, data folder, theme, layout options, global shortcut |
| History | timeline of turns; scrub, undo, redo, Optimize |

**Status.** A thin bar shows the current folder, the model, token use of the last request, and a spinner while the model runs; a model error shows the raw line and the parser message with a “retry” button.

## Editing, history, undo and redo

Every change, by the user or the model, is a **turn**: a comment header plus the lines appended in that turn.

```
@turn 12 2026-10-28T14:02 model expand dog
| dog - chases | cat @src guess
@turn 13 2026-10-28T14:03 user delete
| cat =
```

- User actions compile to notation too: rename → `old = new`, delete → `name =`, drag → `name @pos x y`, confirm → `name @src user`, comment → a comment line placed after the statement.
- **Undo** appends a turn that reverses the previous turn, using the canonical form from before it (the harness keeps a snapshot per turn, so an undo of a delete re-emits the node’s lines). Redo re-appends the original lines. Nothing is ever removed from the log.
- The History panel shows turns as a list; clicking one shows the canvas at that turn (read-only); “branch from here” truncates the active view and writes later turns to an archive.
- Model turns are applied automatically for Extract, Expand and Chat, with a highlight and one-click undo; Dedupe merges wait for confirmation.
- **Optimize** compresses the log: it writes the canonical form (one line per edge, one per node note, surviving comments, grouped by heading and sorted) as the new `map.mm`, moves the old log to `archive/`, and keeps snapshots so undo in the current session still works. The History panel shows the size before and after; it can also run on a schedule (every n turns) if the user turns that on.
- Edits to the text window save continuously and keep their own version history (one version per Submit), separate from the graph log.

## Storage

The user picks a folder once (standard macOS open panel; the app keeps a security-scoped bookmark so it reopens without asking). Everything is plain text plus the original audio, so the folder is readable, diffable and syncable without the app.

```
my-map/
  map.mm            append-only log (the truth)
  context.md        append-only context: pasted text, transcripts, clarifications, chat messages, each a labelled paragraph
  texts/
    1.txt           each submitted source, verbatim
    2.txt
    sentences.jsonl evidence store: {text, s, sentence, t0?, t1?}, append-only, never edited
  audio/
    2.m4a           dropped recordings, kept as given
    2.transcript.json  whisper output with timestamps and speaker labels
  prompts/
    clarify.md      editable prompts; absent file = built-in default
    extract.md
    expand.md
    chat.md
    dedupe.md
    verify.md
  icons/
    manifest.json   keyword → file
    dog.svg
  snapshots/
    0012.mm         canonical form after turn 12 (for undo)
  archive/
    map-2026-10-28.mm   pre-optimize logs
  settings.json     Ollama host and model, whisper model, theme, layout
```

- Writes are append-only on `map.mm`, flushed after every turn, and the same for the evidence store, which is never deleted even by “forget”, so proof always resolves; a write failure keeps the turn in memory and shows a warning until the folder is reachable.
- Opening a folder compiles `map.mm` from scratch; large logs show progress. Several maps = several folders; the Settings panel lists recent folders.
- Export: canonical `.mm`, SVG or PNG of the current view, Markdown outline (headings, nodes as bullets, edges as sub-bullets), and JSON graph for other tools.
- Import: a `.mm` file is appended as one turn; a plain text file goes to the Text panel.
- No data leaves the machine except to the configured Ollama host; transcription is fully local.

## Architecture

&#91;embedded content: extension architecture · 4 parts, 1 contract\]

The UI sends user actions as notation lines and reads back a compiled graph; the model receives a prompt and returns notation lines; the folder receives appends and is read once on open. Nothing but notation crosses a boundary, so each part can be tested with a text file.

- **Native macOS app** in Swift and SwiftUI, with `MenuBarExtra` for the icon and one `Window` for the canvas. Minimum macOS 14. Not sandboxed by default so it can reach localhost and the folder freely; a sandboxed build with the bookmark is possible later.
- **Harness** is a Swift package with no UI dependency: `Parser`, `Compiler`, `Canonical`, `Diff`, `Prompt`, `Gate`, `History`. Tested with the notation spec’s example and the evidence store.
- **Canvas** is a SwiftUI `Canvas` view with a force-directed layout running on a background actor; nodes draw as paths with SF Symbols or the SVG icon set.
- **Ollama client** streams `/api/generate` and feeds lines to the gate as they arrive, so nodes appear while the model is still writing. The app can launch `ollama serve` as a helper if it is installed.
- **Transcriber** wraps whisper.cpp through its Swift package with Metal enabled; runs on a background task with progress.
- **Storage** is a plain folder behind a protocol with an in-memory implementation used by tests and by a demo mode with no folder.

## Gaps and decisions

Gaps in the original idea, with the choice this spec makes. Each is a one-line edit if you disagree.

| Gap | Why it matters | Decision in this spec |
| --- | --- | --- |
| How text removal relates to the graph | “Add even if the old text is gone” needs a way to remove on purpose | Every node carries `@text` support; “forget source n” removes only nodes supported by nothing else |
| Provenance is not in the notation | Distinct styling for world knowledge and guesses needs data, not just a prompt | `@src text/world/guess/advice/user` note on every node and edge; harness enforces it |
| Node categories | “From the text” and “added by the model” need to be told apart at a glance, and advice is not a fact | Closed `@src` set: text, world, guess, advice, user; each with its own border, fill and badge |
| Proof after the context is gone | A node must show its sentences even when the context is cleared | Sentences live in an append-only evidence store; nodes point at sentence ids; the store is never deleted |
| Proof in all-at-once mode | The model is bad at citing exact sentences | Extract asks for a sentence number per line; the gate checks the node name appears in that sentence, else searches, else downgrades to `guess` |
| Model output quality | Small models add junk, duplicates and wrong tags | A harness gate checks parse, names, proof, duplicates, provenance and budget before any append; held-back lines are shown, never hidden |
| Is the context fully represented? | Silent omissions are the main failure of extraction | Verify prompt lists uncovered sentences with proposed lines; status bar shows uncovered-sentence and unsupported-node counts |
| Audio input | Recordings are the richest source and the hardest to paste | Local whisper.cpp transcription with timestamps and speaker diarization; audio kept in the folder; proof can play the clip |
| Who said what | Diarization gives speaker labels but not names; pronouns and places stay ambiguous | Local diarization labels speakers; a Clarify phase, run only when the user asks, lets the model ask questions and the user answer; answers append to the context as labelled paragraphs; the context itself is append-only |
| Name stability across models | A prompt alone will not give identical names | Normal-form rules + harness canonicaliser + node list in the grammar |
| Same name, different things | Scopes would let `paris` be two nodes | Not supported: names are global, one name is one node; the user renames (`paris texas`) when they differ |
| Duplicates the harness cannot see | `dr. ana` and `ana` are the same person but far apart in edit distance | Dedupe prompt proposes `old = new` merges; the user confirms each |
| What “expand” is allowed to add | Unbounded expansion fills the map with noise | Expand adds at most 8 lines per click, about the clicked node; edges between existing nodes are allowed, each tagged |
| Outline needs a place in the notation | Comments were free-floating | `#` heading comments and comment-after-statement attachment |
| Undo on an append-only log | Deleting lines breaks the audit trail | Undo appends inverse turns from snapshots; log never shrinks |
| Log growth | An append-only log with undo turns grows without bound | Optimize rewrites the canonical form and archives the old log; optional every n turns |
| Grammar support varies by model | Not every Ollama build accepts GBNF | Try grammar first, fall back to post-validation per workflow steps 5–9 |
| Long contexts and context windows | A long transcript plus memory can exceed the window even on a big model | Two submit modes: changed paragraphs, or one sentence at a time against the latest map |
| Which model | Extraction quality varies a lot by size | The user picks any installed model; the picker shows what fits in 64 GB and defaults to the largest that does |
| Edge selection and editing | Only nodes were clickable | Edges are selectable: edit label, delete, confirm provenance, comment |
| Layout persistence | Force layout moves nodes every reload | Dragged nodes get `@pos` and are pinned; auto-layout for the rest |
| Multiple maps and switching | One folder = one map was implicit | Recent maps in the menu bar menu; one window per map |
| Icon set licensing and size | Thousands of SVGs bloat the app | SF Symbols first, then \~300 icons from a permissive set (Lucide or Tabler); users add more to `icons/` |
| Model latency and feedback | A 10–30 s wait with no feedback feels broken | Stream the response, draw lines as they parse, show token count, the time it has been running and a **Stop** button (on the map, in the toolbar and status bar; ⌘.) that drops what the model sent so far; every request is stateless (map + context + the item), so any one can be re-run or cancelled without side effects |
| Prompt editing safety | A broken prompt breaks parsing | Prompt panel validates on save by running the example text and checking output parses |
| Privacy | Pasted text and recordings may be sensitive | No network except the configured Ollama host; transcription local; no analytics; a visible “local only” badge |
| When extraction runs | Running on every keystroke wastes the model and surprises the user | Context saves as you type; Extract runs only on explicit Submit |
| Chat messages and the map | A chat answer that silently edits the map is surprising | The user’s message is appended to the context and extracted; model replies stay in chat |

Decided 2026-10-28: Expand may link existing nodes; all scopes on one canvas; explicit Submit with live-saving text; chat messages join the text; the user chooses the model; names are global with no per-scope identity; Submit offers all-at-once or sentence-by-sentence; Optimize compresses the log; Dedupe proposes merges for confirmation; Verify checks text against map; five provenance kinds including advice; proof sentences stored forever and shown for any selection; a harness gate checks every line before append; audio in via local whisper.cpp; a Clarify phase appends who-said-what and other context; the product is a macOS menu bar app, not a Chrome extension; Clarify runs only on “Ask me”; the model is stateless (every request = prompt + map + context + the item; Clarify gets context + map by default, with a context-only option); speaker diarization is attempted locally.

## Development approach

The app should look considered without a design team, and every change should be checkable without clicking through the UI. Both come from the same move: put all logic in the harness, keep the UI a thin pure projection of state, and give the UI one small set of design tokens.

**Where the logic lives.** The harness (parser, compiler, gate, history, evidence, layout) is a Swift package with no SwiftUI import. It exposes one value type, `MapState`, and a list of `Action`s (submit, expand, rename, undo, drag…). Reducing an action to a new state is a pure function, so the whole behaviour of the app is tested with files, not with a mouse.

| Layer | Tests | Runs on |
| --- | --- | --- |
| Notation (parse, compile, canonical, edits) | golden tests: `.mm` in, canonical `.mm` out; the spec’s example is the first case | every commit, under 1 s |
| Gate and canonicaliser | table-driven: model line in, kept / rewritten / dropped out, with reason | every commit |
| Model calls | recorded responses per prompt and model, replayed from fixtures; live Ollama only in a nightly job | every commit (replay), nightly (live) |
| Layout | deterministic: same graph gives the same trees, columns and routes | every commit |
| Views | snapshot tests of each panel and of the canvas against fixture maps, light and dark, two window sizes | every commit, no simulator interaction |
| End-to-end UI | 3 to 5 smoke flows (open folder, submit, expand, undo, drop audio) with `XCUITest` | before a release only |

Snapshot tests replace most UI tests: a view is a function of a fixture state, so a rendering change shows up as an image diff that takes seconds to review, and nothing has to be scripted. A fixture folder with three maps (tiny, typical, large) is checked into the repo and doubles as the demo mode.

**Looking nice by construction**

- One `Theme` with tokens: 4 text sizes, an 8-pt spacing scale, 2 corner radii, one accent, the five provenance styles, and colours for the six node kinds. Views only use tokens; a view that hard-codes a colour or size fails review.
- System materials and SF Symbols where they fit (panels, chips, badges), so the app looks native in light and dark without extra work; the custom icon set is used only inside nodes.
- Motion is limited to three animations: node arrival, panel slide, selection; each a named token with one duration and curve.
- Every view has an Xcode preview bound to a fixture, so design review happens in the canvas without running the model.
- Panels share one container component (header, drag handle, body); new panels add no new chrome.

**Keeping it that way**

- Any new feature starts as actions and state in the harness with tests, then a view that renders it; a pull request without harness tests does not merge.
- The gate, the notation, and the prompts are versioned; changing a prompt re-runs the recorded-fixture suite so regressions in extraction show up as diffs in `.mm` files.
- Crash and error reporting stay local (a log file in the folder), consistent with the privacy rule.

## Milestones

1. **Harness as a Swift package.** Parser, compiler, canonical form, edits, gate, evidence store, with the spec’s example as the test suite. No UI.
2. **Ollama round trip.** Extract prompt with grammar, streaming, post-validation, name canonicaliser, proof attachment. Test: the same text through two models gives the same node set.
3. **Menu bar app and canvas.** `MenuBarExtra`, one window, infinite pan/zoom, force layout, node shapes by kind, provenance styling, icons, click to expand, Proof panel.
4. **Context and folder.** Context, Chat, Settings, Prompt panels; folder picker with bookmark; `map.mm` and `context.md` append and reload.
5. **Audio and clarification.** whisper.cpp transcription with timestamps, speaker diarization, Clarify prompt and panel, play-from-proof.
6. **History, outline, quality tools.** Turns, snapshots, undo/redo, heading comments, Outline panel, Dedupe, Verify, Optimize.
7. **Polish.** Streaming highlights, keyboard shortcuts, global capture shortcut, export, demo mode without a folder, icon packs.

## Update 2026-10-29: the context as a list, actions on the map, details on the right

From using the app. This section supersedes the earlier text where they differ: the Text window in Core concepts, the Context, Clarify, Proof and Chat rows of the Panels table, Node rendering, and the Chat prompt’s trigger.

**Context items.** The left pane holds the context and nothing else. At its top, a box to paste or type new text (**Add text**) and **Add audio…**; below, every item, scrollable, oldest first. Each text added, recording transcribed, clarification answered and reply the model wrote is an item, and once added it stays one. An item shows where it came from (You, Audio, Clarification, Model), when, whether it was edited, and whether it is on the map yet.

- **Click to select or deselect.** Selected items are the current context: every model request (Submit, Expand, Ask, Ask me, Check coverage) reads only them. Deselecting replaces deleting for “not now”: the item and its ideas stay, the model just stops reading it. New items start selected; model replies start deselected.
- **Open over the map.** An item’s open button shows it over the map and closes both panes; they come back when it closes (click outside, the close button or Esc). There it can be read in full, edited, deselected, sent to the map, asked about (**Ask me about this** runs Clarify on that item alone), or deleted.
- **Edit.** Text you added, and model replies, are edited in the overlay. **Save** (or closing) keeps the edit as a new version of the item; the old version stays in `context.md` and the evidence store, so proof that cites it still resolves. An edited item is back in line for Submit, which sends only the paragraphs that changed since the version on the map. Editing a model reply makes it yours: it becomes a typed item, selected.
- **Audio.** **Add audio…** (or a drop on the map) transcribes on the Mac; the transcript joins the list as an Audio item with the recording. Selected, it can be played whole or line by line from the overlay, each line from the moment it was said. A transcript cannot be edited, so text and recording stay in step; a correction or anything to add (who is speaking, where, what a word means) is a clarification, which is a new item. Speakers are named in the overlay, and each name set is a clarification item too.
- **Delete** hides an item from the list; “n deleted” shows them again with **Restore**. Its ideas stay on the map; **Forget its ideas** (the item’s menu) removes the nodes whose only support is that item, as “forget text n” did.
- An item’s menu also has **Select its ideas on the map** and **Submit to the map**.

**Actions on the map.** The buttons that sat at the top of the Context panel now float at the top of the map: **Submit** (with the number of selected items that are new or edited), **Check coverage**, **Ask me**, and a box to ask the model or tell it what to add. Options (one sentence at a time; Ask me reads the context only) are in the bar’s menu. Most asks change the map: lines the model writes are applied as before (`world` or `advice`, through the gate). When the reply has prose, it opens over the map and joins the list as a Model item, tinted and striped in the model’s colour so it is never mistaken for what you added or what was recorded. Ask me’s questions and Check coverage’s report open over the map as well; each answer is a clarification item. The Chat and Clarify panels are gone: their work is the ask box, the overlays and the list.

**Details on the right.** Clicking a node opens the right pane on **Details**: the node’s icon and name, its kind and provenance, then its proof sentences as its description. Each sentence names the item it came from (click to open it over the map) and, for audio, plays the moment it was said. A node with no proof says why (world knowledge, a guess, advice, or yours). Then its notes and comments, its links (click to go to the other node), and Expand or Confirm. Several nodes show the union of their proof; an edge shows its own. The right pane keeps Outline, History, Prompt and Settings as tabs; panels no longer move between sides.

**Node and edge rendering**

| Node | Drawn as |
| --- | --- |
| `src text` (from typed, pasted or recorded context) or `src user` (typed or edited by you) | no box: its icon on top, its name below; the icon is set at twice the name’s size; a root’s name is semibold; `src user` keeps a small pencil by the icon; edges meet the icon’s sides |
| `src world` | a card with a cool blue fill, dashed outline and globe badge |
| `src guess` | a card with a grey fill, dotted outline and question-mark badge, faded |
| `src advice` | a card with a warm fill, double outline and lightbulb badge |

Edge labels are a step smaller than node notes (10.5 pt) and set in the secondary grey, their notes in the tertiary. The SVG export draws the same.

**How it is kept (append-only still holds)**

Every item change is a record appended to `context.md`; nothing is rewritten:

```
[item 3 · text 7 · typed · 2026-10-29T10:00:00Z]
Kim chairs the workshop.

[item 4 · text 8 · model · re: who reviews? · 2026-10-29T10:01:00Z]
Ana reviews the paper.

[item 3 · typed · deselected · 2026-10-29T10:02:00Z]

[item 3 · text 7 · typed · extracted · 2026-10-29T10:03:00Z]

```

- A text record with an item number already used is a new version of that item. Event records (`selected`, `deselected`, `removed`, `restored`, `extracted`) have no body.
- An item’s text goes into the evidence store when it is added, not when it is submitted, so Ask me and Check coverage can read it before Submit. `extracted` records which version went through Extract; Submit sends what is selected and not yet extracted.
- A `context.md` from before items reads as before: each paragraph is an item, numbered in file order, already on the map.
- A body line that would read as a record header is written with a leading space and read back without it.
- Harness actions: `submitText` (add), `submitTranscript`, `addReply`, `reviseContext`, `selectContext`, `removeContext`, `restoreContext`, `markExtracted`; `ContextDocument.items`, `pendingItems`, `selectedTexts`; `Submit.request(for:)`; `MapState.modelTexts` and `proofEvidence`.

**Gaps closed in this update**

| Gap | Decision |
| --- | --- |
| Deleting an item vs append-only | Delete is a `removed` record: the item is hidden, restorable, and its ideas stay on the map until you forget them |
| Editing vs proof | Each save is a new version with its own text id; nodes keep pointing at the sentences they came from |
| What “selected” changes | Only what the model reads (all requests) and what coverage counts; the map is untouched |
| Model prose in the context | A reply is an item marked `model`, deselected at first, labelled “your earlier reply, not evidence” when the model reads it, never cited as proof by the gate, never extracted (its lines arrive through its ```mm block) and never counted by coverage |
| The question you asked | Kept with the reply (“You asked: …”) rather than added to the context, so an instruction like “add the risks” is not extracted as a fact; add it as an item if it is one |
| A dropped recording was never extracted (Submit diffed it away) | A transcript is an item like any other: selected and waiting for Submit |
| Ask me could not see unsubmitted text | Items have evidence from the moment they are added |
| An overlay closes both panes | They come back when it closes, unless you opened others meanwhile |
| Correcting a transcript | Not by editing: add a clarification, a new item, or name the speakers |
| One sentence at a time over several items | One walk over their sentences in turn (only what changed), each item marked on the map as its last sentence is done; a failed request pauses the walk, which can be resumed or stopped |
| Roots without filled cards | Most roots are now open nodes; a root’s name is set semibold instead |
| Where edges meet an open node | At its icon, level with it, so a long name does not leave a gap |
| An item you want the model to read once | Select it, ask, deselect it; the list remembers each choice |

## Update 2026-10-29 (2): models, the notation drawer, adding audio

**Models.** The Settings panel always asks Ollama at the host it shows (`/api/tags`) and lists what is installed with size and fit, or says plainly that Ollama is not answering there, with **Start Ollama** (runs `ollama serve` when it is installed). Changing the host or the grammar setting takes effect on the next request; the client is no longer fixed when the map opens. A demo map answers from its recordings while its model is “demo” and uses Ollama as soon as an installed model is picked. Plain-HTTP requests to a local host are allowed (`NSAllowsLocalNetworking`).

**The notation drawer.** The pill in the map’s bottom left corner is now **Notation**. It opens the map written in the notation, its canonical form, as editable text. When you pause typing (0.7 s), the text is compiled and the lines that take the map to what it says are appended as one user turn (`edit notation`), so the log stays append-only and History can undo it; the map redraws at once. Text that does not compile changes nothing and the drawer shows the line and the parser’s message, with **Revert to the map**. Your edit is the difference from the map you started from, applied on top of whatever the map gained meanwhile (a model’s lines while you typed stay). The text you typed is kept as typed; it reloads from the map only when the map changes and nothing of yours is waiting. Closing the drawer with an edit waiting applies it. **Held back** is the drawer’s second tab (its count shows on the pill), so the gate still never alters the model’s output silently.

**Adding audio.** **Add audio…** (in Context, the menu bar’s “Transcribe audio file…”, or dropping a recording on the map) opens a panel over the map: a drop zone and **Choose a file…** (m4a, mp3, wav, aiff, caf, mp4). Then the recording’s steps, each ticked as it finishes: download the whisper model (first time only, with its progress), read the audio, transcribe (with its progress), find who is speaking, add it to the context. A failure says what went wrong at the step it happened, with **Try again**; a recording with no speech says so. When it is done the panel says which item it became, with **Open it**. The panel can be closed at any time; the work carries on and its progress shows as a row in Context. Demo maps transcribe too (they keep the recording where it was for playback, for the session).

**Gaps closed**

| Gap | Decision |
| --- | --- |
| Picking audio did nothing visible | Demo maps used an empty stand-in transcriber; folder maps showed no progress while downloading a 1.6 GB model. Both now transcribe with whisper and show every step |
| A recording could be kept under the wrong id | The file is stored under the text id the transcript actually gets, after transcription, not the id guessed before it (text added meanwhile shifted it) |
| Settings showed no models | It asked the demo’s stand-in client; it now always asks Ollama |
| Editing text vs append-only | Each pause appends the difference as a turn; nothing in the log is rewritten |
| Model lines arriving while you edit | Your edit is applied as a difference from where you started, so they are kept |
| Held-back drawer replaced | Kept as a tab of the same drawer, with its count on the pill |
