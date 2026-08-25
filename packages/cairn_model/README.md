# cairn_model

The Cairn trip domain, defined once.

`supabase/` had one implicit idea of what a day is, `packages/itinerary_parser`
had another, and the design handoffs in `docs/design/` implied a third. Nothing
had forced them to agree. This package is that forcing function: it is the
vocabulary the database layer, the app's state layer and the interface all
speak, and every layer built after it is written against it.

Pure Dart. No Flutter, no network, no database, no I/O, no dependencies.

```
dart test
```

## The vocabulary

| Word | In code | In one sentence |
| --- | --- | --- |
| Trip | `Trip` | The whole journey: who is on it, how long it runs, what the plan says, and what time it is. |
| Trip clock | `TripClock` | The wall clock everyone on the trip shares. Not any phone's. |
| Day | `TripDay` | One day of the trip, read on the clock it started on. |
| Stop | `Stop` | A place on a day, as the pasted itinerary described it. |
| Member | `Member` | A person on the trip. |
| Invite code | `InviteCode` | The three words somebody says across a table to get onto a trip. |
| An invite | `TripInvite` | One code that was minted for a trip, and whether it still admits people. |
| Photo | `PhotoRef` | A pointer to one photo in the shared pool. The bytes are elsewhere. |
| The day's pool | `DayPool` | One day's slice of the shared pool, plus everyone who has ever contributed to it. |
| Gate | `GateState` | Whether a day's page is open to one person, and why. |
| Where a day stands | `DayStanding` | Behind us, being lived, or still ahead — the only thing the gate asks about time. |
| A date | `CalendarDate` | Three numbers a human would write. Not an instant. |
| A time of day | `ClockTime` | Read off a clock. Not an instant either. |

## Why a day works the way it does

**A day is an artefact, not a measurement.** It is the thing the trip produces
once a day: a page of photos in the order they happened, sealed silently at
midnight (`docs/decisions/2026-08-22-the-moment.md`, and
`docs/decisions/2026-08-22-design-calls.md` §1 for why it is a timeline rather
than a grid). Like any artefact it is made somewhere, and it keeps that
provenance afterwards.

So **a day's clock is fixed where the day starts.** If the group wakes in Tokyo
and lands in London that afternoon, the whole of that day is still read on
Tokyo's clock. Its midnight-to-midnight window is Tokyo's, and a photo taken at
15:00 London time appears on the page at 23:00 — which is what the clock in
their pockets said all day, and what makes "08:40 breakfast · 23:00 the walk
back" a day rather than a folder of pictures
(`docs/decisions/2026-08-22-design-calls.md` §2, "Times show, prominently").
London's clock governs the *next* day: the first one that *starts* there.

`packages/photo_day_assignment` already draws day boundaries this way — its
`TripDefinition.timeZoneOverridesByDay` computes "each day's
midnight-to-midnight window in *that* day's own zone" — and `TripDay.sequence`
is deliberately the same shape, so an override there and an override here mean
the same thing.

The model makes the property hard to get wrong rather than merely possible:

- `TripDay.clock` is final and there is no `copyWith`. A day's clock is chosen
  when the day is built and cannot be moved afterwards.
- `TripDay.startsAt`, `endsAt` and `clockTimeOf` read that clock and nothing
  else. A day cannot reach the trip, so it cannot accidentally be rendered on
  where the trip ended up.
- A day holds a `CalendarDate`, not a `DateTime`. "The fifth of June" is not an
  instant until a clock says which one, which is the same reason
  `packages/photo_day_assignment` has `LocalDateTime`.
- `Trip` orders its days by when they *begin*, not by the date they carry, so a
  trip crossing the date line — which lives the same date twice going west, and
  skips one going east — is still a well-formed trip.

## Why the trip has a clock at all

A trip has one clock its members share. Nobody's phone decides what time it is
on the trip: someone still on home time must not be pinged at 3am
local-to-the-trip, and a day must not seal at eight different midnights.

