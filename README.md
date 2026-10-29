# Layered — Mindmap Mac App

A macOS menu bar app that turns pasted text or a dropped recording into a living mind map, built by a local Ollama model using the text mind-map notation. `SPEC.md` is the source of truth; `docs/notation-original.md` is the notation contract.

```
Harness/   pure Swift package, no UI: notation, gate, evidence, model layer, storage, history, layout, export
App/       the SwiftUI menu bar app, a thin projection of Harness.MapState
docs/      the notation
scripts/   build-app.sh: builds, signs and zips Mindmap.app (CI and the updater run it)
```

## Install (and update)

**The first time only:** the installer comes through `gh` (GitHub's command line tool), signed in to an account that can see this repository. With [Homebrew](https://brew.sh), paste this in Terminal (a browser window opens to sign in):

```bash
brew install gh && gh auth login --web --git-protocol https -h github.com
```

Then paste this. It keeps your maps and settings.

```bash
gh api -H "Accept: application/vnd.github.raw" repos/ainigh/Layered/contents/install.sh | bash
```

It downloads the latest build GitHub made into `~/Applications` and opens it. If the new app quits as soon as it opens, or anything fails on the way, the app you had is put back. With no build published yet, it builds the app on your Mac (needs Apple's command line tools: `xcode-select --install`). Needs macOS 14 (Sonoma) or newer.

**Updates are a click.** The app checks for a new version when it starts and every six hours (or **Check for updates** in its menu bar menu). When there is one, a notification says so and the menu bar icon becomes a ⬇︎: click the notification, or the update in the menu. It downloads GitHub's build (or builds it on your Mac when GitHub hasn't yet), checks it, swaps it in and opens it again; if the new version won't open, the one you had comes back. It reaches GitHub through `gh`, signed in as above. What went wrong, if anything, is in `~/Library/Logs/Mindmap/update.log` (**Copy error report** in the menu). Running the install command again still works too.

GitHub Actions (`.github/workflows/build.yml`) tests the harness on Linux and builds the app on macOS on every push; a push to `main` also publishes the build as a release (`v0.1.<run number>`), which is what the installer and the updater download.

## Build and test

Harness (Linux or macOS, Swift 6.1):

```bash
cd Harness && swift build && swift test
```

App (macOS 14, Xcode 15.3 or newer):

```bash
cd App && make app        # builds Mindmap.app into App/build/ (scripts/build-app.sh, this Mac's chip)
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
| What the updater compares (versions, releases, commits, the update plan) | `Update/` |

See `Harness/README.md` for the conventions the harness fixes where the spec was open or did not survive contact with the grammar.
