# photo_day_assignment

Decides which day of a trip a photo belongs to. Pure Dart — no Flutter, no
UI, no network, no image/EXIF decoding. You hand it metadata the app layer
already extracted; it hands back a day number, how it decided, and how much
to trust that decision.

This is meant to be the quiet backbone of the camera-roll import: it runs
silently, unattended, all trip long. If it puts a photo on the wrong day
silently, everything downstream (the Trail, the shared Pool, the finished
book) is wrong and nobody notices until it's too late to fix. So it never
guesses quietly — every result says exactly how sure it is, and a low-
confidence guess is always marked low.

## Why not just use the EXIF timestamp?

`DateTimeOriginal` in EXIF is a bare string like `2026:03:14 20:00:00` —
**no UTC offset, no zone name.** A photo taken at 20:00 in Tokyo and a photo
taken at 20:00 in London produce the identical string. If a trip's days are
defined in the trip's own timezone and you just parse that string and
compare it, a photo taken after the traveller changed timezones can land on
the wrong day — sometimes off by a full day, not just a few hours.

The correct chain, and the one this package implements, is:

```
GPS coordinate → timezone → interpret the EXIF local time in *that* zone
                                        → compare against the trip's day boundaries
```

## The degradation ladder

Implemented in this order, best evidence first. Every
[`PhotoDayAssignmentResult`](lib/src/result.dart) carries which rung produced
it (`method`) and how much to trust it (`confidence`), so the confirmation UI
can say "we placed this on Day 4 because of where it was taken" versus "we
guessed Day 4 from the date alone" — and the app always has enough
information to let the user override either.

