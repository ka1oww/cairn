import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:itinerary_parser/src/time_parser.dart';
import 'package:test/test.dart';

/// A star is the only place a time appears in the app, so a hedged time —
/// an estimate, not a commitment — must extract no time and therefore
/// produce no star. These tests pin both directions: hedged forms yield
/// nothing, and the definite forms they shadow keep working.
void main() {
  group('hedged times extract nothing', () {
    const hedged = [
      'maybe around 3pm',
      'kiyomizu dera in the afternoon, maybe 4pm?',
      'Check in around 4.40 PM',
      'lunch about 12:30',
      'roughly 9am start',
      'onsen ~7pm',
      'onsen ~ 19:00',
      'dinner 7pm-ish',
      'dinner 7pm ish',
      'temple visit 2pm or 3pm',
      'check-out 10am?',
      'breakfast approx 0830',
      'train sometime around 16:40',
      'museum, probably 11am',
      'hopefully 9:00 departure',
      'pool 14:00-16:00 or so',
    ];
    for (final line in hedged) {
      test('"$line" has no time', () {
        expect(extractTime(line), isNull);
      });
    }
  });

  group('definite times still extract', () {
    const definite = {
      'Check in 4.40 PM': '16:40',
      '16:40 Arrive Narita Airport': '16:40',
      'Train to Kyoto 10:12': '10:12',
      'dinner 7pm': '19:00',
      '0900 Tsukiji breakfast market': '09:00',
      '14:00-16:00 Free time': '14:00',
      // The hedge lives in a different clause than the time.
      'Dinner at 7pm, maybe karaoke after': '19:00',
      'Around the corner from the hotel, 9am pickup': '09:00',
    };
    definite.forEach((line, expected) {
      test('"$line" extracts $expected', () {
        expect(extractTime(line)?.toIso(), expected);
      });
    });
  });

  test('a hedged time produces no star through the full parse', () {
    final result = parseItinerary('Day 1 - Kyoto\n'
        '- Fushimi Inari maybe around 3pm\n'
        '- 18:00 kaiseki dinner\n');
    final stops = result.days.single.stops;
    expect(stops[0].isStarred, isFalse);
    expect(stops[0].time, isNull);
    expect(stops[0].text, 'Fushimi Inari maybe around 3pm',
        reason: 'the hedged text itself is kept verbatim, only unstarred');
    expect(stops[1].isStarred, isTrue);
    expect(stops[1].time?.toIso(), '18:00');
  });
}
