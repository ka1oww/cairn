// The three words somebody says across a table, and the trip they die with.
import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

/// Edit distance counting a swapped pair as one edit, written out here
/// rather than reached for through the package: the wordlist's separation is
/// the property this file pins, so it must not be pinned by the very code
/// that relies on it.
int distance(String a, String b) {
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
      final candidates = [
        rows[i - 1][j] + 1,
        rows[i][j - 1] + 1,
        rows[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1])
          rows[i - 2][j - 2] + 1,
      ];
      rows[i][j] = candidates.reduce((x, y) => x < y ? x : y);
    }
  }
  return rows[a.length][b.length];
}

void main() {
  final code = InviteCode('otter', 'maple', 42);

  group('the code is three things you can say', () {
    test('two words and a two-digit number, as the drawings put it', () {
      expect(code.spoken, 'otter maple 42');
    });

    test('a code of nonsense words is refused', () {
      expect(() => InviteCode('otter', 'kumquat', 42),
          throwsA(isA<ArgumentError>()));
    });

    test('the same word twice is refused — three things, not two', () {
      expect(() => InviteCode('otter', 'otter', 42),
          throwsA(isA<ArgumentError>()));
    });

    test('a one-digit or three-digit number is refused', () {
      expect(
          () => InviteCode('otter', 'maple', 7), throwsA(isA<ArgumentError>()));
      expect(() => InviteCode('otter', 'maple', 100),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('minting draws a real code from any three numbers', () {
    test('the draw lands inside the vocabulary and the two digits', () {
      for (var i = 0; i < 200; i++) {
        final drawn = InviteCode.draw(
          firstDraw: i * 7,
          secondDraw: i * 13,
          numberDraw: i * 31,
        );
        expect(InviteCode.words, contains(drawn.firstWord));
        expect(InviteCode.words, contains(drawn.secondWord));
        expect(drawn.number, inInclusiveRange(10, 99));
      }
    });

    test('the same draw twice never puts the same word in both places', () {
      final drawn = InviteCode.draw(firstDraw: 5, secondDraw: 0, numberDraw: 0);
      expect(drawn.firstWord, isNot(drawn.secondWord));
    });
  });

  group('saying it back', () {
    test('exactly, as it was written down', () {
      expect(code.matches('otter maple 42'), isTrue);
    });

    test('in any order, because it lives in a memory of a sentence', () {
      expect(code.matches('maple otter 42'), isTrue);
      expect(code.matches('42 maple otter'), isTrue);
    });

    test('in any case, and through whatever punctuation was in the way', () {
      expect(code.matches('Otter Maple 42'), isTrue);
      expect(code.matches('  otter,  maple,  42 '), isTrue);
      expect(code.matches('otter-maple-42'), isTrue);
    });

    test('with a letter wrong, which is the whole point of speaking it', () {
      expect(code.matches('oter maple 42'), isTrue);
      expect(code.matches('otterr maple 42'), isTrue);
      // A swapped pair is one mistake, not two — it is how people actually
      // mistype, and pricing it as two would put it outside the slack.
      expect(code.matches('otter mapel 42'), isTrue);
    });

    test('but a different code is a different code, not a worse guess', () {
      expect(code.matches('otter maple 43'), isFalse);
      expect(code.matches('otter willow 42'), isFalse);
      expect(code.matches('otter maple'), isFalse);
      expect(code.matches('otter maple 42 42'), isFalse);
      expect(code.matches(''), isFalse);
      // Two letters out is past the slack: nothing is guessed from here.
      expect(code.matches('oter mapel 42'), isTrue);
      expect(code.matches('ottttr maple 42'), isFalse);
    });

    test('what was said reads back as the code that was minted', () {
      expect(InviteCode.tryParse('MAPLE otter 42'), code);
      expect(InviteCode.tryParse('otter maple 9'), isNull);
      expect(InviteCode.tryParse('hello there 42'), isNull);
    });

    test('two spellings of one code are one code', () {
      expect(InviteCode('maple', 'otter', 42), code);
      expect(InviteCode('maple', 'otter', 42).hashCode, code.hashCode);
    });
  });

  group('the vocabulary', () {
    test('is spellable: four to eight letters, all lowercase', () {
      for (final word in InviteCode.words) {
        expect(word, matches(RegExp(r'^[a-z]{4,8}$')), reason: word);
      }
    });

    test('holds no word twice', () {
      expect(InviteCode.words.toSet().length, InviteCode.words.length);
    });

    test(
        'keeps every pair three edits apart — a swap counting as one — '
        'which is what makes one letter of slack unambiguous', () {
      for (var i = 0; i < InviteCode.words.length; i++) {
        for (var j = i + 1; j < InviteCode.words.length; j++) {
          final a = InviteCode.words[i];
          final b = InviteCode.words[j];
          expect(distance(a, b), greaterThanOrEqualTo(3), reason: '$a vs $b');
        }
      }
    });
  });

  group('an invite dies with its trip and at no other time', () {
    final minted = TripInvite(
      code: code,
      mintedBy: MemberId('mum'),
      mintedAt: DateTime.utc(2026, 6, 1),
    );
    final closes = DateTime.utc(2026, 6, 21, 15).add(graceAfterATrip);

    test('the close is the trip end plus the seventy-two-hour grace', () {
      expect(tripClosesAt(DateTime.utc(2026, 6, 21, 15)), closes);
      expect(graceAfterATrip, const Duration(hours: 72));
      expect(closes, DateTime.utc(2026, 6, 24, 15));
    });

    test('it admits people up to the close', () {
      expect(
        minted.standingAt(DateTime.utc(2026, 6, 23), tripClosesAt: closes),
        InviteStanding.live,
      );
      expect(
        minted.standingAt(
          closes.subtract(const Duration(microseconds: 1)),
          tripClosesAt: closes,
        ),
        InviteStanding.live,
      );
      expect(
        minted.standingAt(closes, tripClosesAt: closes),
        InviteStanding.expired,
      );
    });

    test('a trip with no dates yet has not ended, so nothing has expired', () {
      expect(
        minted.standingAt(DateTime.utc(2030), tripClosesAt: null),
        InviteStanding.live,
      );
    });

    test('revoking shuts it wherever the trip is', () {
      final shut = minted.revoked(DateTime.utc(2026, 6, 2));
      expect(
        shut.standingAt(DateTime.utc(2026, 6, 3), tripClosesAt: closes),
        InviteStanding.revoked,
      );
      expect(shut.code, minted.code);
    });

    test('a non-UTC instant is refused at the door', () {
      expect(
        () => TripInvite(
          code: code,
          mintedBy: MemberId('mum'),
          mintedAt: DateTime(2026, 6, 1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
