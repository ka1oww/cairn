# trip_moments

A pure-Dart, offline library that decides *when* to ping people on a trip.
No Flutter, no network, no server. Given a trip ID and a date, it derives
notification times that every phone on the trip computes identically, with
zero coordination.

## What it computes

Two kinds of ping, both confined to a **quiet window** (default 09:00-21:00,
**in the trip's own timezone**), and never more than two pings per day:

1. **The daily moment** — one instant per day, shared by everyone on the
   trip. Every device computes the same answer from nothing but the trip ID
   and the calendar date.
2. **The scattered ping** — one instant per day, *per device*, different
   from everyone else's on the same trip, but reproducible by that same
   device if it recomputes it later.

`tripSchedule(...)` combines both into a full day-by-day schedule for a
trip (or the remainder of one), so the app can register local notifications
for every remaining day in a single pass and then go fully offline.

## How the derivation works, in plain English

Both kinds of ping are computed the same way:

1. Build a seed string out of the inputs that should determine the
   result — for the daily moment, that's just the trip ID and the date
   (`trip_moments/v1/daily/<tripId>/<YYYY-MM-DD>`); for a scattered ping,
   it also includes a per-device ID
   (`trip_moments/v1/scatter/<tripId>/<YYYY-MM-DD>/<deviceId>`).
2. Hash that string with **SHA-256**.
3. Take the first 6 bytes (48 bits) of the digest and treat them as a
   big-endian integer, then divide by `2^48 - 1` to get a number in
   `[0, 1)`.
4. Use that number as "how far into the quiet window" the ping falls,
   measured against local midnight *in the trip's timezone*.

That's the whole trick. There's no randomness anywhere — `Random()` never
appears in this package. What looks like a random time of day is really a
cryptographic hash of `(trip, date[, device])`, and a hash is a pure
function: same input, same output, always, on any machine, because SHA-256
is a fully specified algorithm with no platform-dependent behaviour.

## Why this needs no server

Because the derivation is a **pure function** of data every device already
has locally (the trip ID it joined, today's date, and — for the scattered
ping — its own stable device ID), any two phones that plug in the same
inputs get the same output, without ever needing to ask a server or each
other what the answer is. There is nothing to synchronize, no round trip,
no risk of "device A saw an old value" — there's no value to see; every
device *derives* it fresh, offline, and always arrives at the same place.

`test/determinism_test.dart` is the proof: it simulates several
independent "devices" that only share a trip ID and a date, and asserts
they compute bit-for-bit identical daily moments.

## The quiet window, in the trip's timezone

Every ping is placed inside a `QuietWindow` (default `09:00`-`21:00`)
measured against midnight **in the trip's timezone**
(`tripUtcOffset`), not the device's home timezone. A trip to Auckland
booked from a phone on US Pacific time still gets pings at 9am-9pm
Auckland time, not 9am-9pm Pacific time translated into some other part of
the Auckland day. This is deliberate: nobody should be pinged mid-flight
or at 3am local-to-the-trip because their phone still thinks in home time.

This package models a trip's timezone as a fixed UTC offset
(`Duration`), not a full IANA timezone. See "What this cannot do" below.

## The ceiling: two pings a day, hard maximum

`maxPingsPerDay` is `2`, and it's not just a documented convention —
`DayPings`, the type `tripSchedule()` returns one of per day, has exactly
two `DateTime` fields (`dailyMoment` and `scatteredPing`), not a
`List<DateTime>`. There is nowhere to `.add()` a third ping. Extending
this package to a third kind of ping requires deliberately widening that
type (and its tests), not just pushing onto a collection by accident.

## What must never change (read this before touching the hash)

The one property this package exists to guarantee is: **two people on the
same trip, on two different app versions, still land on the same daily
moment.** That only holds as long as the derivation is byte-for-byte
identical across every version that might be installed on the trip at the
same time. If it ever changes silently, two phones stop agreeing and the
"one shared moment" quietly becomes two different moments — with no error,
no crash, nothing that would show up in a stack trace. It would just look
like the feature is "randomly" a little broken for some people.

Concretely, changing **any** of the following after this package ships
breaks that guarantee for anyone whose two devices aren't on the exact
same app version mid-trip:

- The hash algorithm (`sha256` in `lib/src/stable_hash.dart`).
- The seed string format: field order, delimiters (`/`), casing, or the
  `trip_moments/v1/...` namespace prefixes.
- The date format (`YYYY-MM-DD` via `dateKey()`).
- How many digest bytes are read (currently the first 6 / 48 bits) or
  their byte order (big-endian).
- The divisor used to normalize into `[0, 1)` (`2^48 - 1`).
- The default `QuietWindow` (09:00-21:00) — for anyone not overriding it.
- How the window offset is combined with local midnight
  (`_placeInWindow` in `lib/src/daily_moment.dart`).

If any of these genuinely need to change, bump the namespace
(`trip_moments/v1/...` → `.../v2/...`) so the old and new derivations are
at least *guaranteed* to disagree everywhere, loudly and consistently,
rather than agreeing for some trips/dates and silently splitting for
others depending on hash-space luck. That's a real user-facing migration
(e.g. "everyone update before your next trip"), not a transparent one —
there is no way to make a change like this invisible.

`test/determinism_test.dart` and `test/stable_hash_test.dart` each pin a
regression value computed from the current implementation; a change to
any of the above will fail those tests immediately, which is the point.

### Why SHA-256 specifically

Dart's built-in `Object.hashCode` / `Object.hash()` are explicitly *not*
guaranteed stable across Dart versions, isolates, or even separate runs of
the same program — they exist for in-memory data structures like `HashMap`,
not for values you persist or need to reproduce elsewhere. SHA-256 is a
fully specified, versionless algorithm (`package:crypto`'s implementation
is a straightforward encoding of the FIPS 180-4 spec); its output for a
given input can never change, on any platform, in any future Dart SDK.

### Why only 48 bits of the digest

Dart compiled to JavaScript (web) represents `int` as a double, which can
only represent integers exactly up to `2^53`. Using the full 64-bit range
would work fine on the Dart VM/AOT but silently lose precision — and
therefore diverge from the VM's answer — if this package were ever used
on a web target. 48 bits stays exact on every backend while still giving
about 2.8 × 10^14 distinct buckets, far more resolution than a time-of-day
scheduling problem needs.

## What this cannot do

- **No true IANA timezones, no DST.** The trip's timezone is a fixed UTC
  offset for the whole trip. A trip that spans a DST transition, or that
  needs "wall clock 9am-9pm even as the offset itself changes," is not
  modeled — the app layer would need to supply the correct offset per day
  if that matters, or this package would need real timezone data
  (e.g. `package:timezone`) to support it properly.
- **No guaranteed non-collision, only overwhelming improbability.** Two
  devices getting the exact same scattered ping instant isn't structurally
  impossible, just as unlikely as a SHA-256 collision on two different
  inputs — astronomically unlikely, not proven impossible. Don't build
  logic elsewhere that assumes strict uniqueness is guaranteed.
- **No enforcement that a phone actually fires the notification.** This
  package hands the app a list of instants; whether the OS actually wakes
  the app and shows something (permissions, battery optimization, the
  device being off) is entirely outside this package's control.
- **No cross-device knowledge.** A device only ever computes its own
  scattered ping and the shared daily moment; it has no way to know what
  time other devices' scattered pings landed on, and this package doesn't
  try to give it one (by design — that's what would require a server).
- **No trip metadata.** This package doesn't know what a trip "is" beyond
  a string ID, a date, a UTC offset, and (optionally) a per-device ID. It
  doesn't validate that a trip ID is real, load timezones from anywhere, or
  know when a trip starts or ends — the app layer supplies all of that.

## API

```dart
import 'package:trip_moments/trip_moments.dart';

// The shared instant everyone on the trip agrees on for this date.
final moment = dailyMoment(
  tripId: 'trip-abc123',
  date: DateTime(2026, 9, 3),
  tripUtcOffset: const Duration(hours: 8), // the trip's timezone
);

// This device's own instant for the same date.
final ping = scatteredPing(
  tripId: 'trip-abc123',
  date: DateTime(2026, 9, 3),
  deviceId: myStableDeviceId,
  tripUtcOffset: const Duration(hours: 8),
);

// The whole remaining trip, in one offline pass.
final schedule = tripSchedule(
  tripId: 'trip-abc123',
  deviceId: myStableDeviceId,
  fromDate: DateTime.now(),
  toDate: tripEndDate,
  tripUtcOffset: const Duration(hours: 8),
);
for (final day in schedule) {
  // day.dailyMoment, day.scatteredPing — hand both to your local
  // notification scheduler and never call this package again until
  // tomorrow (or the next time the trip's date range changes).
}
```

All returned `DateTime`s are UTC instants (`.isUtc == true`); convert with
`.toLocal()` only for display, not for scheduling — the instant itself is
already correct regardless of what timezone the device happens to be in.

## Testing

```
dart test
```

- `test/determinism_test.dart` — the test that is the point of this
  package: independent "devices" agree exactly, given only a trip ID and
  a date.
- `test/distribution_test.dart` — daily moments spread across the window
  rather than clustering.
- `test/scattered_ping_test.dart` — different devices get different
  times; the same device reproduces its own time.
- `test/quiet_window_test.dart` — the window is honoured in the trip's
  timezone, including a trip whose timezone is far from the device's.
- `test/day_pings_ceiling_test.dart` — no day ever exceeds two pings.
- `test/trip_schedule_test.dart` — whole-trip scheduling behaviour.
- `test/stable_hash_test.dart` — the underlying hash-to-`[0,1)` helper.
