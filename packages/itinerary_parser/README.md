# itinerary_parser

A deterministic, offline parser that turns a block of pasted free text —
a rough trip plan copied out of Notes, a WhatsApp chat, an email — into
structured days and stops.

Pure Dart. No Flutter dependency, no network calls, no model calls. It
works on a plane, costs nothing to run, and always returns the same
output for the same input.

## Why deterministic, not an LLM

This is a deliberate choice, not a stopgap. A model call would make this
package non-deterministic, untestable with golden files, dependent on
network and API cost, and confidently wrong in ways that are hard to
predict. A parser that is right most of the time and *knows which lines
it is unsure about* is more useful here than one that is right more
often but gives no signal about which parts to double-check — because the
user reviews and corrects the result before the trip starts anyway. This
package is built to **ask, not guess**: see [`Confidence`](#confidence)
below.

## Usage

```dart
import 'package:itinerary_parser/itinerary_parser.dart';

final result = parseItinerary(pastedText, tripStartDate: DateTime(2026, 11, 3));

for (final day in result.days) {
  print('${day.date} — ${day.place} (${day.confidence.name})');
  for (final stop in day.stops) {
    print('  ${stop.isStarred ? '★' : ' '} ${stop.text}');
  }
}

for (final line in result.unplacedLines) {
  print('could not place: ${line.sourceLine.text} (${line.reason})');
}
```

That's the entire public API: one function, `parseItinerary`, and the
result types it returns (`ParseResult`, `ParsedDay`, `Stop`, `SourceLine`,
`UnplacedLine`, `ParsedTime`, `Confidence`). `ItineraryParser.parse(...)`
is a thin static-method alternative to `parseItinerary(...)` for callers
who prefer that style; they behave identically.

`tripStartDate` is optional. Passing it lets the parser turn `Day N`
headers and year-less dates into real calendar dates. Without it, days
are still split out correctly — only the `date` field stays null where it
would otherwise have to be guessed.

## The star rule

A stop is starred (`Stop.isStarred`) exactly when the parser found a
clock time on its line (`Stop.time != null`). That is the *only* rule
that creates a star anywhere in this package — there is no separate
"important" flag, no keyword list. If a stop needs to be time-anchored in
the app, it needs a time in the source text.

## Confidence

Every day, and the result as a whole, carries a [`Confidence`]:
`high`, `medium`, or `low`. This is meant to drive the confirmation
screen, not just decorate it:

- **`high`** — the source line was unambiguous: an explicit `Day N`
  header (even with no date resolved), or a date header that resolved to
  a full calendar date. Pre-fill and let the user glance past it.
- **`medium`** — the parser had to infer structure from a weaker signal,
  or resolved the structure but not the date: a bare place name acting
  as a header, a weekday with no day/month, a date missing a year with
  no `tripStartDate` to resolve it against. Pre-fill, but the UI should
  draw the user's eye to it rather than let it slide by.
- **`low`** — the parser fell back to a guess it doesn't trust: no
  headers found anywhere in the whole paste (so it split on blank lines
  instead), or a day ended up with zero stops. Do not let the user skip
  past this without looking.

`ParseResult.overallConfidence` is the weakest signal across the whole
parse — it also drops when a large share of lines ended up unplaced,
even if every day that *was* found is individually solid.

## What this parser cannot do

This list is more important than the feature list above. Read it before
building UI on top of this package.

- **It cannot read your mind about ambiguous short lines.** A bare line
  like `Kyoto` is treated as a day header only when the *next* line looks
  like a list item (bulleted, or carries a time). A short capitalized
  line with no such follow-up — `Kinkaku-ji` on its own, say — is kept as
  a stop, not promoted to a header. When nothing in the whole paste ever
  looks like a header, the parser falls back to one day per blank-line
  block and marks everything low confidence rather than guess which
  lines were meant as headers.

- **It cannot resolve a date that has no year and no `tripStartDate`.**
  `3 November` or `Nov 3` parse as a date-shaped header, but `date` stays
  null until you supply `tripStartDate` for the parser to infer the year
  against. It never guesses a year.

- **It cannot tell which calendar "Monday" a bare weekday name means.**
  `Monday` on its own is recognized as a header (so the day still gets
  split out), but its `date` is always null — the parser will not guess
  which occurrence of Monday you meant, even with `tripStartDate` given.

- **It reads numeric dates as day/month, not month/day.** `3/11` means
  3 November, not March 11th. There is no locale detection; if your
  source text uses US-style month/day dates, they will be misread.

- **It cannot distinguish a genuine stop from chat banter that happens to
  contain a link.** In a WhatsApp-style paste, `check this out
  https://...` has its URL stripped and the remaining text kept as a
  stop, the same as a real itinerary line would be. It has no way to
  tell "this is a plan" from "this is commentary" — that judgment is left
  to the confirmation screen.

- **It cannot recognize a bare 4-digit time in the 1900-2099 range.**
  `1900` as a military time (7pm) is indistinguishable from a spelled-out
  year like `1900` or `2026`, and pasted trip text very often contains a
  real calendar year. The parser treats any bare 4-digit number in that
  range as a year, never as a time. Every other bare military time
  (`0900`, `1640`, `2145`, ...) is recognized normally — write times with
  a colon (`19:00`) if you need one in that specific hour range parsed
  correctly.

- **It only takes the start of a time range.** `14:00-16:00` becomes a
  single stop starred at `14:00`; the end time is discarded entirely,
  it is not modeled anywhere in the output.

- **It does not understand trip semantics.** No geocoding, no place
  lookup, no notion of travel time between stops, no duplicate detection
  across days, no flight/hotel-specific parsing beyond recognizing common
  booking-reference lines as noise to leave out. It parses *structure*
  from text, nothing more.

- **It does not translate or normalize text.** Stop text is kept exactly
  as pasted, including mixed languages and non-ASCII characters. It will
  not fix capitalization, spelling, or word order in what it keeps.

- **Nothing is ever silently dropped, but "unplaced" isn't "wrong."**
  Every line the parser didn't turn into a header or a stop shows up in
  `ParseResult.unplacedLines` with a reason. A line ending up there means
  the parser wasn't confident, not that it necessarily made a mistake —
  always let the user see and, if needed, place it manually.

## Testing

```
dart test
```

`test/fixtures/` holds golden-file test cases: each `<name>.input.txt` is
a realistic paste, each `<name>.expected.json` is the exact parse it must
produce, and an optional `<name>.meta.json` supplies the `tripStartDate`
used for that fixture. A change that alters parsing behavior will fail
one of these loudly rather than silently drifting — if the new output is
actually correct, update the matching `.expected.json` deliberately, by
hand, after checking it.
