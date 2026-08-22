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

`2026-08-22-round7-review.html` and `2026-08-22-round8-review.html` are
one-page reviews of their rounds: every changed surface, with the
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

The **book's interior is untouched**: a printed reference for the page
design is still owed, and no round guesses at it. That is why captions
inside the book-spread surfaces (`2g`, `7e`) still read four — they are
interior pages, out of scope until the reference lands. The cover (`13e`)
is the one book surface redrawn, because it carried the retired four-up.

## House system

Paper `#FFF4E4` · sticker `#FFFDF8` · ink `#43382C` · muted `#8C7B66` ·
coral `#F4623E` · amber `#E9A13B` · work blue `#3E6795`.
Young Serif for display, Atkinson Hyperlegible for text.
Coral fills only the today-flag and one primary button per screen.
