/// The three words somebody says across a table to get onto a trip.
///
/// The shape is the record's: three spoken words, forgiving of order and
/// spelling (`docs/decisions/2026-08-22-grill-round-one.md` §5), drawn as
/// `otter maple 42` on design surfaces 6d and 15c — two words and a
/// two-digit number, which is still three things a person says out loud and
/// is what the drawings put on screen. The eight-character generator that
/// decision replaced is still what `supabase/migrations/0005_trip_invites.sql`
/// mints; this type is the phone's half, and the server's half is Phase 2.
///
/// **This file has no randomness.** Minting draws from [words] and [numbers]
/// somewhere that is allowed to be random — the app's seam does it, the way
/// it mints a photo id — because the domain has no I/O and no clock.
library;

/// One invite code: two words and a number, in the order it is written down.
///
/// Two codes with the same pair of words are the same code whichever order
/// they were said in — see [matches] and `==`.
final class InviteCode {
  /// The two words, as [words] spells them. Never equal to each other.
  final String firstWord;
  final String secondWord;

  /// The number, 10..99. Two digits so it is one spoken word ("forty-two")
  /// rather than two.
  final int number;

  InviteCode(this.firstWord, this.secondWord, this.number) {
    if (!words.contains(firstWord) || !words.contains(secondWord)) {
      throw ArgumentError.value(
        '$firstWord $secondWord',
        'words',
        'an invite code is made of two words from InviteCode.words',
      );
    }
    if (firstWord == secondWord) {
      throw ArgumentError.value(
        firstWord,
        'words',
        'the two words of a code are different words',
      );
    }
    if (number < 10 || number > 99) {
      throw ArgumentError.value(number, 'number', 'must be 10..99');
    }
  }

  /// Draws a code from [words] and the two-digit numbers, given three
  /// arbitrary integers — a caller with a source of randomness passes
  /// `random.nextInt(...)`, and a test passes fixed numbers.
  ///
  /// The two words are drawn distinctly: [secondDraw] indexes what is left
  /// after the first word is taken out, so no caller can produce
  /// `otter otter 42` by drawing the same index twice.
  factory InviteCode.draw({
    required int firstDraw,
    required int secondDraw,
    required int numberDraw,
  }) {
    final first = words[firstDraw % words.length];
    final remaining = [for (final w in words) if (w != first) w];
    return InviteCode(
      first,
      remaining[secondDraw % remaining.length],
      10 + numberDraw % 90,
    );
  }

  /// Reads a code back from the canonical spelling [spoken] produces, or
  /// from anything [matches] would accept. Null when the text is not a code.
  static InviteCode? tryParse(String text) {
    final tokens = _tokenise(text);
    if (tokens.length != 3) return null;
    int? number;
    final said = <String>[];
    for (final token in tokens) {
      final parsed = int.tryParse(token);
      if (parsed != null && number == null) {
        number = parsed;
      } else {
        said.add(token);
      }
    }
    if (number == null || number < 10 || number > 99) return null;
    if (said.length != 2) return null;
    final first = _nearestWord(said[0]);
    final second = _nearestWord(said[1]);
    if (first == null || second == null || first == second) return null;
    return InviteCode(first, second, number);
  }

  /// Whether [text] is this code, however it was said.
  ///
  /// Order does not matter, because a code lives in somebody's memory of a
  /// sentence rather than in a field. One letter of slack per word does not
  /// matter either: [words] is chosen so that no two of its words are within
  /// two edits of each other, so a near-spelling can only ever land on the
  /// word it was reaching for. Anything further out is a different code, not
  /// a worse guess at this one.
  bool matches(String text) => tryParse(text) == this;

  /// `otter maple 42` — the code as it is written down and read aloud.
  String get spoken => '$firstWord $secondWord $number';

  /// The two words in one order, so two spellings of the same code compare
  /// equal.
  List<String> get _pair =>
      firstWord.compareTo(secondWord) <= 0
          ? [firstWord, secondWord]
          : [secondWord, firstWord];

  @override
  bool operator ==(Object other) =>
      other is InviteCode &&
      other.number == number &&
      other._pair[0] == _pair[0] &&
      other._pair[1] == _pair[1];

  @override
  int get hashCode => Object.hash(_pair[0], _pair[1], number);

  @override
  String toString() => 'InviteCode($spoken)';

