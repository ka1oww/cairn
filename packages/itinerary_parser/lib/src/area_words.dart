/// Frozen word lists and tokenizer for the area engine.
///
/// Ported verbatim from `lab/scorer.py` lines 26-153. Editing any list is
/// a re-measurement event — re-run the GT harness and record the delta.
library;

// ---------------------------------------------------------------- word lists

const Set<String> genericStopWords = {
  'the',
  'and',
  'for',
  'from',
  'with',
  'of',
  'or',
  'at',
  'in',
  'to',
  'a',
  'an',
  'by',
  'near',
  'opposite',
  'beside',
  'next',
  'via',
  'stn',
  'sta',
  'etc',
  'around',
  'about',
  'approx',
  'jr',
  'only',
};

const Set<String> venueGenericWords = {
  'station',
  'park',
  'temple',
  'shrine',
  'castle',
  'museum',
  'market',
  'garden',
  'gardens',
  'bridge',
  'tower',
  'street',
  'st',
  'ave',
  'avenue',
  'river',
  'lake',
  'port',
  'airport',
  'terminal',
  'mall',
  'plaza',
  'center',
  'centre',
  'hall',
  'palace',
  'gate',
  'falls',
  'waterfall',
  'valley',
  'village',
  'beach',
  'bay',
  'hill',
  'hills',
  'mountain',
  'mount',
  'mt',
  'line',
  'exit',
  'hotel',
  'hostel',
  'ryokan',
  'guesthouse',
  'inn',
  'stay',
  'city',
  'shop',
  'store',
  'cafe',
  'building',
  'gondola',
  'memorial',
  'water',
  'pier',
  'wharf',
  'ropeway',
  'gorge',
  'ravine',
  'canyon',
  'crossing',
  'corner',
  'cave',
  'island',
  'resort',
  'alley',
  'lane',
};

const Set<String> transitLeadWords = {
  'walk',
  'take',
  'board',
  'ride',
  'bus',
  'train',
  'taxi',
  'transfer',
  'catch',
  'head',
  'fly',
  'drive',
  'go',
  'start',
  'from',
  'continue',
};

const Set<String> monthWeekdayWords = {
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
};

const Set<String> furnitureWords = {
  'morning',
  'afternoon',
  'evening',
  'night',
  'noon',
  'midday',
  'late',
  'early',
  'lunch',
  'dinner',
  'breakfast',
  'brunch',
  'supper',
  'snack',
  'snacks',
  'dessert',
  'desert',
  'drinks',
  'drink',
  'arrival',
  'departure',
  'arrive',
  'depart',
  'day',
  'days',
  'trip',
  'trips',
  'overview',
  'highlights',
  'highlight',
  'itinerary',
  'notes',
  'note',
  'tips',
  'tip',
  'practical',
  'practicals',
  'transport',
  'transportation',
  'weather',
  'apps',
  'currency',
  'budget',
  'budgeting',
  'expenses',
  'template',
  'options',
  'option',
  'optional',
  'route',
  'routes',
  'walk',
  'walking',
  'bus',
  'train',
  'transfer',
  'stores',
  'store',
  'shops',
  'shop',
  'shopping',
  'misc',
  'essentials',
  'extras',
  'food',
  'eats',
  'musts',
  'must',
  'tries',
  'schedule',
  'summary',
  'checklist',
  'packing',
  'costs',
  'cost',
  'total',
  'free',
  'rest',
  'flex',
  'flexible',
  'return',
  'back',
  'checkout',
  'check',
  'out',
  'info',
  'min',
  'mins',
  'minute',
  'minutes',
  'hrs',
  'hour',
  'hours',
  'drive',
  'taxi',
  'ferry',
  'cab',
  'move',
  'cash',
  'card',
  'cards',
  'yen',
  'won',
  'euro',
  'euros',
  'fee',
  'fees',
  'admission',
  'entry',
  'ticket',
  'tickets',
  'reservation',
  'reservations',
  'booking',
  'closed',
  'open',
};

const Set<String> mealPrefixWords = {
  'breakfast',
  'lunch',
  'dinner',
  'brunch',
  'supper',
  'snack',
  'snacks',
  'dessert',
  'desert',
  'coffee',
  'drinks',
  'drink',
  'cafe',
  'food',
};

// ---------------------------------------------------------------- regex constants

