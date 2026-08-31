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
  if (day.uncertainty != null) {
    print('  unsure because: ${day.uncertainty!.explanation}');
  }
  for (final stop in day.stops) {
    print('  ${stop.isStarred ? '★' : ' '} ${stop.text}');
  }
}

for (final line in result.unplacedLines) {
  print('kept aside: ${line.sourceLine.text}');
  print('  because: ${line.reason.explanation}');
}
```

That's the entire public API: one function, `parseItinerary`, and the
result types it returns (`ParseResult`, `ParsedDay`, `Stop`, `StopKind`,
`AreaHint`, `AreaSource`, `SourceLine`, `UnplacedLine`, `UnplacedReason`,
`ParsedTime`, `DateCandidate`, `Confidence`, `DayUncertainty`).
`ItineraryParser.parse(...)` is a thin static-method alternative to
`parseItinerary(...)` for callers who prefer that style; they behave
identically.

`tripStartDate` is optional. Passing it lets the parser turn `Day N`
headers and year-less dates into real calendar dates. Without it, days
are still split out correctly — only the `date` field stays null where it
would otherwise have to be guessed.

`monthFirstNumericDates` (default false) flips how numeric slash dates
are read: `3/11` is 3 November by default, March 11th with the flag on.
It exists so a confirmation screen can offer "these are month-first
dates" as one tap that re-parses the whole paste consistently —
`ParseResult.firstAmbiguousNumericDate` hands back the first recognized
numeric date that would actually change under the flip — as the two
numbers the person wrote, so a confirmation screen can teach the flip with
their own date rather than an invented one. It is null when no date would
move, i.e. when the offer is not worth showing at all;
`ParseResult.hasAmbiguousNumericDates` is a getter over exactly that.

## The star rule

A stop is starred (`Stop.isStarred`) exactly when the parser found a
**definite** clock time on its line (`Stop.time != null`). That is the
*only* rule that creates a star anywhere in this package — there is no
separate "important" flag, no keyword list. If a stop needs to be
time-anchored in the app, it needs a time in the source text.

A *hedged* time deliberately does not count: `maybe around 3pm`,
`~7pm`, `7pm-ish`, `4pm?`, `2pm or 3pm` all leave the stop unstarred,
with `time` null (the hedged words stay in the stop's text — nothing is
rewritten). A star marks the one or two things a day with a real
consequence if missed; a starred guess would devalue every real star in
the trip. The rule errs on the side of not starring: a hedge word
anywhere in the same comma-separated clause before the time (`maybe`,
`around`, `about`, `roughly`, `approx`, `sometime`, `probably`,
`possibly`, `perhaps`, `hopefully`, `likely`, `might`, `circa`,
`ideally`, `tbc`, `tbd`, or a `~`), or `ish` / `?` / `or …` right after
it, suppresses the time entirely. A hedge in a *different* clause does
not: `Dinner at 7pm, maybe karaoke after` still stars the dinner.

## Stop kind and area (tap-to-Maps)

Every stop carries a `StopKind` (`place`, `areaHeading`, `mealLabel`, or
`note`) and, where the deterministic extractor could work one out, an
`AreaHint` — the neighbourhood/area text in force for that stop, plus an
`AreaSource` naming why (`travellerDeclared`, `travellerProximity`,
`inlineLocality`, `runningHeading`, `hotelPrefix`, `trainDestination`, or
`person`, the last reserved for an area the app's own editable-area seam
set rather than the parser). `area` is null when nothing in the text lets
the extractor say — sending nothing to a map is the correct behaviour
then, not a bug. This is the same "ask, not guess" posture as the star
rule and confidence: an area is only ever attached when the source text
actually supports it.

### The gazetteer (phase 2, the C10 validator)

`parseItinerary` takes an optional `gazetteer` (an `AreaGazetteer`), and
**`null` is a supported mode forever, not a stub**: with no gazetteer the
extractor behaves exactly as phase 1 did, and the C7t ground-truth floors
in `test/area_ground_truth_test.dart` are pinned without one precisely so
that stays true. Given one, a candidate area drawn from a *vocabulary run*
must also be a real place name before it may become an area — which is
what stops a menu word ('UNAGI', 'UDON') being sent to a map. The
traveller's own in-tail wording ('Art & Eats in Le Marais') is trusted
without validation, because it is a statement rather than an inference.

`SortedListAreaGazetteer` is the shipped implementation: a sorted name
list searched by bisection, built from already-normalised text through
`SortedListAreaGazetteer.fromAssetTexts`. **This package never reads a
file or an asset** — inflating the bytes is the caller's business, which
is what keeps it dependency-free. In Cairn the assets are built by
`tool/build_area_gazetteer.dart` from the GeoNames dumps and read once,
on import only, by `lib/app_state/area_gazetteer_loader.dart`.

Names on both sides go through this package's own `areaTokens`, so the
builder and the lookup share one normaliser. That matters more than it
looks: the asset was frozen against Python's NFD in the measurement lab,
so `area_words.dart`'s decomposition map has to spell the same
macrons, breves and carons the dumps carry, or a name is built one way
and looked up another and simply never matches.

`placesOnLine(stop)` splits a stop's `placeText` on `/`, `,`, `+`, `&`,
and `;` into the individual place names a multi-place line named, for a
caller that wants to offer more than one Maps query per line.

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

### The cause, not just the level

A confirmation screen that varies its copy by *why* a day is doubtful —
"which Monday?" reads differently from "found the day, nothing in it" —
should not have to re-parse the header text to find out. So every day
below `high` also carries `ParsedDay.uncertainty`, a `DayUncertainty`
naming the cause (`weekdayWithoutDate`, `dateWithoutYear`,
`barePlaceName`, `noStops`, `headerlessBlock`), and each cause carries a
person-showable `explanation` sentence stating what the parser saw and
what it refused to guess. `uncertainty` is null exactly when the day's
confidence is `high`.

When a header names a weekday (`Monday`, `Mon 3 Nov`), the ISO weekday
it named is exposed as `ParsedDay.headerWeekday` — for a
weekday-without-date day this is the only structured record of what the
plan called the day, and it lets the UI check the named weekday against
whatever date the day would land on.

A leading weekday may be followed by a comma, and the day and the month
may come in either order after it: `Mon 3 Nov`, `Sat, Jun 14th`,
`Sat Jun 14` and `Saturday, June 14 2027` all read as dated headers,
with or without a `- Kyoto` place trailing a separator. That is
the `ddd, MMM Do` family printed itineraries (Wanderlog among them) use.

### A date in a day's own title

`Day 1 - Tokyo, 14 June` is a `Day N` header, and a `Day N` header takes
its date from where the day sits in the trip, not from a fragment in its
title. The parser will not bind that fragment — but it will not swallow
it into the place name either (which is what it used to do, leaving a day
that read "date open" beside a title that said 14 June).

The fragment is lifted out of `ParsedDay.place` and reported as
`ParsedDay.dateCandidate`, a `DateCandidate` carrying the day, the month,
the year *if the title spelled one*, and the fragment exactly as written.
It is a suggestion for the confirmation screen to offer in one tap, never
a date the parser chose: `DateCandidate.resolved` is null whenever the
title named no year, because this package does not guess years. A day can
carry both a bound `date` and a candidate that disagrees with it; only
the person can settle that.

Only shapes naming a **day and a month** qualify (`14 June`, `June 14`,
`14/6`, `2027-06-20`), and the month word has to be a real month, so
`Day 6 - 5 temples` finds nothing. A numeric candidate follows
`monthFirstNumericDates` exactly as a numeric header does.

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

- **A bare place header is judged by shape, in any script.** The word test
  is Unicode-aware (`unicode: true` and property escapes, not widened
  character ranges), so `München`, `Kraków`, `Αθήνα`, `Москва`, `京都`, `서울` and
  `กรุงเทพ` all read as headers. A word counts when it opens with an
  uppercase letter (`\p{Lu}`/`\p{Lt}`), or when it is written entirely in a
  script that *has* no letter case (`\p{Lo}` — CJK, kana, hangul, Thai,
  Arabic, Hebrew, the Indic scripts), where an uncapitalized word is what a
  place name looks like. Two length bounds stand in for the capital a
  caseless word cannot show: such a word may be at most 16 code points, since
  a script written without spaces puts a whole sentence in one "word"; and a
  line offering no capital anywhere may be at most 3 words rather than 5.
  Lowercase Latin, Greek or Cyrillic prose is still refused — those letters
  are `\p{Ll}`, not `\p{Lo}` — as are bullets, digits, times and long lines,
  exactly as before.

- **It cannot resolve a date that has no year and no `tripStartDate`.**
  `3 November` or `Nov 3` parse as a date-shaped header, but `date` stays
  null until you supply `tripStartDate` for the parser to infer the year
  against. It never guesses a year.

- **It cannot tell which calendar "Monday" a bare weekday name means.**
  `Monday` on its own is recognized as a header (so the day still gets
  split out), but its `date` is always null — the parser will not guess
  which occurrence of Monday you meant, even with `tripStartDate` given.

- **It cannot tell day-first from month-first numeric dates by itself.**
  There is no locale detection: `3/11` is read as 3 November unless the
  caller passes `monthFirstNumericDates: true`, in which case the whole
  paste is read month-first. The parser does flag when the choice
  mattered (`ParseResult.hasAmbiguousNumericDates`), and a numeric date
  that is only valid one way round (`25/12`) is read that way regardless
  of the setting — but deciding which dialect a genuinely ambiguous paste
  speaks is the user's call, made once for the whole paste.

- **It cannot read a line that names two dates as a day.** A range like
  `Sat, Jun 14th — Wed, Jun 18th` names no single day, so the weekday-comma
  and weekday-then-month-day shapes refuse it rather than bind its first
  date and keep the second as a place name; the line falls through as a
  stop or an unplaced line the person still sees. The test is the shape of
  the trailing text, so a real place whose name opens with a month-day run
  (`… — May 1 Museum`) is refused the same way — mis-binding a spurious
  day is the worse failure of the two.

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

- **The area extractor can attach the wrong running area.** It tracks one
  "area in force" per day from headers and traveller wording, so a stop
  that is actually a branch of a chain located outside that running area
  (a coffee chain, a department store) can inherit the wrong
  neighbourhood — this is a known, pinned limitation
  (`test/area_ground_truth_test.dart`'s "known failures are documented"),
  not something a caller should silently trust for every stop.

- **Nothing is ever silently dropped, but "unplaced" isn't "wrong."**
  Every line the parser didn't turn into a header or a stop shows up in
  `ParseResult.unplacedLines` with an `UnplacedReason` whose
  `explanation` is a sentence written to be shown to the person — what
  the parser saw on that line, stated so they can check it against their
  own paste. A line ending up there means the parser wasn't confident,
  not that it necessarily made a mistake — always let the user see and,
  if needed, place it manually.

## Testing

```
dart test
```

`test/fixtures/` holds golden-file test cases: each `<name>.input.txt` is
a realistic paste, each `<name>.expected.json` is the exact parse it must
produce, and an optional `<name>.meta.json` supplies the `tripStartDate`
used for that fixture. A change that alters parsing behavior will fail
one of these loudly rather than silently drifting — if the new output is
actually correct, regenerate with `dart run tool/regen_goldens.dart` and
review the diff line by line before committing; the goldens are the spec,
not a cache.
