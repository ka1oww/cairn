# trip_moments

A pure-Dart, offline library that decides *when* each person on a trip is
interrupted. No Flutter, no network, no server. Given a trip, its party and
a date, it deals one ping to each person, and every phone on the trip
derives the same deal with zero coordination.

## What it computes

**One ping per person per day. Never two, never a shared instant.**

The waking day is cut into as many equal slots as there are people, and the
party is dealt across them, one person per slot. At 11:40 exactly one phone
buzzes; that person is the only one interrupted and therefore the only one
holding a phone, so they look up and photograph everyone else. The camera
turns around by itself. That is the whole mechanic, and the reasoning is in
[`docs/decisions/2026-08-22-the-moment.md`](../../docs/decisions/2026-08-22-the-moment.md).

```
08:00                                                            22:30
  |------|------|------|------|------|------|------|------|
   gita    bob    hal   carla   dan    eve   alice  frank
   09:19  10:18  12:30  14:38  16:34  17:38  19:58  22:08
```

(A real day from `test/golden_values_test.dart`: eight people, one each.)

Four properties, all of them load-bearing:

1. **Exactly one interruption per person per day.** Cairn interrupts once
   and never otherwise, which is the cleanest permission ask in the app.
2. **No two people collide, ever.** Not "collides with negligible
   probability" — the deal is a permutation, so two people landing on the
   same minute is structurally impossible.
3. **The party does not bunch up.** One person per equal slot means the
   pings cover breakfast through dinner instead of clustering in the
   afternoon by hash luck.
4. **The deal reshuffles every day.** Nobody owns the breakfast slot for a
   whole trip.

## Why the party is an input

This is the part worth understanding before changing anything.

A device could hash only its own member id, which is what this package used
to do. That derivation cannot see the other seven draws, so it permits two
people to land on the same minute and permits the whole party to pile into
one part of the day. Nothing coordinates independent draws.

So the **party is an input**, and each device computes the whole day's
assignment — everyone's slot, not just its own — from the party plus the
date. Because every device runs that same pure function over the same
inputs, they all arrive at the same permutation without asking each other
or a server anything.

The roster is data the app already holds offline: the backend's
`trip_members_select_co_member` policy lets every member read the full
roster of any trip they belong to, and the app needs it anyway to credit
photos by name. Nothing new has to be fetched to schedule a day.

## The waking day: 08:00 to 22:30

In the trip's own clock, never the phone's home clock. A trip to Auckland
booked from a phone on US Pacific time still gets pings at 08:00–22:30
Auckland time.

The `22:30` close is deliberate and is not a rounding of `22:00`: it pushes
the whole last slot later so the person holding it is interrupted *during*
dinner rather than before it. Dinner is the part of a trip day most worth a
photograph and the part a 22:00 close reliably missed. The `08:00` open is
the same judgement at the other end — early enough for breakfast, late
enough not to wake anyone.

### Where inside a slot the ping lands

Somewhere in the middle three fifths of it, chosen by hashing the slot
index. The outer fifth at each end is held back, which does two things:
consecutive pings can never crowd each other across a slot boundary (the
floor is 40% of a slot — about 43 minutes for a party of eight), and the
very first and last minutes of the day stay empty.

The jitter is not decoration. A schedule that fired at 08:00, 09:48, 11:36
every single day would be learnable, and a ping you can see coming is a
ping you can pose for. The entire value of the mechanic is that the
photograph is one nobody planned.

## The first and last day follow the itinerary

These are the only two days where a fixed window is reliably wrong: you
were on a plane for half of each. `TripDay.opensAt` and
`TripDay.closesAt` take the real arrival and departure times.

Land at 16:00 and that day runs 16:00–22:30, its slots compressed to fit.
Fly out at 11:00 and the day runs 08:00–11:00, which at a 30-minute floor
is six slots for a party of eight — **fewer slots on a short day is the
correct answer, not a shortfall to pad.** The two who miss out are named in
`DayAssignment.unpingedMemberIds`, and because the deal reshuffles, who
misses out rotates too.

Itinerary bounds only ever *narrow* the day. A 05:40 red-eye landing does
not buy anyone an 05:40 ping, and a 23:50 departure does not extend the day
past 22:30. Land at 23:00 and nobody is pinged that day at all.

## A day that changes country keeps the clock it started in

`TripDay.utcOffset` is the offset in force **where the day begins**, and it
holds for the whole day even if the party crosses a border at noon. The
clock moves at the next day boundary.

A day is an artefact, not a measurement. The day's page is one page, and
slots that shifted an hour sideways halfway through it would leave two
people pinged at the same wall-clock minute, or a gap where the clock
jumped. One clock start to finish keeps the slots stable.

Build the itinerary with `tripDays(...)` for a trip that stays in one
clock; construct `TripDay`s directly when it does not, so each day can
carry its own offset.

## How the deal works, in plain English

1. Build a seed out of the inputs that should determine the result:
   `trip_moments/v2/slots/<tripId>/<partyFingerprint>/<YYYY-MM-DD>`. The
   party is folded in as a 16-character fingerprint so the seed stays a
   predictable size however large the party is.