final RegExp nearXRegExp = RegExp(
  r'\b(?:near|opposite|beside|next\s+to|in\s+front\s+of|across\s+from)\s+([^),;.\n]+)',
  caseSensitive: false,
);
final RegExp fromXRegExp = RegExp(
  r'\b\d+\s*min(?:ute)?s?\s*(?:walk\s*)?from\s+([^),;.\n]+)',
  caseSensitive: false,
);
final RegExp suggRegExp = RegExp(
  r'\bsuggested\s+area:?\s*([^);.\n]+)',
  caseSensitive: false,
);
final RegExp stationRegExp = RegExp(
  r"([A-Za-z][A-Za-z'’‘’\-]*)[ \t]+(?:STATION|STN|Station|Sta\.?)\b",
);
final RegExp hotelWordRegExp = RegExp(
  r'\b(?:hotel|hostel|ryokan|guesthouse|inn)\b',
  caseSensitive: false,
);
final RegExp hotelPrefixRegExp = RegExp(
  r"^\s*([A-Z][A-Za-z'’\-]*)[ \t]+HOTEL\b",
);

// ---------------------------------------------------------------- tokenizer

/// Strips diacritics via NFD decomposition — drops combining marks.
/// In Dart we do this manually over code units since dart:core has no
/// unicodedata.normalize. We handle the common Latin diacritics by
/// decomposing via a lookup table for the corpus's actual characters.
String stripDiacritics(String s) {
  // For the corpus we only need to handle the characters that actually
  // appear. The scorer uses NFD + Mn filter; we implement a minimal
  // equivalent that covers the test cases (e.g. café, naïve, etc).
  // We use a manual map for combining marks stripping via codePoint
  // decomposition for characters in the Latin-1 supplement range.
  final buf = StringBuffer();
  for (final cp in s.runes) {
    final ch = String.fromCharCode(cp);
    // Decompose common precomposed characters
    final decomposed = _decomposeMap[ch];
    if (decomposed != null) {
      for (final d in decomposed.runes) {
        if (!_isCombining(d)) buf.writeCharCode(d);
      }
    } else if (!_isCombining(cp)) {
      buf.writeCharCode(cp);
    }
  }
  return buf.toString();
}

bool _isCombining(int cp) =>
    (cp >= 0x0300 && cp <= 0x036F) ||
    (cp >= 0x1AB0 && cp <= 0x1AFF) ||
    (cp >= 0x1DC0 && cp <= 0x1DFF) ||
    (cp >= 0x20D0 && cp <= 0x20FF) ||
    (cp >= 0xFE20 && cp <= 0xFE2F);

// Minimal decomposition map for characters that appear in tests/corpus.
// Covers e-acute, a-grave, etc. For characters not in map, we still strip
// combining marks if the Dart string already contains decomposed forms.
const Map<String, String> _decomposeMap = {
  'à': 'a\u0300',
  'á': 'a\u0301',
  'â': 'a\u0302',
  'ã': 'a\u0303',
  'ä': 'a\u0308',
  'å': 'a\u030a',
  'è': 'e\u0300',
  'é': 'e\u0301',
  'ê': 'e\u0302',
  'ë': 'e\u0308',
  'ì': 'i\u0300',
  'í': 'i\u0301',
  'î': 'i\u0302',
  'ï': 'i\u0308',
  'ò': 'o\u0300',
  'ó': 'o\u0301',
  'ô': 'o\u0302',
  'õ': 'o\u0303',
  'ö': 'o\u0308',
  'ù': 'u\u0300',
  'ú': 'u\u0301',
  'û': 'u\u0302',
  'ü': 'u\u0308',
  'ñ': 'n\u0303',
  'ç': 'c\u0327',
  'À': 'A\u0300',
  'Á': 'A\u0301',
  'Â': 'A\u0302',
  'Ã': 'A\u0303',
  'Ä': 'A\u0308',
  'Å': 'A\u030a',
  'È': 'E\u0300',
  'É': 'E\u0301',
  'Ê': 'E\u0302',
  'Ë': 'E\u0308',
  'Ì': 'I\u0300',
  'Í': 'I\u0301',
  'Î': 'I\u0302',
  'Ï': 'I\u0308',
  'Ò': 'O\u0300',
  'Ó': 'O\u0301',
  'Ô': 'O\u0302',
  'Õ': 'O\u0303',
  'Ö': 'O\u0308',
  'Ù': 'U\u0300',
  'Ú': 'U\u0301',
  'Û': 'U\u0302',
  'Ü': 'U\u0308',
  'Ñ': 'N\u0303',
  'Ç': 'C\u0327',
  'ý': 'y\u0301',
  'ÿ': 'y\u0308',
  'Ý': 'Y\u0301',
  // Latin Extended-A forms the GeoNames dumps and romanised itineraries
  // carry: macrons (Hepburn — Ōsaka, Kyūshū), breves (McCune–Reischauer —
  // Sŏul), and the common carons. Python's NFD (the scorer, and the lab
  // measurement the gazetteer asset was frozen against) strips all of
  // these; the committed asset and the runtime lookups must agree.
  'ā': 'a\u0304',
  'ă': 'a\u0306',
  'ē': 'e\u0304',
  'ĕ': 'e\u0306',
  'ī': 'i\u0304',
  'ĭ': 'i\u0306',
  'ō': 'o\u0304',
  'ŏ': 'o\u0306',
  'ū': 'u\u0304',
  'ŭ': 'u\u0306',
  'Ā': 'A\u0304',
  'Ă': 'A\u0306',
  'Ē': 'E\u0304',
  'Ĕ': 'E\u0306',
  'Ī': 'I\u0304',
  'Ĭ': 'I\u0306',
  'Ō': 'O\u0304',
  'Ŏ': 'O\u0306',
  'Ū': 'U\u0304',
  'Ŭ': 'U\u0306',
  'š': 's\u030c',
  'Š': 'S\u030c',
  'ž': 'z\u030c',
  'Ž': 'Z\u030c',
  'č': 'c\u030c',
  'Č': 'C\u030c',
};

