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
| [2026-08-22 — last calls](2026-08-22-last-calls.md) | Roles, deleting your own photo, joining mid-trip, the trip clock, dormancy, and the ping schedule: the 08:00–22:30 window, the arrival and departure days, the day's fixed clock |
| [2026-08-22 — the alert level](2026-08-22-notification-alert-level.md) | The ping does not break through Do Not Disturb, and why respecting that is worth a missed slot |
| [2026-08-22 — the import promise](2026-08-22-auto-import-honesty.md) | iOS will not wake the app for a new photo, so the interface says only what is true |
| [2026-08-22 — the starter](2026-08-22-starter-and-container.md) | What happens when the person who started the trip leaves, who can rename or delete a trip, and who can invite |

Design handoffs that implement these live in [`../design/`](../design/).
