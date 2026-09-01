# The trip's clock is the phone's, and the app says where the plan is — 27 August 2026

Two decisions, taken together because they are the two halves of one defect.
A bug sweep found that **an ordinary build of Cairn had never once put an
itinerary on the server, and nothing on any screen said so.** The backend was
hosted, all ten migrations were applied, the sync was written and tested, the
merge rule was written twice and agreed — and every build shipped with the
push switched off by a compile-time constant nobody could see.

This note settles what replaces the constant, and what the app now says.

## What was actually wrong

`bootstrap.dart` assembled the shared `trips` row from a `String.fromEnvironment`
with **no default**:

```dart
const _tripTimeZone = String.fromEnvironment('CAIRN_TRIP_TIMEZONE');
```

An empty zone meant no `trips` row could be created, which meant the itinerary
had nowhere to be pushed, so `TripSync` reported `awaitingTripRow` and returned.
Forever, on every build anybody would ever run, because `flutter build ios`
passes no defines. The trip's name was a second gate of the same kind:
`trips.name` is `not null`, so a trip nobody had renamed also could not be
published.

Neither gate was a bug in the sense of a wrong line. Both were *deliberate
refusals to guess*, and both were right about the guess and wrong about the
consequence: the alternative to guessing was never "wait", it was "wait
silently, forever, in the one part of the product that is supposed to reach
other people".

And that is the part that made this worth a decision note rather than a fix.
**A person holding the phone could not have found out.** The Trail, the sheet
and the Pool rendered identically whether the plan had reached seven other
phones or had never left this one. The standing existed — `SyncStanding` had
seven values, `awaitingTripRow` among them — and nothing above the repository
seam had ever been allowed to see it.

## Decision one: the clock is the phone's, read as a name

**With no define, the trip's clock is the IANA zone this phone keeps**, read
from the platform. `CAIRN_TRIP_TIMEZONE` survives as an *override*, not a
gate.

Four candidates were weighed.

**The device's UTC offset, rendered as `Etc/GMT±N`.** Rejected. It is not the
same fact. An offset carries no daylight saving, so a trip that crosses a
change is wrong for half its length; and `Etc/GMT±N` cannot spell a half-hour
zone at all — India, Iran, South Australia, Newfoundland and Nepal have no
representation in it. It would also be *plausible*, which is the worst
property a wrong answer can have.

**A package.** Rejected for a one-line fact. Adding a dependency to read a
string the operating system already holds is not proportionate, and this repo
has an established idiom for exactly this.

**The plan's own dates and places.** Rejected, and this is the interesting one,
because it is the answer that sounds best. A plan that says *Tokyo* plainly
wants `Asia/Tokyo`, and the sweep's brief raised it. But deriving a zone from a
place name means either a geocoder (a network call, on the offline-first path,
to answer a question the phone already knows) or a table of place names in the
app (which would be wrong for every place not in it, silently). Worse, a trip
has *many* places, and picking one of them is a guess dressed as a derivation.
The phone's own zone is at least a fact about something real.

**The phone's own IANA name.** Chosen. `TimeZone.current.identifier` in Swift,
over a hand-written method channel — the same shape as `cairn/text_recognition`
(`ios/Runner/DeviceTimeZone.swift`, `lib/app_state/device_time_zone.dart`), a
seam with a real implementation and a fake, so the app's own answer is what the
tests drive.

**What this is right about, and what it is not.** It is right that a trip's
hours are the hours of whoever is on it, and that a phone at home the week
before a trip is a phone in the right zone for planning it. It is *not* right
that the zone a plan was pasted in is the zone the trip is lived in: paste a
Tokyo itinerary in London and the shared row says `Europe/London`. That is
what the override is for, and why the override was kept rather than deleted —
pinning the destination is strictly better than the phone's answer, when
somebody knows to pin it. It is also **not re-read**: the row is created once,
and a phone that flies does not rewrite the trip's clock. Deciding whether a
trip's clock should follow the trip is a real question and is deliberately not
answered here; it is the captain's, and nothing in this change forecloses it.

## Decision two: a trip may be published before it is named

**Yes.** An unnamed trip is published under `unnamedTripPlaceholder` —
`This trip`, the same words the app already shows over a trip nobody has
named — and **the sync maps that wire word back to local null.**

The alternative was to hold the whole itinerary off the server until somebody
typed a title, which is the same silent-forever failure in a second costume,
over a field that is decoration. Of the two lies available — "this trip is
called *This trip*" and "your plan is shared when it is not" — the first is
visible, local to one string, and corrected the moment anybody renames the
trip. The second is the defect.

The original implementation used a one-way ratchet because nothing pushed a
rename up: it adopted a shared name only into an unnamed phone and never
adopted the placeholder. That prevented an immediate reversion, but left the
server stale.

**Captain's ruling, 1 September 2026: “sure let them rename it.”** The server
now follows the phone's flat `canRenameTrip`: any current member may rename,
while the starter-only powers over the rest of the trip row and deletion are
unchanged. A name carries its own `name_revised_at` clock and
`sync_trip_name` applies the same offline last-write-wins shape as itinerary
days: strictly newer wins and the server returns the winner. Flat is not
unbounded: a closed trip takes no rename at all, from any door and from
anybody — the trigger refuses it before the starter's own update path is
reached, not only inside `sync_trip_name` — refused on the server the way
a closed trip's plan and pool already are, so the record keeps the name it
closed under. Clearing a name
travels as `This trip` because the server column is non-null, then maps back to
null on the phone. The old ratchet and its stale-server cost are retired;
`test/shared_facts_sync_test.dart` and the RLS probe pin both halves.

## Decision three: the app says where the plan is

**A plan that has not reached the trip's own copy is visible to the person
holding the phone, in Cairn's voice, without going looking for it.**

This is the half that is actually the defect. The other two decisions only
turn the push on; this one is why turning it on quietly would not have been
enough. Any of the seven standings can happen to a working build — a tunnel,
a refusal, an undated plan — and each of them used to look exactly like
success.

Three rules shape it.

**The standing crosses the seam as a stream, and nothing else does.**
`TripSync.standings` is the one thing above the repository band that knows the
sync exists. No screen may ask it to sync, and none does; the plan's own Drift
stream still drives every reconcile.

**The words are the app's, not the machine's.** `SyncOutcome.detail` — "the
trip clock is not known yet" — is for a log and is never rendered. What a
person reads is written once, in `planSharingFor`, in the register the rest of
the app already speaks:

> The plan is only on this phone, and it stays here until the trip has dates.
> Put one on the first day and the rest follow.

Not a spinner, not an exception, not a status code, and never the word *sync*.
`test/plan_sharing_test.dart` asserts the absence as well as the presence.

**Two depths, one derivation.** The Trail carries a short mark
(*Only on this phone.*) because that is where a person is standing; the trip
sheet carries the full sentence and what to do about it, one tap away. Both
read the same `PlanSharing`, so they cannot disagree.

And **silence is still an answer where silence is honest**: before anything
has reconciled, and on an archived trip (which is never reconciled at all,
[the ending](2026-08-26-the-ending.md)), this phone genuinely does not know
where the plan got to — so it says nothing, rather than guessing in either
direction.

## What remains untrue after this

The push works on an ordinary build and a test proves it against a fake
server. **No two real phones have exchanged an itinerary**, and nothing here
establishes that they can. The hosted project has only ever been touched by
one account, so no RLS refusal has ever been observed there — which is
precisely the path `SyncStanding.refused` now has a sentence for.
`supabase/tests/rls_probe.py` remains the only adversarial evidence, and it
runs against a throwaway Postgres, not the hosted project.
