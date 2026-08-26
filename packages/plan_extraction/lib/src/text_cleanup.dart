// The cleanup every page-shaped format runs its lines through before the
// paste box sees them. It is deliberately, almost pedantically conservative,
// and the reason is measured rather than aesthetic (the import plan's risk 3):
// `parseItinerary` drops the whole read's confidence once more than 15% of
// content lines go unplaced, so a footer-heavy PDF can read as doubtful even
// when every day parsed perfectly. Stripping page furniture buys that budget
// back.
//
// The bar for stripping a line is *provable repetition*, never a guess at
// meaning:
//
//   - A line is furniture if the same text sits at a page edge on at least
//     three distinct pages **and** on at least half the pages. One
//     coincidence ("Lunch" three times in a ten-day plan) cannot clear that,
//     and a running header cannot fail it.
//   - "The same text" is blind to digits, so a footer's page number does not
//     disguise it — which means `Day 1` and `Day 2` look identical too. A
//     line therefore has to read as a *phrase* (two words, eight letters)
//     before it can be furniture at all. Without that guard a plan printed
//     one day to a page would lose every day header.
//   - Only the edge occurrences go. The same words in the middle of a page
//     are somebody's stop, and stay.
//   - A page number goes only when it is a number a page could actually be.
//     A bare `1900` is a year, a price or a room number, and the guard is
//     what keeps the garbled fixture's standalone `1900` out of the
//     furniture pile; a bare `14/6` or `3-11` is a date, and a date header
//     is the single line the parser most needs, so the numerator has to be a
//     page and the denominator has to be the page count before the pair form
//     counts. Only the forms that literally *say* `page` need no guard.
//   - The Wanderlog print furniture named in the plan's §4 — travel-time
//     dividers, star ratings, `View on map` — is matched by shape, not by
//     position, because those lines sit between stops rather than at a page
//     edge.
//
// Two rules hold above all of it. **Line order is preserved**, and **lines
// are never joined.** A wrongly joined line corrupts a stop silently; an
// unjoined one is merely two stops the person can fix in the editor, in a
// box they are looking at anyway. Address and phone lines are kept for the
// same reason — they are real information, and the parser already files what
// it cannot place into the visible set-aside.
library;

/// Turns the per-page lines of a paginated document into the one text the
/// paste box shows. [pages] is one list of lines per page, in page order.
String cleanPaginatedText(List<List<String>> pages) {
  final normalized = [
    for (final page in pages) [for (final line in page) normalizeLine(line)],
  ];
  final furniture = _repeatedFurniture(normalized);
  final pageCount = normalized.length;

  final out = <String>[];
  for (final page in normalized) {
    final kept = <String>[];
    final edges = _edgeIndices(page);
    for (var i = 0; i < page.length; i++) {
      final line = page[i];
      if (line.isEmpty) {
        kept.add('');
        continue;
      }
      final atEdge = edges.contains(i);
      if (atEdge && furniture.contains(_furnitureKey(line))) continue;
      if (atEdge && _isPageNumber(line, pageCount)) continue;
      if (_isPrintFurniture(line)) continue;
      kept.add(line);
    }
    if (kept.any((l) => l.isNotEmpty)) {
      if (out.isNotEmpty) out.add('');
      out.addAll(kept);
    }
  }
  return _collapseBlanks(out).join('\n');
}

