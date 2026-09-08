/// Does this line name a place at all?
///
/// The question the tap-to-Maps affordance turns on. `Free morning`,
/// `LUNCH: OUTLET` and `Shopping / CHILLING / EVERYTHING` are real lines from
/// the captain's own plan, and no parser on earth will find a place in them:
/// a maps search for "OUTLET" opens rubbish, and a button that opens rubbish
/// is what makes an app feel broken. A missing button is honest.
///
/// The rule is one sentence: **a line names no place when every content word
/// it has is a common word.** A common word is one of the frozen lists in
/// `area_words.dart` — the generic connectives, the venue-generic nouns
/// (`station`, `market`, `mall`), the furniture (`morning`, `shopping`,
/// `free`) — plus [placelessWords] below.
///
/// [placelessWords] is deliberately a *separate* list rather than an addition
/// to those. The lists in `area_words.dart` drive the area engine, and their
/// header says plainly that editing one is a re-measurement event.
///
/// This one is now a re-measurement event too, and it was not always. The
/// area engine asks [namesNoPlace] of a heading it is about to seed a day
/// from, because a run through the anchor vocabulary is an inference and an
/// inference has to survive the question the tap rule already asks of a stop
/// line: `## Day 4: Local Gems` runs `local`, and `local` names no place on
/// a stop line or in a heading. So a word added below withholds a maps
/// button *and* can withhold an area. Measure both.
library;

import 'area_words.dart';

final RegExp _anyLetterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Common words this corpus proves are not places, kept apart from the area
/// engine's frozen lists.
///
/// Every entry is a word that actually appears as a whole stop, or as a whole
/// meal payload, in the measured corpus. `outlet` is the one that matters:
/// `GOTEMBA PREMIUM OUTLET` names a place because `GOTEMBA` does, and
/// `LUNCH: OUTLET` names nothing because `OUTLET` is all it says.
const Set<String> placelessWords = {
  'outlet',
  'outlets',
  'chill',
  'chilling',
  'everything',
  'anything',
  'something',
  'whatever',
  'somewhere',
  'anywhere',
  'nearby',
  'local',
  'random',
  'explore',
  'exploring',
  'wander',
  'wandering',
  'relax',
  'relaxing',
  'sightseeing',
  'departures',
  'arrivals',
  'pack',
  'packing',
  'sleep',
  'nap',
  'onsen',
  'spa',
  'gym',
  'laundry',
  'groceries',
  'grocery',
  'souvenir',
  'souvenirs',
  'snacking',
  'eat',
  'eating',
  'dine',
  'dining',
  'tbd',
  'tba',
  'none',
};

/// True when [text] carries no word that could name a specific place.
///
/// Venue-generic words count as common on their own — a bare `Station` or
/// `Market` is a category, not a destination — but stop counting the moment
/// any other word joins them, which is why `Nishiki Market` and
/// `Tokyo Station` are places and `Market` is not.
bool namesNoPlace(String text) {
  final content = [
    for (final w in areaTokens(text))
      if (!genericStopWords.contains(w)) w,
  ];
  if (content.isEmpty) {
    // No tokens and yet letters on the line means the tokenizer cannot read
    // this script, not that the line is empty. Withholding a tap on evidence
    // we do not have is the wrong way to be wrong: a Japanese or Korean stop
    // name is exactly the one a maps app is most needed for. Digits are the
    // same argument once removed — `711` is a shop with a number for a name,
    // and only a line with neither letter nor digit (a markdown fence, a
    // table rule) is genuinely nothing.
    return !_anyLetterOrDigit.hasMatch(text);
  }
  return content.every(
    (w) =>
        furnitureWords.contains(w) ||
        venueGenericWords.contains(w) ||
        placelessWords.contains(w),
  );
}