| Rung | Condition | What happens | Confidence | Flagged for confirmation? |
|---|---|---|---|---|
| 1 | GPS present, resolves to a land timezone | EXIF local time interpreted in the **GPS-derived** zone | `high` | No |
| 2 | GPS absent, or present but unresolved (open ocean) | EXIF local time interpreted in the **trip's** zone | `medium` | Yes — this is exactly where a cross-timezone photo can land wrong |
| 3 | No EXIF timestamp at all | Falls back to the file's last-modified time | `low` | Always |
| — | Nothing usable (no EXIF, no file time) | `PhotoDayAssignmentOutcome.insufficientMetadata` — no rung applies | *(none)* | Always |
| — | A candidate instant (from any rung above) falls before day 1 or after the last day | `PhotoDayAssignmentOutcome.outsideTrip` — **never** clamped to day 1 or the last day | *(rung's own confidence)* | No — this is a confident exclusion, not an uncertain one |

**Rung 2 is the common case, not the exception.** Roughly 89% of
WhatsApp-forwarded photos have GPS stripped by the client before you ever
see them. This package is designed and tested with that as the normal path,
not an edge case.

## Quick example

```dart
import 'package:photo_day_assignment/photo_day_assignment.dart';

void main() {
  initializePhotoDayAssignment(); // loads the IANA tz database once

  final trip = TripDefinition(
    startDate: DateTime(2026, 3, 10),
    numberOfDays: 7,
    defaultTimeZoneName: 'Asia/Tokyo',
  );

  final result = assignPhotoToDay(
    trip: trip,
    photo: PhotoMetadata(
      exifLocalTimestamp: const LocalDateTime(
        year: 2026, month: 3, day: 14, hour: 20, minute: 0,
      ),
      gpsLatitude: 51.5074,   // London — the traveller has moved on
      gpsLongitude: -0.1278,
    ),
  );

  print(result.dayNumber);      // 6, correctly — not the day a naive
                                 // Tokyo-local read of "20:00" would imply
  print(result.method);         // PhotoDayAssignmentMethod.gpsTimezone
  print(result.confidence);     // PhotoDayAssignmentConfidence.high
  print(result.needsConfirmation); // false
  print(result.explanation);    // human-readable, safe to show in a debug view
}
```

`exifLocalTimestamp` is a [`LocalDateTime`](lib/src/local_date_time.dart), not
a `DateTime` — deliberately. EXIF carries no timezone, so a plain `DateTime`
would tempt you to call `.toUtc()` on it or compare it directly against
another instant, which is precisely the bug this package exists to prevent.
`LocalDateTime` only holds wall-clock digits; it can't become a real instant
until a zone is chosen for it, which is exactly what the ladder above does.

A trip whose own itinerary crosses timezones (not just a photo taken
somewhere unexpected) can give individual days their own zone:

```dart
final trip = TripDefinition(
  startDate: DateTime(2026, 6, 1),
  numberOfDays: 6,
  defaultTimeZoneName: 'America/New_York',
  timeZoneOverridesByDay: {4: 'America/Los_Angeles', 5: 'America/Los_Angeles', 6: 'America/Los_Angeles'},
);
```

Each day's midnight-to-midnight window is computed in *that day's own* zone.
`defaultTimeZoneName` remains "the trip's timezone" for rung 2 regardless of
overrides — see [What this cannot do](#what-this-cannot-do) for why that's a
deliberate simplification, not an oversight.

## Timezone lookup

Coordinate → timezone is done entirely offline with
[`timezone_finder`](https://pub.dev/packages/timezone_finder) (v0.2.0) on top
of [`timezone`](https://pub.dev/packages/timezone) (v0.11.1) for the IANA
zone rules themselves. No network call happens anywhere in this package, on
any platform — the app keeps working on a plane, which was the deciding
factor over a more "accurate" service-backed lookup.

- **Land boundary data:** the [Timezone Boundary
  Builder](https://github.com/evansiroky/timezone-boundary-builder) project
  (derived from OpenStreetMap), embedded release **`2026c`**
  (`timezone_finder.boundaryDataVersion` at runtime).
- **English zone names:** Unicode CLDR release **48**
  (`timezone_finder.cldrVersion` at runtime).
- **IANA zone rules:** the `timezone` package's `latest_all` tzdb variant —
  deliberately not the smaller default `latest` variant, which is missing
  106 of the boundary identifiers `timezone_finder`'s data references.
  `initializePhotoDayAssignment()` loads `latest_all` for you.
- **Size:** the embedded boundary dataset is a ~4 MB binary blob (compiled
  to ~4.3 MB of generated Dart source for native/VM targets); the `timezone`
  package's own `latest_all` database is a few hundred KB more. This is a
  one-time addition to the app's asset/binary size, not a per-lookup cost.
- **Currency:** timezone *boundaries* (the geographic polygons) update on
  Timezone Boundary Builder's own release cadence, roughly matching new
  IANA tzdb releases (several times a year, more after politically-driven
  changes). Bump the `timezone_finder` and `timezone` versions in
  `pubspec.yaml` periodically to pick up boundary corrections — this
  package does not check for updates itself.

## What this cannot do

This section matters more than the feature list above. Read it before
trusting a `high`-confidence result more than it deserves, and before being
surprised by a `medium` or `low` one.

- **It can't fix a camera clock that was already wrong.** Rung 1 corrects
  *which timezone* an EXIF wall-clock reading is interpreted in — it cannot
  tell that a camera's clock itself was never set, drifted, or was left on
  a timezone from three trips ago. Example: a phone whose clock silently
  drifted 40 minutes fast will place every photo it takes 40 minutes into
  the wrong slot, GPS or no GPS, and nothing here can detect that.
- **It can't resolve open ocean or far-offshore GPS to a timezone.**
  `timezone_finder`'s coastal buffer extends roughly 22 km offshore; a
  cruise-ship photo taken mid-Atlantic will not resolve to a land timezone
  and falls straight through to rung 2 (trip-timezone fallback), even
  though real GPS coordinates were present. This is intentional — inventing
  a maritime "Etc/GMT+n" zone guess is not more trustworthy than the
  fallback, so we don't pretend it is.
- **It is not survey-grade accurate near timezone borders.** The boundary
  polygons are a community-maintained OpenStreetMap derivative, not an
  authoritative legal dataset. A GPS point within a few hundred meters of a
  land timezone border can occasionally resolve to the neighboring zone.
  For almost every real trip this is irrelevant (you'd need to be standing
  on a state or national border); it matters if your product ever needs
  legal-grade timezone attribution, which this does not aim to provide.
- **Rung 2's "trip timezone" is a single assumption, even for a
  multi-zone trip.** `timeZoneOverridesByDay` changes which zone *day
  boundaries* are drawn in, but rung 2 (no GPS) always interprets the EXIF
  reading in `defaultTimeZoneName`, not whichever zone the traveller happens
  to be in that day. On a trip that changes zones, a GPS-stripped photo from
  the second leg can still be misplaced by rung 2 — the flag
  (`confidence: medium`, `needsConfirmation: true`) exists precisely so the
  app doesn't present that guess as settled.
- **A day boundary computed in one zone and the next day's boundary
  computed in a different zone can leave a gap (or overlap) in absolute
  time.** If day *N* uses Tokyo and day *N+1* uses London, day *N* ends at
  Tokyo midnight while day *N+1* starts at London midnight — points in
  between belong to neither window. A photo taken during, say, the flight
  between the two cities can come back as `outsideTrip` even though it
  happened during the trip. This is the same "refuse rather than guess"
  principle applied at a boundary, not a bug — but it means a multi-zone
  trip's in-transit photos may need manual placement.
- **It does not know the local time literally doesn't exist or is
  ambiguous around a DST transition.** Interpreting `02:30` on a
  spring-forward day, or an EXIF reading that occurs twice during a
  fall-back day, is delegated entirely to `package:timezone`'s `TZDateTime`
  resolution rules. This package does not add its own disambiguation or
  flag these instants specially — they are rare enough in real camera rolls
  that it wasn't worth the complexity, but a result for such a photo should
  be treated with the same skepticism as any `medium`/`low` result.
- **Boundary data can lag a real-world change.** Timezone boundaries do
  change (a country adopts or drops DST, a boundary is redrawn). The
  embedded `2026c` release is a snapshot; a boundary change after that
  release won't be reflected until this package's dependencies are bumped.
- **It never reads pixels or EXIF bytes.** Garbage in, garbage out — if the
  app layer hands this package a wrong GPS coordinate or a corrupted
  timestamp, it will confidently place the photo somewhere wrong. This
  package's job starts after metadata extraction, not before.
- **It doesn't decide anything about the UI.** `needsConfirmation` is a
  hint, not a policy — whether/how to surface it, and what an override
  looks like, is entirely up to the app layer.

## Testing

```
dart test
```

Covers: a photo squarely inside a day; the 23:50/00:10 midnight boundary;
the flagship timezone-crossing case (GPS gets it right, the trip-timezone
fallback gets it wrong, and the test asserts the two disagree); a
GPS-stripped photo; GPS present but unresolved (open ocean); a
file-time-only fallback with its confidence asserted `low`; a photo with no
usable metadata at all; a photo dated before and after the trip (never
clamped); and a trip whose own itinerary spans two timezones, with a second
assertion proving the per-day override is what changes the outcome.

No Flutter dependency — check `pubspec.yaml`.
