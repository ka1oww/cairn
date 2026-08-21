# Decisions

Why Cairn is built the way it is.

Each file records one pass of decisions, dated. They are the reasoning behind
the architecture, not a changelog — read them when a piece of the app looks
arbitrary and you want to know what it was weighed against. Several of these
reversed an earlier position, and the reversals are kept deliberately: the
argument that changed the answer is usually more useful than the answer.

Read in order:

| Date | What it settles |
|---|---|
| [2026-08-21](2026-08-21-first-calls.md) | The book, photo handover, panel shape, Android delivery, the second ping, the Pool |
| [2026-08-22 — the moment](2026-08-22-the-moment.md) | The daily ping stops being simultaneous. The central decision in the app. |
| [2026-08-22 — design](2026-08-22-design-calls.md) | The seven calls a design round needed: page shape, timestamps, credit, the gate, the camera, the trip view, the window |

Design handoffs that implement these live in [`../design/`](../design/).
