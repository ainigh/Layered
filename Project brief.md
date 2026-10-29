
**Project brief**

You are building the Mindmap Mac App described in `SPEC.md` (export the doc to Markdown and put it in the repo). The spec is the source of truth; the text mind-map notation in `NOTATION.md` is the contract between every part. Read both fully before writing code.

**How to work**

- Build in the milestone order in the spec. Do not start a milestone until the previous one is green. Within a milestone, start with the harness (pure Swift package, no UI import), then views.
- Before each milestone, write a short plan: the types, the actions, the tests you will add, and anything in the spec that is ambiguous. Ask me about ambiguity then, not mid-build. If something in the spec is wrong or will not work, say so and propose the smallest change rather than silently deviating.
- Every behaviour lives in the harness as `MapState` + `Action` → `MapState`. Views only render state and dispatch actions. If you find yourself putting logic in a view, move it.
- Tests are not optional. A change is done when: the golden `.mm` tests pass, the new behaviour has its own table-driven test, snapshot tests are updated and the diff is intentional, and `swift build` has zero warnings. Model calls in tests use recorded fixtures; never require a running Ollama for the test suite.
- Keep each change small and complete: one feature, its tests, its preview, committed with a message that says what and why. No half-wired features, no TODOs that hide missing behaviour.
- Match the existing style and the `Theme` tokens. Do not introduce a dependency, a hard-coded colour, or a new UI pattern without saying why.
- When you finish a milestone, give me: what works, how to try it, what is not covered by tests, and what you would do differently given what you learned.

**Quality bar**

- The notation parser must accept everything the GBNF grammar produces and reject the documented errors with a line number and a message a user can act on.
- The gate must never silently alter model output; everything held back is reported.
- Append-only is absolute: no code path deletes or rewrites `map.mm`, `context.md` or the evidence store except Optimize, which archives first.
- The app must run with no network and no folder (demo mode) so I can see the UI without the model.
- Do not sacrifice UI look and feel. Bring in the best you can