/// Whitespace and invisible-character repair, applied to every line of every
/// paginated format. PDF text layers are full of non-breaking spaces where a
/// person typed an ordinary one, and of zero-width joiners left over from
/// font shaping; both would reach the parser as characters that are not the
/// space and not the letter they look like.
String normalizeLine(String line) {
  final repaired = line
      .replaceAll(' ', ' ') // non-breaking space
      .replaceAll(' ', ' ') // figure space
      .replaceAll(' ', ' ') // narrow no-break space
      .replaceAll('﻿', '') // zero-width no-break space / stray BOM
      .replaceAll('​', '') // zero-width space
      .replaceAll('‌', '')
      .replaceAll('‍', '')
      .replaceAll('­', ''); // soft hyphen
  return repaired.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

// ---------------------------------------------------------------------------
// Repeated furniture
// ---------------------------------------------------------------------------

/// How many non-empty lines at each end of a page count as its edge. Running
/// headers and footers live here; a stop does too, which is why edge position
/// alone strips nothing — it only makes a line *eligible* to be judged
/// repeated.
const int _edgeDepth = 2;

/// The minimum number of distinct pages a line must head or foot before it is
/// called furniture, from the plan's risk 3.
const int _minRepeats = 3;

Set<int> _edgeIndices(List<String> page) {
  final filled = <int>[
    for (var i = 0; i < page.length; i++)
      if (page[i].isNotEmpty) i,
  ];
  return {...filled.take(_edgeDepth), ...filled.reversed.take(_edgeDepth)};
}

/// Case- and punctuation-insensitive, and blind to the digits inside a line,
/// so `Kyoto trip — page 3 of 9` and `Kyoto trip — page 4 of 9` are
/// recognised as one footer wearing two page numbers.
String _furnitureKey(String line) => line
    .toLowerCase()
    .replaceAll(RegExp(r'\d+'), '#')
    .replaceAll(RegExp(r'[^a-z#]+'), ' ')
    .trim();

/// Being blind to digits is what makes the key useful and also what makes it
/// dangerous: `Day 1` and `Day 2` share a key too, and a plan that prints one
/// day per page would lose every day header to a rule meant for footers. So a
/// key only counts as furniture if what is left after the digits go still
/// reads as a *phrase* — two words and eight letters. A running header is a
/// phrase. A day marker is a word and a number.
bool _couldBeFurniture(String key) {
  final words = key.split(' ').where((w) => w.contains(RegExp('[a-z]')));
  if (words.length < 2) return false;
  return words.fold<int>(0, (n, w) => n + w.length) >= 8;
}

Set<String> _repeatedFurniture(List<List<String>> pages) {
  if (pages.length < _minRepeats) return const {};
  final pagesPerKey = <String, Set<int>>{};
  for (var p = 0; p < pages.length; p++) {
    final page = pages[p];
    for (final i in _edgeIndices(page)) {
      final line = page[i];
      if (line.isEmpty) continue;
      final key = _furnitureKey(line);
      if (!_couldBeFurniture(key)) continue;
      pagesPerKey.putIfAbsent(key, () => <int>{}).add(p);
    }
  }
  final half = (pages.length + 1) ~/ 2;
  return {
    for (final entry in pagesPerKey.entries)
      if (entry.value.length >= _minRepeats && entry.value.length >= half)
        entry.key,
  };
}

// ---------------------------------------------------------------------------
// Page numbers
// ---------------------------------------------------------------------------

final RegExp _bareNumber = RegExp(r'^[-–—\s]*(\d{1,4})[-–—\s.]*$');
final RegExp _pagedNumberOfNumber = RegExp(
  r'^page\s*(\d{1,4})\s*(?:/|of|—|–|-)\s*(\d{1,4})$',
  caseSensitive: false,
);
final RegExp _bareNumberOfNumber = RegExp(
  r'^(\d{1,4})\s*(?:/|of|—|–|-)\s*(\d{1,4})$',
  caseSensitive: false,
);
final RegExp _pageWord = RegExp(r'^page\s*(\d{1,4})$', caseSensitive: false);

/// A page number, and only a page number. Every form that does not say the
/// word `page` carries a `<= pageCount` guard, because the shapes a folio
/// wears are also the shapes a year, a price and — the one that matters most
/// — a numeric date header wear. `14/6` and `3-11` are dates on any print
/// shorter than fourteen pages; Chrome's real footer is `n/9` on a nine-page
/// export, so demanding the second number *be* the page count strips the
/// footer and leaves the date alone.
bool _isPageNumber(String line, int pageCount) {
  if (_pagedNumberOfNumber.hasMatch(line)) return true;
  if (_pageWord.hasMatch(line)) return true;
  final pair = _bareNumberOfNumber.firstMatch(line);
  if (pair != null) {
    final folio = int.tryParse(pair.group(1)!);
    final total = int.tryParse(pair.group(2)!);
    return folio != null &&
        total != null &&
        total == pageCount &&
        folio >= 1 &&
        folio <= pageCount;
  }
  final bare = _bareNumber.firstMatch(line);
  if (bare == null) return false;
  final value = int.tryParse(bare.group(1)!);
  return value != null && value >= 1 && value <= pageCount;
}

// ---------------------------------------------------------------------------
// Print furniture with a shape of its own (the plan's §4, Wanderlog)
// ---------------------------------------------------------------------------

/// `10 min · 3.7 mi`, `1 hr 5 min • 84 km` — the travel-time divider
/// Wanderlog prints between two stops. A duration, a middle dot, a distance,
/// and nothing else on the line.
final RegExp _travelDivider = RegExp(
  r'^\d+\s*(?:h|hr|hrs|hour|hours|min|mins|minute|minutes)\b[^·•]*[·•]\s*'
  r'[\d.,]+\s*(?:mi|mile|miles|km|kms|kilometre|kilometres|kilometer|kilometers|m|ft)\.?$',
  caseSensitive: false,
);

/// A ratings line off a public Wanderlog guide page: `★★★★½ 4.5 (28336)`,
/// `4.5 · 1,204 Google reviews`. The chip always carries the rating as a
/// number, and demanding that number is what keeps a starred stop somebody
/// wrote — `★ Fushimi Inari at dawn`, `⭐ Asahiyama Zoo` — out of the rule:
/// those are short, so the sentence guard below never sees them.
final RegExp _ratingLine = RegExp(
  r'^(?:[★☆✩⭐½]+\s*[\d.,]+.*|.*\bgoogle reviews?\b.*)$',
  caseSensitive: false,
);

final RegExp _mapButton = RegExp(
  r'^(?:view on map|open in google maps|directions|get directions)$',
  caseSensitive: false,
);

bool _isPrintFurniture(String line) =>
    _travelDivider.hasMatch(line) ||
    _mapButton.hasMatch(line) ||
    (_ratingLine.hasMatch(line) && !_looksLikeSomebodysWords(line));

/// A guard on the ratings pattern alone, which is the one broad rule here:
/// a long line is a sentence somebody wrote, not a ratings chip, even if a
/// star crept into it.
bool _looksLikeSomebodysWords(String line) => line.length > 60;

// ---------------------------------------------------------------------------

List<String> _collapseBlanks(List<String> lines) {
  final out = <String>[];
  for (final line in lines) {
    if (line.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
    out.add(line);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out;
}