final RegExp _wordRegExp = RegExp(r"[A-Za-z][A-Za-z'’‘’-]*");

/// Ordered word tokens, lowercased, diacritics stripped, hyphens split
/// (hyphenated pairs also contribute their joined form).
List<String> areaTokens(String s) {
  s = stripDiacritics(s);
  final out = <String>[];
  for (final m in _wordRegExp.allMatches(s)) {
    var w = m.group(0)!.toLowerCase().replaceAll('’', "'").replaceAll('‘', "'");
    w = w.replaceAll(RegExp(r"^['-]+|['-]+$"), '');
    if (w.isEmpty) continue;
    if (w.contains('-')) {
      final parts = w.split('-').where((p) => p.isNotEmpty).toList();
      out.addAll(parts);
      if (parts.length > 1) {
        out.add(parts.join(''));
      }
    } else {
      out.add(w);
    }
  }
  return out;
}

/// Content words for area matching: tokens minus generic/venue, len >=2.
Set<String> areaWords(String s) => {
      for (final w in areaTokens(s))
        if (!genericStopWords.contains(w) &&
            !venueGenericWords.contains(w) &&
            w.length >= 2)
          w
    };

/// Joined form: concatenation of area words — for hyphen-joined matching.
String joinedAreaWords(String s) => areaTokens(s)
    .where(
        (w) => !genericStopWords.contains(w) && !venueGenericWords.contains(w))
    .join();

/// True when every content token is furniture/venue-generic/digit-bearing.
bool isFurniture(String cand) {
  final ws = [
    for (final w in areaTokens(cand))
      if (!genericStopWords.contains(w)) w
  ];
  if (ws.isEmpty) return true;
  if (cand.codeUnits.any((c) => c >= 48 && c <= 57)) return true;
  return ws.every(
      (w) => furnitureWords.contains(w) || venueGenericWords.contains(w));
}

/// Area verdict matching (§3.4): correct if subset/superset or joined equality.
String areaVerdict(String? assigned, List<String> accepts) {
  if (assigned == null || areaWords(assigned).isEmpty) {
    return accepts.contains('NONE') ? 'none-ok' : 'miss';
  }
  final a = areaWords(assigned);
  final jA = joinedAreaWords(assigned);
  for (final acc in accepts) {
    if (acc == 'NONE') continue;
    final b = areaWords(acc);
    if (b.isEmpty) continue;
    if ((a.containsAll(b) || b.containsAll(a)) || jA == joinedAreaWords(acc)) {
      return 'correct';
    }
  }
  return 'wrong';
}

/// Normalized form (§3.4 canonical): lowercase, diacritics stripped,
/// hyphens split+joined handled via areaTokens, generics stripped,
/// space-joined.
String normalizedArea(String s) {
  final ws = areaTokens(s)
      .where((w) =>
          !genericStopWords.contains(w) && !venueGenericWords.contains(w))
      .toList();
  // Deduplicate joined variant: if last token is the join of previous tokens, drop it
  // (the tokenizer appends joined form — for normalized we want the split form)
  // Actually scorer's `area_words` doesn't include the joined variant separately
  // in the set, but `tokens` does include it. For normalized we want the
  // space-joined content words without the joined duplicate.
  // Detect: if last token == join of all previous tokens that are content words
  // This handles "shimo-kitazawa" -> ["shimo","kitazawa","shimokitazawa"]
  if (ws.length >= 3) {
    final last = ws.last;
    final withoutLast = ws.sublist(0, ws.length - 1);
    if (withoutLast.join() == last) {
      return withoutLast.join(' ');
    }
  }
  return ws.join(' ');
}