2. Deal the party into slot order with **Fisher–Yates**, drawing each swap
   partner from `stableIndex(...)` instead of a random number generator.
   The result is a permutation, which is what makes collisions impossible
   rather than merely unlikely.
3. Cut the day from its open to its close into one equal slot per person —
   or into however many 30-minute slots fit, on a day too short for
   everyone.
4. For each slot, hash the slot index to pick a minute inside its middle
   three fifths.
5. Add that minute to local midnight in the day's own clock.

`Random()` never appears in this package. What looks like a random time of
day is a SHA-256 hash of `(trip, party, date, slot)`, and a hash is a pure
function: same input, same output, always, on any machine.

**Everything after the hash is integer arithmetic on minutes-since-
midnight.** Nothing is rounded from a float into a time, so there is no
step where two backends could disagree by a microsecond.

## When devices disagree

The assignment is a pure function of the party it is given, so two devices
holding *different* rosters compute different permutations. A mid-trip join
is the case that matters: until every phone has seen the new member, phones
disagree about the deal.

This package deliberately does not paper over that — there is no fallback
that would let a stale device be quietly wrong. It is the app layer's job
to resync the roster before scheduling, and to reschedule the remaining
days when the roster changes. Scheduling at the day boundary rather than
once at trip start makes the window for disagreement small.

## What must never change (read this before touching the derivation)

The property this package exists to guarantee is: **two people on the same
trip, on two different app versions, still compute the same deal.** That
holds only as long as the derivation is byte-for-byte identical across
every version installed on the trip at once. If it changes silently, two
phones stop agreeing — with no error, no crash, nothing in a stack trace.
It would just look like the app is "randomly" a little broken for some
people.

Changing any of these breaks that guarantee:

- The hash algorithm (`sha256` in `lib/src/stable_hash.dart`).
- The seed string format: field order, delimiters (`/`), casing, or the
  `trip_moments/v2/...` namespace prefix.
- The date format (`YYYY-MM-DD` via `dateKey()`).
- How many digest bytes are read (the first 6 / 48 bits) or their byte
  order (big-endian) — **or the arithmetic used to assemble them.**
- The party's canonical form (sorted, de-duplicated) or its fingerprint.
- The shuffle: Fisher–Yates, descending, with `.../swap/<i>` seeds.
- The slot geometry: equal division, the 30-minute floor, the 20% inset.
- The default `PingWindow` (08:00–22:30), for anyone not overriding it.

