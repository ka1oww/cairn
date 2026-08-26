# The phone mints the trip's id — 25 August 2026

Decided by the captain: **the phone mints the trip id offline and reconciles
later — a trip can always be created without a connection, for seamless UX.**

This answers a question the model had been ducking. `cairn_model` defined a
trip id as "whatever the layer below produces: a Supabase `uuid` rendered as
text", and the scaffold's disposable `trip_drafts` table sidestepped it
by deliberately holding no `TripId` at all. Both were placeholders for the
same missing answer: *who names a trip that has never been near a server?*

## The decision

**The phone mints the trip's id, in the same transaction that creates the
trip, and the server keeps it.** There is exactly one mint per trip and it is
never reissued. `trips.id` on the server stops being the authority on what a
trip is called and becomes the place that id is stored.

## Why it cannot be the server's

Three reasons, and only the first is the one that was asked for.

**A trip has to be startable in flight mode.** Accepting a pasted plan is the
only door into the app ([paste confirmation](2026-08-22-paste-confirmation.md)),
and the moment somebody is most likely to paste an itinerary is the moment
they are least likely to have signal — on the plane, in the taxi, in the
airport with a dead eSIM. A create that waits on a round trip is a spinner on
the first screen of the product, and the alternative to the spinner is worse:
a trip that exists locally with no id, which is exactly the `trip_drafts`
sidestep.

**The ping schedule seeds itself from the trip id.** `packages/trip_moments`
derives each person's daily minute as a pure function of `(trip id, party,
date)`, and that derivation is frozen (`docs/architecture.md`, invariant 4).
Under a server mint, the id a trip is created with is *not* the id it ends up
with — so the first sync would silently re-deal every remaining day of the
trip. Nothing would raise; the pings would just move. A phone that had already
registered notifications would fire on the old deal until it next recomputed.
This is the reason that would have forced the decision even if the offline
requirement had not.

**An id that arrives late is an id every layer has to be able to do without.**
`TripId` is the word the storage rows, the seam, the app's state and the
interface all use for a trip. Make it nullable-until-sync and every one of
those layers grows a branch for a trip that has not been named yet — the
branch nobody writes tests for, in a product whose whole first phase is
offline. Minting up front deletes that branch instead of handling it.

## What the phone mints, and where

A **version-4 uuid**, in the lower-case hyphenated form Postgres reads back,
because `trips.id` is a `uuid` column and the whole point is that the column
takes this string unchanged.

The work is split the same way invite codes are split, and for the same
reason: `cairn_model` has no randomness and is not growing any.

- `TripId.mint(bytes)` in `cairn_model` is a **formatter**. It takes sixteen
  bytes a caller already has, stamps the version and variant nibbles, and
  returns the id. It is the only place the shape is written down, and
  `TripId.isCanonical` is the same rule read backwards.
- `mintTripId()` in `lib/storage/drift/app_database.dart` is the **draw**:
  sixteen bytes of `Random.secure()`. It sits in the storage band on purpose —
  it is the counterpart of `trips.id`'s `default gen_random_uuid()`, and that
  default lives on the column for the same reason this lives beside the store.

`AppDatabase.startTripIfAbsent` calls it **inside the transaction that decides
there is no trip yet**, so the mint and the row cannot disagree. Nothing above
the store may hand in an id: `MembershipStore.startTrip` no longer takes one
and `paste_flow.dart` no longer names one. An id no row remembers is not an
id.

## How it reconciles, when there is something to reconcile with

Written before anything synced; it does now, against a hosted project
(`supabase/README.md`), and the terms below held unchanged. The id model is
what makes the sync a copy rather than a negotiation:

1. **The first sync inserts the trip with its id.** `trips.id`'s
   `default gen_random_uuid()` fires only when the client omits the column, so
   an insert that names the id keeps it. The insert policy
   (`trips_insert_self` in `0004_trip_members.sql`) checks
   `created_by = auth.uid()` and says nothing about the id, so a client-minted
   id is already accepted by the schema as written. No migration is needed for
   this decision; a comment on the column records it.
2. **The server never reissues.** There is no path where a phone is handed a
   different id and has to renumber its local rows — which is the same thing
   as saying the ping schedule never re-deals.
3. **That first insert must be a plain `insert`, never an upsert.** A uuid
   collision between two phones is vanishingly unlikely (122 random bits), but
   the failure mode matters more than the odds: an `on conflict do update`
   would quietly merge two parties' trips into one, where a plain insert
   raises. Loud and impossible beats silent and improbable.
4. **There is no "synced" column, and there should not be one yet.** The id
   *is* the reconcile key; a flag nothing writes is a fact nothing maintains.
   Phase 2 adds whatever sync state it actually needs, when it needs it.

## What this retires

**The `trip_drafts` sidestep is gone in both of its forms.** The scaffold's
table itself was dropped at schema v2; what survived it was the constant
`localTripId = 'local-trip'` in `lib/app_state/ping_schedule.dart` — the same
sidestep with a different spelling, a trip id standing in for a uuid that had
not been minted yet. It is deleted, and `pingsForPlan` now *requires* a
`TripId` rather than defaulting to one. There is no fallback id anywhere in
the app: an invented id would deal a schedule the trip does not have.

Schema **v5** heals a trip written before the mint existed, replacing
`'local-trip'` with a real uuid. **This is the only time a trip's id changes,
and it can only happen before the id has ever left the phone** — it was written
before any hosted project existed, so no server had seen a `'local-trip'` id
and none ever will. After this, an id is the trip's for good.
