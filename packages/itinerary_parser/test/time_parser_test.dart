import 'package:itinerary_parser/src/models.dart';
import 'package:itinerary_parser/src/time_parser.dart';
import 'package:test/test.dart';

void main() {
  group('extractTime', () {
    test('24-hour colon form', () {
      expect(extractTime('Arrive at 16:40 sharp'), ParsedTime(16, 40));
    });

    test('24-hour dot form', () {
      expect(extractTime('16.40 check in'), ParsedTime(16, 40));
    });

    test('12-hour colon with lowercase pm', () {
      expect(extractTime('4:40pm at the gate'), ParsedTime(16, 40));
    });

    test('12-hour dot form with spaced uppercase PM', () {
      expect(extractTime('4.40 PM at the gate'), ParsedTime(16, 40));
    });

    test('hour-only with meridiem', () {
      expect(extractTime('back by 4pm'), ParsedTime(16, 0));
    });

    test('bare 4-digit military time', () {
      expect(extractTime('1640 train departs'), ParsedTime(16, 40));
    });

    test('bare 4-digit military time before noon', () {
      expect(extractTime('0900 breakfast'), ParsedTime(9, 0));
    });

    test('a range uses only the start time', () {
      expect(extractTime('14:00-16:00 free time'), ParsedTime(14, 0));
    });

    test('a range with meridiem uses only the start time', () {
      expect(extractTime('2pm-4pm at the pool'), ParsedTime(14, 0));
    });

    test('12am is midnight', () {
      expect(extractTime('12am curfew'), ParsedTime(0, 0));
    });

    test('12pm is noon', () {
      expect(extractTime('12pm lunch'), ParsedTime(12, 0));
    });

    test('a bare 4-digit number that reads as a calendar year is not a time',
        () {
      expect(extractTime('Japan trip 2026'), isNull);
      expect(extractTime('booked in 1999'), isNull);
    });

    test('no time present returns null', () {
      expect(extractTime('Lunch at Nishiki Market'), isNull);
    });

    test('an out-of-range hour is not treated as a time', () {
      expect(extractTime('flight AA2599 direct'), isNull);
    });
  });
}
