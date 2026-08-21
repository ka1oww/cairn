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