If one of these genuinely has to change, bump the namespace
(`trip_moments/v2/...` → `.../v3/...`) so old and new builds are
*guaranteed* to disagree everywhere, loudly and consistently, rather than
agreeing on some trips and splitting on others depending on hash-space
luck. That is a real user-facing migration ("everyone update before your
next trip"), not a transparent one.

### Why SHA-256 specifically

Dart's `Object.hashCode` / `Object.hash()` are explicitly *not* guaranteed
stable across Dart versions, isolates, or even separate runs of the same
program — they exist for in-memory structures like `HashMap`, not for
values you need to reproduce on someone else's phone. SHA-256 is a fully
specified, versionless algorithm; its output for a given input can never
change, on any platform, in any future SDK. A seeded PRNG would have the
same problem as `hashCode`: Dart does not promise its stream is stable
across versions.

### Why only 48 bits, and why multiplication

Dart compiled to JavaScript represents `int` as a double, exact only up to
2^53. A 64-bit value would be correct on the Dart VM and silently lose
precision on web, so two people on the same trip would derive different
schedules depending on which backend built their app. 48 bits stays exact
on every backend while still giving ~2.8 × 10^14 distinct values.

**The bit count alone is not enough — the arithmetic has to be portable
too.** `lib/src/stable_hash.dart` builds the value with
`value = value * 256 + byte`, never `value = (value << 8) | byte`, and
writes the 48-bit ceiling as the literal `281474976710655` rather than
`(1 << 48) - 1`. This is not cosmetic. dart2js specifies `int` bitwise
operators as **32-bit**, so a shift-based accumulation of 48 bits silently
truncates on web while working fine on the VM — a bug this file has
actually shipped.

Accumulating the six bytes `DE AD BE EF 12 34` both ways, compiled for each
backend, reproduces it exactly:

|                    | Dart VM           | dart2js / Node          |
| ------------------ | ----------------- | ----------------------- |
| `(value << 8) \| b` | `244837814047284` | `3203338804` *truncated* |
| `value * 256 + b`  | `244837814047284` | `244837814047284`       |
| `(1 << 48) - 1`    | `281474976710655` | `-1`                    |

Note the last row: the ceiling constant does not merely lose precision on
web, it changes sign. Do not "simplify" the arithmetic back to shifts.

### Verified cross-platform, and reproducibly

`test/determinism_test.dart` runs entirely on the Dart VM, so it cannot by
itself detect a VM-vs-web divergence — every device it simulates shares one
backend. The cross-platform half is backed by a command anyone can re-run:

```
dart run tool/print_goldens.dart > /tmp/vm.txt
dart compile js -O0 -o /tmp/goldens.js tool/print_goldens.dart
node /tmp/goldens.js > /tmp/js.txt
diff /tmp/vm.txt /tmp/js.txt
```

An empty diff is the proof. `tool/print_goldens.dart` and
`test/golden_values_test.dart` both read the same `goldenLines()` from
`test/golden_fixture.dart`, so the values the test pins and the values this
check compares cannot drift apart. Re-run it whenever
`lib/src/stable_hash.dart` or `lib/src/slots.dart` changes; it is not
automated, so a genuinely web-specific regression would still need this
diff (or a Node step in CI) to be caught.

## What this cannot do

- **No true IANA timezones, no DST.** A day's clock is a fixed UTC offset,
  supplied per day by the app layer. That is enough to fix the clock where
  a day starts, but the app is where a DST transition or a real zone
  lookup has to be resolved.
- **A party larger than the day can hold is not fully pinged.** At the
  30-minute floor a full waking day holds 29 slots, so a trip of more than
  29 people leaves some unpinged each day — rotating, like a short day.
  Cairn is built for a party of about eight.
- **No cross-day fairness.** Someone who misses out on a short arrival day
  is not compensated on the next one. Each day is dealt independently, and
  fairness is the reshuffle averaging out, not a ledger.
- **No enforcement that a phone actually fires the notification.** This
  package hands the app a list of instants; whether the OS wakes the app
  (permissions, battery optimization, the device being off) is outside its
  control.
- **No knowledge of who answered.** The schedule is derived, not recorded.
  Late contributions, the answering window (how long it lasts is the app's
  own `captureWindow`, not this package's) and the day's page belong to the
  app layer.
- **No trip metadata.** This package does not know what a trip "is" beyond
  a string id, a party of member ids, dates and offsets. It does not
  validate that a trip exists, load timezones, or know when a trip starts —
  the app supplies all of that.

## API

```dart
import 'package:trip_moments/trip_moments.dart';

final party = Party(['alice', 'bob', 'carla', 'dan', 'eve', 'frank',
                     'gita', 'hal']);

// A trip that stays in one clock: eight days, landing at 16:00 on the
// first and flying out at 11:00 on the last.
final schedule = tripSchedule(
  tripId: 'trip-bali-2026',
  party: party,
  days: tripDays(
    fromDate: DateTime(2026, 9, 3),
    toDate: DateTime(2026, 9, 10),
    utcOffset: const Duration(hours: 8),
    arrival: const Duration(hours: 16),
    departure: const Duration(hours: 11),
  ),
);

// What this device registers with the OS: its own line through a schedule
// it computed for the whole party.
for (final ping in pingsForMember(schedule, myMemberId)) {
  scheduleLocalNotification(at: ping.at);   // ping.at is a UTC instant
}

// The whole day, which is what the day's page needs.
for (final ping in schedule.first.pings) {
  print('${ping.localLabel}  ${ping.memberId}');   // 16:27  alice
}
print(schedule.last.unpingedMemberIds);            // [dan, gita]

// A trip that crosses a border: give each day the offset in force where
// that day begins.
final asia = tripSchedule(
  tripId: 'trip-asia',
  party: party,
  days: [
    TripDay(date: DateTime(2026, 5, 3), utcOffset: const Duration(hours: 7)),
    TripDay(date: DateTime(2026, 5, 4), utcOffset: const Duration(hours: 9)),
  ],
);
```

All returned `DateTime`s are UTC instants (`.isUtc == true`); convert with
`.toLocal()` only for display, not for scheduling — the instant is already
correct whatever timezone the phone is in. For display in the *trip's*
clock, use `Ping.localTimeOfDay` or `Ping.localLabel`.

## Testing

```
dart test
```

- `test/determinism_test.dart` — the test that is the point of this
  package: independently constructed devices, sharing only the party and
  the date, compute bit-for-bit identical assignments.
- `test/one_ping_per_person_test.dart` — exactly one ping per person per
  day, across a full trip.
- `test/collision_and_spread_test.dart` — no two members ever share a
  minute, exactly one ping per equal slot, and the party covers the day
  edge to edge rather than clustering.
- `test/reshuffle_test.dart` — the deal differs between consecutive days,
  the first slot rotates, and over a long run everyone visits every slot.
- `test/short_day_test.dart` — arrival and departure days are bounded
  correctly, including the days too short to hold a slot for everyone.
- `test/trip_clock_test.dart` — the trip's clock is used, not the phone's,
  and a day that changes country keeps the clock it started in.
- `test/golden_values_test.dart` — a pinned table, cross-checked against a
  dart2js/Node build. See "Verified cross-platform".
- `test/stable_hash_test.dart` — the hash primitives, the slot geometry and
  the permutation.
- `test/party_and_schedule_test.dart` — party canonicalisation and the
  whole-trip helpers.
