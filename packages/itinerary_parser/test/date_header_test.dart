import 'package:itinerary_parser/src/date_header.dart';
import 'package:test/test.dart';

void main() {
  group('tryParseDateHeader', () {
    test('weekday + day + month', () {
      final m = tryParseDateHeader('Mon 3 Nov')!;
      expect(m.weekday, 1);
      expect(m.day, 3);
      expect(m.month, 11);
      expect(m.year, isNull);
      expect(m.hasFullDate, isTrue);
    });

    test('weekday + day + month + trailing place', () {
      final m = tryParseDateHeader('Mon 3 Nov - Kyoto')!;
      expect(m.day, 3);
      expect(m.month, 11);
      expect(m.trailingText, 'Kyoto');
    });

    test('day + month, no weekday', () {
      final m = tryParseDateHeader('3 November')!;
      expect(m.day, 3);
      expect(m.month, 11);
      expect(m.weekday, isNull);
    });

    test('month + day', () {
      final m = tryParseDateHeader('Nov 3')!;
      expect(m.day, 3);
      expect(m.month, 11);
    });

    test('month + day + year', () {
      final m = tryParseDateHeader('November 3, 2026')!;
      expect(m.day, 3);
      expect(m.month, 11);
      expect(m.year, 2026);
    });

    test('numeric day/month, day-first', () {
      final m = tryParseDateHeader('3/11')!;
      expect(m.day, 3);
      expect(m.month, 11);
      expect(m.year, isNull);
    });

    test('numeric day/month/year', () {
      final m = tryParseDateHeader('3/11/2026')!;
      expect(m.day, 3);
      expect(m.month, 11);
      expect(m.year, 2026);
    });

    test('ISO date', () {
      final m = tryParseDateHeader('2026-11-03')!;
      expect(m.day, 3);
      expect(m.month, 11);
      expect(m.year, 2026);
    });

    test('bare weekday, no date', () {
      final m = tryParseDateHeader('Monday')!;
      expect(m.weekday, 1);
      expect(m.hasFullDate, isFalse);
    });

    test('weekday + comma + day + month', () {
      final m = tryParseDateHeader('Sat, 14 June')!;
      expect(m.weekday, 6);
      expect(m.day, 14);
      expect(m.month, 6);
    });

    test('weekday + comma + day + month + year + trailing place', () {
      final m = tryParseDateHeader('Sat, 14 June 2027 - Kyoto')!;
      expect(m.weekday, 6);
      expect(m.day, 14);
      expect(m.month, 6);
      expect(m.year, 2027);
      expect(m.trailingText, 'Kyoto');
    });

    test('weekday + month + day, no comma', () {
      final m = tryParseDateHeader('Sat Jun 14')!;
      expect(m.weekday, 6);
      expect(m.month, 6);
      expect(m.day, 14);
      expect(m.year, isNull);
    });

    test('full weekday + comma + full month + day', () {
      final m = tryParseDateHeader('Saturday, June 14')!;
      expect(m.weekday, 6);
      expect(m.month, 6);
      expect(m.day, 14);
    });

    test('Wanderlog ddd, MMM Do with ordinal suffix', () {
      final m = tryParseDateHeader('Sat, Jun 14th')!;
      expect(m.weekday, 6);
      expect(m.month, 6);
      expect(m.day, 14);
    });

    test('weekday + month + day + year + trailing place', () {
      final m = tryParseDateHeader('Sat, Jun 14, 2027 — Tokyo')!;
      expect(m.weekday, 6);
      expect(m.month, 6);
      expect(m.day, 14);
      expect(m.year, 2027);
      expect(m.trailingText, 'Tokyo');
    });

    test('a date range reads as one header with the far end as place text',
        () {
      final m = tryParseDateHeader('Sat, Jun 14th — Wed, Jun 18th')!;
      expect(m.weekday, 6);
      expect(m.month, 6);
      expect(m.day, 14);
      expect(m.trailingText, 'Wed, Jun 18th');
    });

    test('month + day without a weekday still reads month-first', () {
      final m = tryParseDateHeader('June 14, 2027')!;
      expect(m.weekday, isNull);
      expect(m.month, 6);
      expect(m.day, 14);
      expect(m.year, 2027);
    });

    test('a leading word that is neither weekday nor month does not match',
        () {
      expect(tryParseDateHeader('Foo Jun 14'), isNull);
      expect(tryParseDateHeader('Foo, 14 June'), isNull);
    });

    test('a plain stop line is not mistaken for a date header', () {
      expect(tryParseDateHeader('Lunch at Nishiki Market'), isNull);
      expect(tryParseDateHeader('10 Downing Street'), isNull);
      expect(tryParseDateHeader('5 minutes to the station'), isNull);
      expect(tryParseDateHeader('Bags packed and ready'), isNull);
    });

    test('an invalid month name does not match', () {
      expect(tryParseDateHeader('32 Nonmonth'), isNull);
    });
  });
}
