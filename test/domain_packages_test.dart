// The DOMAIN band, consumed from the app. The four packages are path
// dependencies (never modified here); this test is the proof that each one
// resolves and runs inside the app's own toolchain — `flutter test`, not the
// packages' `dart test` — including photo_day_assignment's embedded IANA
// timezone data, the one dependency with data files that could plausibly
// load under one toolchain and not the other.
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn_model/cairn_model.dart';
import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:photo_day_assignment/photo_day_assignment.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  test('cairn_model: the vocabulary constructs', () {
    final date = CalendarDate(2026, 8, 22);
    expect(date.month, 8);
  });

  test('itinerary_parser: a pasted plan parses into days', () {
    final result = parseItinerary('''
Day 1 - Kyoto
09:00 Fushimi Inari
Day 2 - Nara
''');
    expect(result.days, hasLength(2));
    expect(result.days.first.stops, isNotEmpty);
  });

  test('trip_moments: the deal is a permutation of the party', () {
    final order = dealOrder(seedBase: 'trip_moments/v2|smoke', partySize: 4);
    expect(order.toSet(), {0, 1, 2, 3});
    expect(
      dealOrder(seedBase: 'trip_moments/v2|smoke', partySize: 4),
      order,
      reason: 'the derivation must be deterministic across calls',
    );
  });

  test('photo_day_assignment: GPS rung resolves via embedded tz data', () {
    final result = assignPhotoToDay(
      photo: const PhotoMetadata(
        exifLocalTimestamp: LocalDateTime(
          year: 2026,
          month: 8,
          day: 23,
          hour: 10,
        ),
        gpsLatitude: 35.6812,
        gpsLongitude: 139.7671,
      ),
      trip: TripDefinition(
        startDate: DateTime.utc(2026, 8, 22),
        numberOfDays: 5,
        defaultTimeZoneName: 'Asia/Tokyo',
      ),
    );
    expect(result.outcome, PhotoDayAssignmentOutcome.assigned);
    expect(result.dayNumber, 2);
    expect(result.resolvedTimeZoneName, 'Asia/Tokyo');
  });
}