The decision files do not use the phrase "trip clock", but both existing
packages already implement one and neither would work without it —
`trip_moments` places every ping in the trip's own timezone (`tripUtcOffset`,
and its `quiet_window.dart` refers to a `[TripClock]` that did not exist until
this package), and `photo_day_assignment` falls back to the trip's zone for any
photo without GPS (`TripDefinition.defaultTimeZoneName`). `TripClock` is the
name for the thing they were both already assuming.

It carries **two spellings and resolves neither**: a fixed `utcOffset`, which
is all `trip_moments` can use, and an optional IANA `zoneId`, which is what
`photo_day_assignment` and `photos.capture_timezone` need. Converting between
them takes a timezone database; this package has none and will never have one,
so a caller that has one passes the answer in
(`TripClock.zone('Asia/Tokyo', utcOffset: Duration(hours: 9))`).

## Why the gate is shaped like this

Contribution gates access. It is one of the five load-bearing properties of the
app, and the one thing scattering the daily ping did not touch
(`docs/decisions/2026-08-22-the-moment.md`). A shut gate is not an empty
screen: it shows the shape of the day, obscured — times and names visible,
images not (`docs/decisions/2026-08-22-design-calls.md` §4).

**The gate applies to the day you are living, and to no other day.** That is
the round-one decision in one line — *"A day that is over belongs to the party.
The gate applies to today only."*
(`docs/decisions/2026-08-22-grill-round-one.md` §1) — and it is why
`Trip.gateFor` takes a `now`: which day is in progress is a question about the
clock, asked once, in `TripDay.standingAt`.

Two things open a day, and nothing else does:

- **You contributed to it.** `GateState.openedByContribution`. This outranks
  the clock, so a day you answered reads the same way that evening and a week
  later.
- **It is over.** `GateState.openBecauseTheDayIsOver`. Every day that has
  sealed is open to everyone on the trip — the people who answered it, the
  people who did not, and the person who arrived the following morning. The
  gate exists to make you contribute to the day you are living, never to punish
  you afterwards for one you did not
  (`docs/decisions/2026-08-22-last-calls.md` §3).

A day still ahead is shut for its own reason,
`GateState.shutUntilTheDayArrives`, rather than "awaiting contribution": there
is nothing in it to show and nothing you could put in it, so promising that
contributing would open it would be a promise about a day nobody has reached.

Not on that list: starting the trip. `Trip.gateFor` does not look at
`Trip.startedBy`, and a test pins that. Nor is it on `Member.joinedOnDay` any
more — that used to be the second key, back when a past day otherwise stayed
shut forever; now that every past day is open the late joiner's case is simply
the ordinary one, and their arrival is something the interface marks once
(`docs/design/`, 15d) rather than a reason a gate reports.

`GateState` is one enum rather than a boolean plus a reason, because an open
gate with a "still waiting for you" reason is not a state the app has — and
this way it is not a state anyone can build either. The four-line rule itself
is `GateState.decide`, so that the app's own state layer — which has no roster
and therefore no `Trip` to ask — answers the gate through the same lines rather
than a second copy of them.

**Deleting your own photo leaves the day open.** Contributing is something a
person did; a photo is a thing that exists, and deleting the thing does not
undo the act. Someone tidying up a bad shot must not find themselves locked out
of a day they answered. `DayPool` therefore tracks its photos and its
contributors separately: `deletePhoto` removes from one and never touches the
other, and there is no operation anywhere on the class that removes a
contributor.

There is one way to lose that, and it is worth knowing: `DayPool.of` seeds the
contributor set from the photos you hand it, so rebuilding a day from the
photos that survived would revoke access already earned. Reload with
`DayPool.restore`, which takes the persisted contributor set. `day_pool_test`
asserts both halves so the edge is visible rather than folklore.

## Why members have no roles

Roles are flat. There is no role field, no permission set, and no
`MemberRole` enum, because the product has none of those: everyone on a trip
can do the same things. The single asymmetry is the removal power, and it
lives on the trip (`Trip.startedBy`, `Trip.canRemove`) rather than on the
member, because it is a fact about who started *that trip*, not a rank a
person carries between trips.

