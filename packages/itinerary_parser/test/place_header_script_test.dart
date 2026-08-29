import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:itinerary_parser/src/line_classifier.dart';
import 'package:test/test.dart';

/// The bare place-name day header, across scripts.
///
/// `looksLikeProperNounHeader` used to test `^[A-Z][A-Za-z'.]*$`, which is
/// ASCII-only: `München`, `Αθήνα`, `Москва` and `京都` were not headers at
/// all, so `ParsedDay.place` came back null for every day of the trip and
/// nothing reported a problem. Every fixture in this package is Japan
/// written in English, which is why it stayed invisible.
///
/// The two halves of this file are equally load-bearing. The first proves
/// the alphabet widened; the second proves that widening it did not widen
/// what counts as a heading. The heuristic earns its place by being narrow.
void main() {
  group('accepts a capitalized name in any cased script', () {
    const accepted = <String, String>{
      // The ASCII cases, unchanged.
      'Kyoto': 'plain ASCII, the shape that already worked',
      'New York': 'two ASCII words',
      'San Francisco Bay': 'three ASCII words',
      'KYOTO': 'all caps',
      'St. Moritz': 'a period inside a word',
      "O'Brien": 'an apostrophe inside a word',
      'McDonald': 'an interior capital',
      // Latin with diacritics — the commonest form of the defect.
      'München': 'German umlaut',
      'Zürich': 'Swiss umlaut',
      'São Paulo': 'Portuguese tilde',
      'Kraków': 'Polish acute',
      'Málaga': 'Spanish acute',
      'Genève': 'French grave',
      'Reykjavík': 'Icelandic acute',
      'Ålesund': 'Norwegian ring',
      'Đà Nẵng': 'Vietnamese stroke and stacked diacritics',
      'Ísafjörður': 'Icelandic eth',
      // Greek and Cyrillic: cased scripts outside the Latin block.
      'Αθήνα': 'Greek',
      'ΑΘΗΝΑ': 'Greek, all caps',
      'Θεσσαλονίκη': 'Greek, long',
      'Москва': 'Cyrillic',
      'МОСКВА': 'Cyrillic, all caps',
      'Київ': 'Ukrainian Cyrillic',
      'Երևան': 'Armenian',
    };

    accepted.forEach((line, why) {
      test('$line ($why)', () {
        expect(looksLikeProperNounHeader(line), isTrue, reason: why);
      });
    });

    test('a decomposed name is the same name as a composed one', () {
      // NFD: `u` + COMBINING DIAERESIS, which is what a paste out of a
      // macOS filename or some PDF text layers actually carries.
      const decomposed = 'Zürich';
      expect(decomposed, isNot('Zürich'), reason: 'this really is NFD');
      expect(looksLikeProperNounHeader(decomposed), isTrue);
    });
  });

  group('accepts a name in a script with no letter case', () {
    // `\p{Lu}` alone still refuses these: 京都 has no capital to show,
    // because kanji has no capitals. In a caseless script an uncapitalized
    // word *is* what a place name looks like.
    const accepted = <String, String>{
      '京都': 'kanji',
      '東京': 'kanji',
      '富士河口湖町': 'kanji, six characters',
      'ソウル': 'katakana',
      'おおさか': 'hiragana',
      '서울': 'hangul',
      '부산': 'hangul',
      'กรุงเทพ': 'Thai',
      'กรุงเทพมหานคร': 'Thai, thirteen code points',
      'เชียงใหม่': 'Thai with tone marks',
      'القاهرة': 'Arabic',
      'بيت لحم': 'Arabic, two words',
      'ירושלים': 'Hebrew',
      'नई दिल्ली': 'Devanagari with matras, two words',
      '東京 大阪': 'two caseless words',
      'Kyoto 京都': 'a cased word beside a caseless one',
    };

    accepted.forEach((line, why) {
      test('$line ($why)', () {
        expect(looksLikeProperNounHeader(line), isTrue, reason: why);
      });
    });
  });

  group('still refuses everything it refused before', () {
    const refused = <String, String>{
      'lunch at the market': 'ordinary lowercase prose',
      'kyoto': 'one lowercase word',
      'café by the river': 'lowercase prose carrying a diacritic',
      'обед в кафе': 'lowercase Cyrillic prose — a cased script with no '
          'capital is prose, not a name',
      'μεσημεριανό στην αγορά': 'lowercase Greek prose, likewise',
      '- Kyoto': 'a dash bullet',
      '• München': 'a round bullet',
      '1. München': 'a numbered bullet',
      'Kyoto 2027': 'a line carrying digits',
      'München 14': 'a non-ASCII line carrying digits',
      '京都 2027': 'a caseless line carrying digits',
      '18:00 Kyoto': 'a line carrying a time',
      'We Will Take The Early Train To Kyoto':
          'a long sentence, capitalized or not',
      'Wir Fahren Mit Dem Frühen Zug Nach München':
          'a long sentence in another language',
      'Kyoto!': 'punctuation the ASCII form never admitted either',
      '🗼 Tokyo': 'an emoji is not a letter',
      '': 'the empty line',
      '   ': 'whitespace only',
    };

    refused.forEach((line, why) {
      test('${line.isEmpty ? '(empty)' : line} ($why)', () {
        expect(looksLikeProperNounHeader(line), isFalse, reason: why);
      });
    });

    test('an unspaced caseless sentence is not a place name', () {
      // Japanese is written without spaces, so word *count* — the bound
      // that keeps a Latin line short — stops bounding anything here. A
      // whole sentence arrives as one "word".
      const sentence = '朝食のあとで京都駅に集合してください';
      expect(sentence.split(RegExp(r'\s+')).length, 1,
          reason: 'one word by the splitter, eighteen characters to a reader');
      expect(looksLikeProperNounHeader(sentence), isFalse);
    });

    test('a spaced caseless line is held to a tighter word count', () {
      // Arabic has no capitals to offer as evidence, so brevity is the
      // only evidence left and the bound is three words, not five.
      expect(looksLikeProperNounHeader('نلتقي في الفندق'), isTrue,
          reason: 'three words still read as a name');
      expect(looksLikeProperNounHeader('نلتقي في الفندق غدا'), isFalse,
          reason: 'four caseless words is prose');
      expect(looksLikeProperNounHeader('San Francisco Bay Area Hotel'), isTrue,
          reason: 'five words is still fine when capitals vouch for them');
    });
  });

  group('end to end: the day gets its place', () {
    test('a bare non-ASCII header becomes the day place', () {
      final result = parseItinerary(
        'München\n'
        '- Marienplatz\n'
        '- 19:00 Hofbräuhaus\n',
      );
      final day = result.days.single;
      expect(day.place, 'München');
      expect(day.uncertainty, DayUncertainty.barePlaceName);
      expect(day.stops, hasLength(2));
    });

    test('a whole plan of non-ASCII headers keeps every place', () {
      final result = parseItinerary(
        'Zürich\n'
        '- Grossmünster\n'
        '\n'
        'Αθήνα\n'
        '- Ακρόπολη\n'
        '\n'
        'Москва\n'
        '- Красная площадь\n'
        '\n'
        '京都\n'
        '- 伏見稲荷大社\n'
        '\n'
        '서울\n'
        '- 경복궁\n',
      );
      expect(
        result.days.map((d) => d.place).toList(),
        ['Zürich', 'Αθήνα', 'Москва', '京都', '서울'],
      );
      expect(result.days.every((d) => d.stops.length == 1), isTrue);
      expect(result.unplacedLines, isEmpty,
          reason: 'nothing should fall out of a plan the parser understood');
    });

    test('an ASCII plan is untouched', () {
      final result = parseItinerary(
        'Kyoto\n'
        '- Fushimi Inari Taisha\n'
        '\n'
        'Nara\n'
        '- Todai-ji Temple\n',
      );
      expect(result.days.map((d) => d.place).toList(), ['Kyoto', 'Nara']);
    });
  });
}
