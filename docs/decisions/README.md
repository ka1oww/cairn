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
| [2026-08-22 — grill round one](2026-08-22-grill-round-one.md) | Past days open, the itinerary syncs and propagates, originals kept, the trip really ends, three spoken words, spike the camera now |
| [2026-08-22 — the camera](2026-08-22-camera-like-bereal.md) | The capture stays BeReal-shaped — back full-bleed, front inset, taken as a sequence — and the stale front-full-bleed note is confirmed dead |
| [2026-08-22 — the screen after the paste](2026-08-22-paste-confirmation.md) | The parse-confirmation gap, closed by design round eight, and the parser API extension it exposed |
| [2026-08-22 — book round nine](2026-08-22-book-round-nine.md) | The photograph is the cover's face with the cairn signing the foot, and people may write their own words |
| [2026-08-22 — no book editor](2026-08-22-book-no-editor.md) | The book generates itself; authored words are captions at capture time, not an editing surface |
| [2026-08-22 — the grace window](2026-08-22-grace-window.md) | The trip closes to new photos fourteen days after it ends; the book stays makeable forever. Two rules, never one timestamp. |
| [2026-08-22 — the first release](2026-08-22-first-release.md) | The line: whatever makes one real trip work for eight people is in; everything else is deliberately after |
| [2026-08-22 — the cat](2026-08-22-cat-deferred.md) | The cat is parked as a future feature, with the feasibility findings preserved |
| [2026-08-22 — paying later](2026-08-22-paying-later.md) | The Apple $99 waits until the weekend test with friends — the first moment the app must reach someone else's phone |
| [2026-08-22 — the December target](2026-08-22-december-target.md) | No trip is in the calendar; December is the chosen anchor, with six weeks of slack and the two things that would spend it |

Design handoffs that implement these live in [`../design/`](../design/).