`src/trip_powers.dart` is where the whole permission model is written, as
functions over the few facts each rule needs — the app holds a roster long
before it can build a whole `Trip`, and one rule written twice is one rule
that will eventually be two. `Trip`'s own methods delegate to it.

- **Removal** is the one asymmetry, and it is narrower than a group admin:
  it removes a member and does nothing else. It cannot promote anyone,
  moderate a photo, or make another person into a starter, so nothing may
  call its holder an "admin" or draw the role as a title
  (`docs/decisions/2026-08-22-starter-and-container.md` §1).
- **When the starter leaves, it passes to the longest-standing member.** No
  dialog names a successor. There is always exactly one holder and it is
  never nobody, which is why `Trip` no longer requires its starter to be on
  it. Two people who joined on the same day are separated by member id —
  arbitrary, but the *same* arbitrary answer on every phone, which is what a
  party agreeing offline needs.
- **Renaming and minting an invite are flat.** Any member does either.
- **Deleting is the starter's, and only while the trip holds nobody else's
  photos** — after that nobody can, the starter included, because deleting
  cascades eight people's memories. It does not pass on when the starter
  leaves; a trip whose starter has gone is a trip nobody can delete.
- **Revoking a code** belongs to whoever minted it, or to the starter.

`Trip.canRemove` is false for removing yourself: leaving a trip is a
different action, available to everyone (`docs/design/`, 6e "Leave this
trip"), and it is not modelled here.

## Invite codes, and when they die

Three spoken words, forgiving of order and spelling
(`docs/decisions/2026-08-22-grill-round-one.md` §5), drawn as `otter maple 42`
on design surfaces 6d and 15c — two words and a two-digit number, which is
still three things a person says. `InviteCode.matches` accepts them in any
order, in any case, through any punctuation, and one edit out per word, where
a swapped pair of adjacent letters counts as one edit because that is how
people mistype. Every word in the vocabulary is at least three edits from
every other word, which is what makes that slack unambiguous, and a test pins
it rather than trusting it.

**A code carries no expiry of its own.** It dies when its trip closes and at
no other time, so `TripInvite.standingAt` is *told* the trip's close rather
than remembering a second copy of it: two timestamps for one rule are two
chances to disagree about when a trip is over. The close itself is
`tripClosesAt` — trip end plus the fourteen-day grace — and the book's rule
is deliberately not modelled beside it, because the book never expires and
the two were unbundled on purpose
(`docs/decisions/2026-08-22-grace-window.md`).

This package still has no randomness, so it does not mint codes: `InviteCode.draw`
turns three numbers a caller already has into a code, and where those numbers
come from is the app's seam's business.

## Stops, and `itinerary_parser`

`Stop` is the domain-side shape of `itinerary_parser`'s `Stop`, not a parallel
one. The mapping is mechanical:

| `itinerary_parser` | here |
| --- | --- |
| `Stop.text` | `Stop.text`, unchanged and never normalised |
| `Stop.time` (`ParsedTime`) | `Stop.time` (`ClockTime`) — `ClockTime(t.hour, t.minute)` |
| `Stop.isStarred` | `Stop.isStarred`, and it is still a getter over `time` |
| `Stop.sourceLine`, `ParsedDay.confidence` | stay in the parser |
| `ParsedDay.place` | `TripDay.place` |
| `ParsedDay.date` | `TripDay.date` (as a `CalendarDate`) |

`SourceLine` and `Confidence` are evidence about the *parse* — they exist for
the confirmation screen the user sees before the trip starts, and they stop
being interesting once the itinerary is confirmed. They are not domain
vocabulary and are deliberately not mirrored here.

The star rule survives the trip across the boundary intact: a stop is starred
exactly when it has a time, there is no separate flag, and `isStarred` is a
getter precisely so no second field can drift out of step with the first.

## What this package deliberately does not define

Everything here is something the decision record settled. Where it is silent,
this package is silent too — a wrong name here would propagate into every layer
above it, which is the exact cost the package exists to avoid.

- **No notification timing.** No ping, no moment, no schedule. That is
  `packages/trip_moments`, and it stays there.
- **No four-up panel.** `supabase/`'s `daily_moments` and
  `daily_moment_sources` tables model the day as one composed four-up image.
  That mechanic was retired by `docs/decisions/2026-08-22-the-moment.md` — the
  day page is a timeline of individual photos now — so there is no type for it
  here. The backend still carries the retired shape; reconciling that is the
  backend's to do, not this package's to encode.
- **No day-assignment logic.** Deciding which day a photo belongs to is
  `packages/photo_day_assignment`'s job, ladder, confidence and all. By the
  time a photo is a `PhotoRef`, that question is answered.
- **No storage keys, no bytes, no sync state.** A `PhotoId` and the object key
  derived from it are `supabase/README.md`'s business.
- **No book, no cairn, no trail.** The cairn is what the trip turns into
  (`docs/decisions/2026-08-22-design-calls.md` §6) and is drawn from the days;
  it is not a separate thing to model. The book's page design is still open.
- **No account lifecycle.** Signing in, display names arriving from a
  provider, and what deleting an account does to the photos it credited are
  the backend's, and the backend flags what it has not settled. `InviteCode`
  is the code's own grammar and nothing about the accounts it admits.
- `PhotoRef.origin` says whether the app took a photo when it pinged someone or
  whether it came off the camera roll, because the two carry different-quality
  timestamps. **The gate treats them identically**, because the rule is "a
  member who has contributed", full stop. If the product ever wants only a
  pinged photo to open a day, that is a decision to take, not something to
  infer from this enum.

## What this package cannot do

- **A day is exactly 24 hours of its own clock.** A DST transition inside a day
  makes the real midnight-to-midnight 23 or 25 hours; that is not modelled.
  `packages/trip_moments` has the same limitation for the same reason, and
  `packages/photo_day_assignment` — which has real zone data — is the authority
  whenever an instant has to be placed on a day.
- **Consecutive days on different clocks can gap or overlap in absolute time.**
  If day 4 ends at Tokyo midnight and day 5 opens at London midnight, the hours
  between belong to neither window. This is the same gap
  `packages/photo_day_assignment` documents; the model reproduces it honestly
  rather than papering over it, and does not offer a "which day is this
  instant" answer of its own, because refusing to guess is that package's job
  and it does it better.
- **It validates shape, not truth.** It will refuse a trip whose days run
  backwards or that holds the same person twice. It has no idea whether a
  trip is real, whether a `MemberId` exists, or whether a photo was ever
  uploaded. It will not refuse a trip whose starter has left, because that is
  an ordinary trip.

## Testing

```
dart test
```

The tests are aimed at the parts that are genuinely subtle, not the getters:

- `test/trip_day_clock_test.dart` — a day whose clock is fixed at its start
  while the trip crosses a timezone: the photo taken after landing in London
  still belongs to the Tokyo day and still reads at 23:00. Also the gap left
  between two days on different clocks, and a trip that lives the same date
  twice across the date line.
- `test/gate_test.dart` — the gate opening on contribution, staying shut for
  everyone else standing in the day including the person who started the trip,
  every day that is over opening to the whole party at that day's own midnight,
  a day still ahead being shut for its own reason, a mid-trip joiner seeing
  exactly what everyone else sees, and a member deleting their own photo
  leaving the day open.
- `test/day_pool_test.dart` — timeline ordering, deleting only your own photo,
  contributors surviving deletion, and the `DayPool.of`-on-reload trap.
- `test/trip_test.dart` — the trips that cannot be built, removal as the only
  asymmetry, and the power passing when the starter leaves.
- `test/trip_powers_test.dart` — the whole permission model in one place: the
  one narrow power, the flat rest, and the delete gate that shuts for
  everybody once somebody else's photos are in.
- `test/invite_code_test.dart` — a code said back in the wrong order, in the
  wrong case and a letter out; the vocabulary's separation, which is what
  makes that safe; and a code dying with its trip and at no other time.
- `test/values_test.dart` — dates the calendar does not have, clocks no zone
  has, the star rule, and a photo timestamp that is not UTC.
