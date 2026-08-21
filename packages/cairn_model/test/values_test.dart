import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

void main() {
  group('CalendarDate', () {
    test('refuses a date the calendar does not have', () {
      expect(() => CalendarDate(2026, 2, 30), throwsA(isA<ArgumentError>()));
      expect(() => CalendarDate(2026, 13, 1), throwsA(isA<ArgumentError>()));
      expect(() => CalendarDate(2026, 2, 29), throwsA(isA<ArgumentError>()));
      expect(CalendarDate(2028, 2, 29).iso, '2028-02-29');
    });

    test('walks the calendar, including over a year boundary', () {
      expect(CalendarDate(2026, 12, 31).next.iso, '2027-01-01');
      expect(CalendarDate(2026, 3, 1).addDays(-1).iso, '2026-02-28');
    });

    test('orders and compares by value', () {
      expect(CalendarDate(2026, 6, 14), CalendarDate(2026, 6, 14));
      expect(CalendarDate(2026, 6, 14) < CalendarDate(2026, 6, 15), isTrue);
      expect(
        [CalendarDate(2026, 7, 1), CalendarDate(2026, 6, 30)]..sort(),
        [CalendarDate(2026, 6, 30), CalendarDate(2026, 7, 1)],
      );
    });
  });

  group('ClockTime', () {
    test('prints the way the day page does', () {
      expect(const ClockTime(8, 40).iso, '08:40');
      expect(const ClockTime(23, 40).iso, '23:40');
    });

    test('compares through the day', () {
      expect(const ClockTime(8, 40).compareTo(const ClockTime(22, 10)),
          lessThan(0));
      expect(const ClockTime(8, 40), const ClockTime(8, 40));
    });
  });

  group('Stop', () {
    test('is starred exactly when it has a time, and never otherwise', () {
      expect(Stop(text: 'Nishiki Market').isStarred, isFalse);
      expect(
        Stop(text: 'train to Osaka', time: const ClockTime(18, 40)).isStarred,
        isTrue,
      );
    });

    test('keeps its text as written', () {
      expect(
          Stop(text: '  philosopher\'s path ').text, '  philosopher\'s path ');
      expect(() => Stop(text: '   '), throwsA(isA<ArgumentError>()));
    });
  });

  group('TripClock', () {
    test('refuses an offset no zone has', () {
      expect(
        () => TripClock.fixedOffset(const Duration(hours: 20)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => TripClock.fixedOffset(const Duration(seconds: 30)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('carries both spellings so neither layer below has to guess', () {
      final tokyo =
          TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9));
      expect(tokyo.zoneId, 'Asia/Tokyo');
      expect(tokyo.utcOffset, const Duration(hours: 9));
      expect(tokyo.label, 'Asia/Tokyo');
      expect(
          TripClock.fixedOffset(const Duration(hours: -9, minutes: -30)).label,
          'UTC-09:30');
    });

    test('reads an instant as a date and a time', () {
      final tokyo =
          TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9));
      final instant = DateTime.utc(2026, 6, 14, 23, 40);
      expect(tokyo.dateAt(instant), CalendarDate(2026, 6, 15));
      expect(tokyo.clockTimeAt(instant), const ClockTime(8, 40));
      expect(tokyo.startOfDay(CalendarDate(2026, 6, 15)),
          DateTime.utc(2026, 6, 14, 15));
    });
  });

  group('PhotoRef', () {
    test('refuses a timestamp that is not UTC', () {
      expect(
        () => PhotoRef(
          id: const PhotoId('p1'),
          dayNumber: 1,
          contributor: const MemberId('mum'),
          takenAt: DateTime(2026, 6, 14, 8, 40),
          origin: PhotoOrigin.pinged,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('identifiers', () {
    test('of different kinds are never equal', () {
      expect(const MemberId('x') == const MemberId('x'), isTrue);
      // ignore: unrelated_type_equality_checks
      expect(const MemberId('x') == const PhotoId('x'), isFalse);
      expect(
          <MemberId>{
            ...[const MemberId('x'), const MemberId('x')]
          }.length,
          1);
    });
  });
}
