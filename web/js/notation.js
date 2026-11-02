// The text mind-map notation (docs/notation-original.md): lines in, a graph out.
// A port of Harness/Notation (Parser, Graph, Compiler), names global (no scopes), as the app runs it.
(function (MM) {
  "use strict";

  // Trims and collapses runs of whitespace to one space (notation §2).
  function collapse(s) {
    return s.split(/\s+/).filter(Boolean).join(" ");
  }

  class NotationError extends Error {
    constructor(line, message) {
      super(`line ${line}: ${message}`);
      this.line = line;
      this.detail = message;
    }
  }

  // A symbol is active only when preceded by whitespace or first in the line (§2).
  // The first token has no symbol and holds any leading text.
  function tokenize(body) {
    const tokens = [{ symbol: null, text: "" }];
    let previousWasSpace = true;
    for (const ch of body) {
      if (previousWasSpace && "|-@=".includes(ch)) tokens.push({ symbol: ch, text: "" });
      else tokens[tokens.length - 1].text += ch;
      previousWasSpace = /\s/.test(ch);
    }
    return tokens.map((t) => ({ symbol: t.symbol, text: collapse(t.text) }));
  }

  function parseName(text, number, context) {
    if (!text) throw new NotationError(number, context);
    const at = text.indexOf("@");
    if (at >= 0) throw new NotationError(number, `\`${text}\` qualifies a scope; names are global in this map, write \`${text.slice(0, at).trim()}\``);
    return text;
  }

  // One trimmed line: a comment, or a statement (a path, or an edit).
  function parseLine(raw, number) {
    const line = collapse(raw);
    if (line[0] !== "|") return { comment: line };
    const tokens = tokenize(line.slice(1));
    if (tokens.length >= 2 && tokens[0].text === "" && tokens[1].symbol === "@") {
      throw new NotationError(number, "scopes are not used in this map; names are global");
    }
    const first = parseName(tokens[0].text, number, "`|` needs a name after it");
    const names = [first], links = [];
    let labels = [], notes = [], undirected = false;
    for (let i = 1; i < tokens.length; i++) {
      const t = tokens[i];
      switch (t.symbol) {
        case "=": {
          if (i !== 1) throw new NotationError(number, "`=` must come right after the name: `| old = new` or `| old =`");
          if (i !== tokens.length - 1) throw new NotationError(number, "nothing may follow an edit: `| old = new` is a whole line");
          const next = t.text ? parseName(t.text, number, "`=` needs a name after it, or nothing to delete") : null;
          return { edit: { old: first, new: next } };
        }
        case "-":
          if (undirected) throw new NotationError(number, "`- |` must be followed directly by a name; a label cannot come between");
          if (!t.text) {
            if (!(i + 1 < tokens.length && tokens[i + 1].symbol === "|")) {
              throw new NotationError(number, "`-` needs a label after it, or `|` directly after it for an undirected edge");
            }
            undirected = true;
          } else labels.push(t.text);
          break;
        case "@":
          if (undirected) throw new NotationError(number, "`- |` must be followed directly by a name; a note cannot come between");
          if (!t.text) throw new NotationError(number, "`@` needs note text after it, like `@date 2026-11-03`");
          notes.push(t.text);
          break;
        case "|": {
          const name = parseName(t.text, number, "`|` needs a name after it");
          links.push({ labels, notes, directed: !undirected });
          names.push(name);
          labels = []; notes = []; undirected = false;
          break;
        }
      }
    }
    if (undirected) throw new NotationError(number, "`- |` needs a name after it");
    if (labels.length) throw new NotationError(number, `the label \`${labels[0]}\` needs a target: add \`| name\` after it`);
    return { path: { names, links, notes } };
  }

  // Note convention: a note starts with its kind (`date`, `src`, `kind`, …).
  function splitNote(note) {
    const space = note.indexOf(" ");
    return space < 0 ? { kind: note, value: "" } : { kind: note.slice(0, space), value: note.slice(space + 1) };
  }

  // Note kinds the app treats as single-valued: a new `@pos` replaces the old one.
  const SINGLE_VALUED = new Set(["src", "kind", "icon", "pos"]);

  function addNote(notes, note) {
    const kind = splitNote(note).kind;
    if (SINGLE_VALUED.has(kind)) {
      const i = notes.findIndex((n) => splitNote(n).kind === kind);
      if (i >= 0) { notes[i] = note; return; }
    }
    if (!notes.includes(note)) notes.push(note);
  }

  function noteOf(notes, kind) {
    for (const n of notes) { const s = splitNote(n); if (s.kind === kind) return s.value; }
    return null;
  }

  // Strings compared as Swift compares ASCII names: by code unit.
  function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }

  // An edge is the unordered pair of its nodes.
  function edgeKey(a, b) { return cmp(a, b) <= 0 ? { lo: a, hi: b } : { lo: b, hi: a }; }
  function keyString(a, b) { const k = edgeKey(a, b); return k.lo + "\u0000" + k.hi; }

  class Graph {
    constructor() {
      this.nodes = new Map(); // name → { name, notes, heading }
      this.edges = new Map(); // keyString → { a, b, forward, backward, labels, notes }
      this.comments = [];
      this.headings = [];
    }

    node(name) { return this.nodes.get(name) || null; }
    edge(a, b) { return this.edges.get(keyString(a, b)) || null; }

    apply(parsed, number) {
      if (parsed.comment !== undefined) {
        const text = parsed.comment;
        if (text.startsWith("#")) {
          const level = Math.max(1, text.match(/^#*/)[0].length);
          this.headings = this.headings.slice(0, level - 1).concat([collapse(text.replace(/^#*/, ""))]);
        }
        this.comments.push(text);
      } else if (parsed.edit) {
        const { old, new: next } = parsed.edit;
        if (next !== null) this.rename(old, next); else this.remove(old);
      } else {
        const { names, links, notes } = parsed.path;
        for (const n of names) if (!this.nodes.has(n)) this.nodes.set(n, { name: n, notes: [], heading: this.headings.slice() });
        links.forEach((link, i) => this.addEdge(names[i], names[i + 1], link.directed, link.labels, link.notes));
        const last = this.nodes.get(names[names.length - 1]);
        for (const note of notes) addNote(last.notes, note);
      }
    }

    addEdge(from, to, directed, labels, notes) {
      const k = keyString(from, to);
      let e = this.edges.get(k);
      if (!e) { e = { a: from, b: to, forward: false, backward: false, labels: [], notes: [] }; this.edges.set(k, e); }
      if (directed) { if (from === e.a && to === e.b) e.forward = true; else e.backward = true; }
      for (const l of labels) if (!e.labels.includes(l)) e.labels.push(l);
      for (const n of notes) addNote(e.notes, n);
    }

    edgesTouching(name) {
      return [...this.edges.values()].filter((e) => e.a === name || e.b === name)
        .sort((x, y) => { const kx = edgeKey(x.a, x.b), ky = edgeKey(y.a, y.b); return cmp(kx.lo, ky.lo) || cmp(kx.hi, ky.hi); });
    }

    // `old = new`: the node becomes `new`, merging into it if it exists (§4 “Edits”).
    rename(old, next) {
      if (old === next || !this.nodes.has(old)) return;
      const node = this.nodes.get(old);
      this.nodes.delete(old);
      const target = this.nodes.get(next) || { name: next, notes: [], heading: node.heading };
      for (const n of node.notes) addNote(target.notes, n);
      this.nodes.set(next, target);
      for (const e of this.edgesTouching(old)) {
        this.edges.delete(keyString(e.a, e.b));
        if (e.a === old) e.a = next;
        if (e.b === old) e.b = next;
        if (e.a === e.b) continue;
        const k = keyString(e.a, e.b), existing = this.edges.get(k);
        if (existing) {
          if (e.forward) this.addEdge(e.a, e.b, true, [], []);
          if (e.backward) this.addEdge(e.b, e.a, true, [], []);
          for (const l of e.labels) if (!existing.labels.includes(l)) existing.labels.push(l);
          for (const n of e.notes) addNote(existing.notes, n);
        } else this.edges.set(k, e);
      }
    }

    // `old =`: the node goes with its edges.
    remove(name) {
      this.nodes.delete(name);
      for (const e of this.edgesTouching(name)) this.edges.delete(keyString(e.a, e.b));
    }
  }

  // Compiles a log into a graph, stopping at the first line that fails.
  function compile(source) {
    const graph = new Graph();
    source.split(/\r\n|\r|\n/).forEach((raw, i) => {
      const text = raw.trim();
      if (!text) return;
      graph.apply(parseLine(text, i + 1), i + 1);
    });
    return graph;
  }

  MM.notation = { collapse, tokenize, parseLine, compile, Graph, NotationError, splitNote, noteOf, edgeKey, keyString, cmp };
})(typeof window !== "undefined" ? (window.MM = window.MM || {}) : (globalThis.MM = globalThis.MM || {}));
