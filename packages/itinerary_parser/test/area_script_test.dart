import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

/// Areas derived from a day heading written in a script that is not ASCII.
///
/// `place_header_script_test.dart` covers the layer below this one: whether a
/// bare `München` or `京都` line is recognised as a day heading at all. It is,
/// and it was before this file existed. The defect this file pins sat one
/// layer up, in the area engine, and it was invisible because every fixture
/// in this package is Japan written in English.
///
/// Three ASCII-only assumptions had to go, and each one failed silently:
///
///   1. The tokenizer's word shape was `[A-Za-z]+`, so `areaTokens('京都')`
///      returned the empty list. A word that produces no tokens can never
///      enter the anchor vocabulary, so no run ever forms and every stop
///      comes back with no area.
///   2. The corroboration pass proved a word was a name by testing it for a
///      capital letter. CJK, hangul, Thai and the Indic scripts have no
///      capitals to offer, so that test refuses every name they can write.
///      [looksLikeANameWord] accepts a caseless-script word instead of
///      demanding evidence the script cannot produce.
///   3. The vocabulary's length floor was a flat three characters, which is
///      right for a script that writes with an alphabet and wrong for one
///      that does not: `京都`, `大阪`, `東京` and `서울` are whole place names
///      in two code points. [isLongEnoughToAnchor] splits the bound.
///
/// The plans below carry the corroboration the vocabulary has always
/// required (a word on at least two distinct lines). That requirement is
/// unchanged and deliberately so — this file proves the alphabet widened,
/// not that the evidence bar moved.
void main() {
  group('the tokenizer reads a name in any script', () {
    const reads = <String, String>{
      'München': 'German umlaut',
      'Zürich': 'Swiss umlaut',
      'Kraków': 'Polish acute',
      '京都': 'Japanese kanji',
      '東京': 'Japanese kanji',
      '서울': 'Korean hangul',
      'Αθήνα': 'Greek',
      'Москва': 'Cyrillic',
      'กรุงเทพ': 'Thai',
    };
    reads.forEach((word, why) {
      test('$word ($why) produces at least one token', () {
        expect(areaTokens(word), isNotEmpty,
            reason: 'a word the tokenizer cannot read can never anchor an area');
      });
    });
  });

  group('a name word is recognised without demanding a capital', () {
    for (final word in ['München', '京都', '서울', 'กรุงเทพ', 'Αθήνα']) {
      test('$word reads as a name word', () {
        expect(looksLikeANameWord(word), isTrue);
      });
    }
    test('a lowercase Latin word still does not', () {
      // Greek and Cyrillic lowercase are \p{Ll}, never \p{Lo}, so the
      // caseless branch cannot leak into them either.
      expect(looksLikeANameWord('breakfast'), isFalse);
      expect(looksLikeANameWord('αθήνα'), isFalse);
      expect(looksLikeANameWord('москва'), isFalse);
    });
  });

  group('the anchor length floor is split by script', () {
    test('two ASCII letters are still too short to anchor', () {
      expect(isLongEnoughToAnchor('st'), isFalse);
      expect(isLongEnoughToAnchor('to'), isFalse);
    });
    test('three ASCII letters are enough, as they always were', () {
      expect(isLongEnoughToAnchor('kyo'), isTrue);
    });
    test('two code points are enough in a caseless script', () {
      expect(isLongEnoughToAnchor('京都'), isTrue);
      expect(isLongEnoughToAnchor('서울'), isTrue);
    });
  });

  test('an accented-Latin heading derives an area for its day', () {
    const plan = '''
München
- Marienplatz (München)
- Hofbräuhaus
- München Hauptbahnhof Station

Zürich
- Grossmünster (Zürich)
- Bahnhofstrasse
- Zürich Hauptbahnhof Station
''';
    final result = parseItinerary(plan);
    expect(result.days, hasLength(2));

    // The area is the tokenized, diacritic-stripped spelling, which is what
    // the engine has always emitted for a Latin name: the traveller sees the
    // stop's own text, and the area is a search term, not a display string.
    for (final stop in result.days[0].stops) {
      expect(stop.area?.text, contains('munchen'),
          reason: 'every stop under the München heading should carry it');
    }
    for (final stop in result.days[1].stops) {
      expect(stop.area?.text, contains('zurich'));
    }
  });

  test('a CJK heading derives an area for its day', () {
    const plan = '''
京都
- 伏見稲荷大社
- 錦市場 (京都)
- 京都駅で昼食

大阪
- 道頓堀 (大阪)
- 大阪城
- 大阪駅の近くで夕食
''';
    final result = parseItinerary(plan);
    expect(result.days, hasLength(2));
    expect(result.days[0].place, '京都');
    expect(result.days[1].place, '大阪');

    for (final stop in result.days[0].stops) {
      expect(stop.area?.text, '京都',
          reason: 'this returned null for every stop before the fix');
    }
    for (final stop in result.days[1].stops) {
      expect(stop.area?.text, '大阪');
    }
  });
}