  /// The vocabulary codes are drawn from.
  ///
  /// Every word is four to eight letters, has one obvious spelling, and is
  /// at least three edits away from every other word in the list — counting
  /// a swapped pair of letters as one edit, the way [matches] counts. Three
  /// is what makes one letter of slack unambiguous: a said word within one
  /// edit of two different words would be a code nobody could type. It is
  /// pinned by a test rather than left as a promise, so adding a word that
  /// breaks it fails rather than quietly widening a code.
  ///
  /// A hundred and nineteen words, chosen distinctly and paired with a
  /// two-digit number, is a little over six hundred thousand codes. That is
  /// sized against two people on the same trip minting codes minutes apart,
  /// not against somebody guessing at a server: rate-limiting redemption is
  /// the server's job, and the server's generator is still the old one.
  static const words = <String>[
    'acorn', 'almond', 'amber', 'anchor', 'anvil', 'apricot',
    'bamboo', 'basket', 'beacon', 'bison', 'cabin', 'cactus',
    'candle', 'cedar', 'clover', 'compass', 'copper', 'dahlia',
    'daisy', 'dolphin', 'domino', 'dragon', 'drift', 'elder',
    'falcon', 'feather', 'ferry', 'fjord', 'fossil', 'garden',
    'gecko', 'ginger', 'glacier', 'hammock', 'harbour', 'harvest',
    'hazel', 'hedge', 'heron', 'honey', 'ibex', 'indigo',
    'iris', 'island', 'ivory', 'jackal', 'jasmine', 'jetty',
    'jungle', 'juniper', 'kayak', 'kelp', 'kestrel', 'kettle',
    'knoll', 'koala', 'ladder', 'lagoon', 'lantern', 'lilac',
    'llama', 'lupin', 'mammoth', 'mango', 'maple', 'marsh',
    'meadow', 'monsoon', 'narwhal', 'nectar', 'needle', 'nook',
    'nutmeg', 'oasis', 'ocelot', 'octopus', 'olive', 'orchard',
    'otter', 'parcel', 'parsnip', 'pebble', 'puffin', 'pumpkin',
    'quail', 'quartz', 'quince', 'quokka', 'rabbit', 'radish',
    'reindeer', 'ribbon', 'river', 'sorrel', 'summit', 'tapir',
    'teal', 'temple', 'thistle', 'tulip', 'tunnel', 'umbrella',
    'urchin', 'velvet', 'vessel', 'violet', 'vulture', 'walnut',
    'willow', 'wombat', 'yarrow', 'yonder', 'yucca', 'zebra',
    'zenith', 'zephyr', 'zinnia',
  ];

  /// How far a said word may be from a real one and still be that word.
  static const spellingSlack = 1;
}

/// Splits what somebody typed into the three things they said.
///
/// Everything that is not a letter or a digit is a gap: `otter-maple-42`,
/// `Otter Maple 42` and `otter, maple, 42` are one code said three ways. A
/// link carrying a code hands over the three words; taking them out of a URL
/// is the link's own business and deliberately not this function's, which
/// would otherwise read a code out of any sentence with three tokens in it.
List<String> _tokenise(String text) => [
      for (final part in text.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
        if (part.isNotEmpty) part,
    ];

/// The word [said] was reaching for, or null if it was not reaching for one.
String? _nearestWord(String said) {
  if (InviteCode.words.contains(said)) return said;
  for (final word in InviteCode.words) {
    if ((word.length - said.length).abs() > InviteCode.spellingSlack) continue;
    if (_editDistance(word, said) <= InviteCode.spellingSlack) return word;
  }
  return null;
}

/// How many edits apart two words are, **counting a swapped pair of
/// adjacent letters as one edit** rather than two.
///
/// That is the difference between Levenshtein and what this needs:
/// `mapel` for `maple` is the most ordinary way to mistype a word, and
/// plain Levenshtein prices it at two, which would put it outside the one
/// letter of slack the record asked for. This is the optimal string
/// alignment distance.
int _editDistance(String a, String b) {
  final rows = List.generate(
    a.length + 1,
    (i) => List<int>.filled(b.length + 1, 0),
  );
  for (var i = 0; i <= a.length; i++) {
    rows[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    rows[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var best = rows[i - 1][j] + 1;
      final insertion = rows[i][j - 1] + 1;
      if (insertion < best) best = insertion;
      final substitution = rows[i - 1][j - 1] + cost;
      if (substitution < best) best = substitution;
      if (i > 1 &&
          j > 1 &&
          a[i - 1] == b[j - 2] &&
          a[i - 2] == b[j - 1]) {
        final transposition = rows[i - 2][j - 2] + 1;
        if (transposition < best) best = transposition;
      }
      rows[i][j] = best;
    }
  }
  return rows[a.length][b.length];
}
