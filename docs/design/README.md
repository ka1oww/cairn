# Design

The design system and its handoffs, one file per round.

Each handoff is a self-contained page: open it in a browser. The `.dc.html`
files carry the annotated directions — every screen with the decision that
produced it and the alternatives it beat. The `.zip` is the full export.

| Round | File | What it added |
|---|---|---|
| 21 Aug 2026 | `2026-08-21-handoff.zip` | Directions, the Sticker Trail system, ten stress tests, icon and wordmark, four missing surfaces, the way in, the quiet months |
| 22 Aug 2026 | `2026-08-22-handoff.zip` | The day page, the shut gate, the capture, the trip cairn, the one notification |
| 22 Aug 2026 (round 7) | `2026-08-22-round7-handoff.zip` | The retired simultaneous surfaces redrawn on the scattered model, every trip surface at eight people, and first surfaces for the alert level, the import promise, the starter and the container, and joining mid-trip |
| 22 Aug 2026 (round 8) | `2026-08-22-round8-handoff.zip` | The screen after the paste: the confident read, the uncertain read, correcting the parse, and the paste that wouldn't parse |
| 22 Aug 2026 (round 9) | `2026-08-22-round9-handoff.zip` | The book interior, drawn against the printed reference: the cover, the day spread in two honest treatments plus the blend that was settled on 23 August, the quiet and full days, the closer where the cairn appears, and the non-photo cell |
| 22 Aug 2026 (round 10) | `2026-08-22-round10-handoff.zip` | The two surfaces the book decisions created: where a word is written (the caption line at the capture breath, words-later on your own print, the wordless book) and the page as paper (Blurb's measured 8×10 geometry, round nine re-read against the fold, the four-up, the printed colophon and the ink specimen) |

`2026-08-22-round7-review.html`, `2026-08-22-round8-review.html`,
`2026-08-22-round9-review.html` and `2026-08-22-round10-review.html`
are one-page reviews of their rounds: every changed surface, with the
decision that shaped it.

## Reading these against the decisions

Round 7 settles what the earlier handoffs left in flight. Build from the
latest drawing of a surface, which for everything the moment or the party
size touches is in `2026-08-22-round7-handoff.zip`:

- The six surfaces in the 22 August handoff that drew the simultaneous
  mechanic are resolved: `2d` → `13a` (the day as a sealed card of scattered
  prints), `3f` → `13b` (five of eight answer and the day is complete),
  `5c` → `13c` (back camera primary, live front inset, one tap), `5e` → `13d`
  (one person's slot, and the deal diagram), `7d` → `13e` (the cover's
  tipped-in cairn, one stone per day). `6f`'s notification column was checked
  and confirmed superseded by `12a`, which still stands as drawn.
- The party is **eight people**, and the trip-level surfaces are redrawn at
  that size: the gate (`14a`), the Pool (`14b`), the cairn caption (`14c`),
  the member list (`15c`) and the joining sheet (`15d`).
- The four decisions that had no surface now have their first ones: the
  alert level (`15a` — the ping never breaks through Do Not Disturb, and no
  loudness setting exists), the import promise (`15b` — photos are swept when
  the app is opened, and the words claim nothing more), the starter and the
  container (`15c` — rename and invite flat, delete gated once the trip
  holds others' photos, removal power passes silently), and joining mid-trip
  (`15d` — past days open freely, today gated like anyone's).

Still current from the 22 August handoff: `8` (day page), `9`'s composition
at the round-7 count, `10` (capture room states), `11` (the cairn), `12`
(the notification).

The **paste-confirmation gap is closed** (round 8): what the itinerary
parser understood now has its screens — the confident read (`16a`), the
uncertain read built on the parser's per-day confidence (`16b`), in-place
correction (`16c`), and the nothing-parsed path (`16d`). They are designed
to `packages/itinerary_parser/README.md`'s contract: per-day high/medium/
low drives the layout, unplaced lines are always shown with reasons, and
everything is read on the phone — no surface implies a server saw the plan.

The **book's interior is designed** (round 9, drawn against the printed
reference the captain supplied): build book pages from the round-9
handoff, not from the earlier sketches. `2g`'s book page and `7e`'s
spread and colophon cards are superseded by the turn-17 surfaces
(`17b`/`17d` day spread, `17e`–`17f` at the volume extremes, `17g` the
closer); `7e`'s middle card — the long-press slide-to-day correction —
still stands as drawn. The treatment is **settled**: `17d`, the blend --
treatment A warmed only by what the app already owns. It stopped being a
recommendation on 23 August ([the book's
treatment](../decisions/2026-08-23-book-treatment.md)), which also carries
the rule the drawing is an instance of: *the book may only look handmade in
ways that are true.* The two treatments it beat -- admit it is generated,
simulate the handmade -- stay drawn in the round-9 handoff as the argument
that produced it. Round 9's two open
questions were both decided on 22 August: the cover's face is the
**photograph** (`17a`, with the cairn signing the foot — `13e`'s
pile-as-portrait cover is superseded), and **authored words are in**:
the book generates itself and nobody edits it, but it prints words
people had already written.

Those decisions created **round 10's two surfaces** (turn 18). The word
is written at the capture breath — one dashed line on `10d`'s
confirmation sheet (`18a`–`18b`), skippable by construction — and stays
writable on your own print until the trip closes (`18c`); the wordless
book is round nine's book unchanged (`18d`). The page is designed
against Blurb's published PDF-to-Book 8×10 geometry (`18f`): an
eight-day trip lands exactly on the 20-page minimum, `17f`'s gutter
caption moves to the fore-edge to survive the binding (`18g`), the
four-up surrenders its middle column to the fold (`18h`), and the
printed colophon replaces `17g`'s button bar with derived facts and an
ink specimen (`18i`). One question is escalated, not decided: how a
written line dresses — four registers drawn and priced on the captain's
board (`18e`), flagged `needs-decision` on the status file.

## Corrections to an exported round

Rounds are exported as they were drawn and are not revised for taste. One
correction has been made, because the drawn record contradicted a settled
decision:

- **13c's camera annotation** (round 7, 25 August 2026) said the two frames
  fire "at the same instant". The dual-camera spike settled **back-then-front
  sequential** capture, recorded in
  `docs/decisions/2026-08-22-camera-like-bereal.md`; round 10's review had
  already flagged the line as stale. The annotation now reads as a sequence in
  `2026-08-22-round7-handoff.zip` (`CameraBackFirst.dc.html`, `canvas.json`,
  `cairn-round7.html`) and in `2026-08-22-round7-review.html`. Nothing else in
  round 7 was touched, and the board's drawing was already correct. Round 10's
  note stands as the record of how it was found.

## House system

Paper `#FFF4E4` · sticker `#FFFDF8` · ink `#43382C` · muted `#8C7B66` ·
coral `#F4623E` · amber `#E9A13B` · work blue `#3E6795`.
Young Serif for display, Atkinson Hyperlegible for text.
Coral fills only the today-flag and one primary button per screen.
