import 'package:photo_day_assignment/photo_day_assignment.dart';
import 'package:test/test.dart';

// Coordinates below are passed to the library as (latitude, longitude) on
// PhotoMetadata; the library itself is responsible for reordering them for
// timezone_finder's GeoJSON (longitude, latitude) convention.
const _tokyoLat = 35.6812, _tokyoLng = 139.7671;
const _londonLat = 51.5074, _londonLng = -0.1278;
const _losAngelesLat = 34.0522, _losAngelesLng = -118.2437;
const _midPacificLat = 0.0, _midPacificLng = -140.0; // open ocean

void main() {
  setUpAll(initializePhotoDayAssignment);

  group('a 7-day Tokyo trip (2026-03-10 .. 2026-03-16, Asia/Tokyo)', () {
    final trip = TripDefinition(
      startDate: DateTime(2026, 3, 10),
      numberOfDays: 7,
      defaultTimeZoneName: 'Asia/Tokyo',
    );

    test('a photo squarely inside a day is placed on that day, rung 1', () {
      final result = assignPhotoToDay(
        photo: PhotoMetadata(
          exifLocalTimestamp: const LocalDateTime(
            year: 2026,
            month: 3,
            day: 12,
            hour: 14,
            minute: 30,
          ),
          gpsLatitude: _tokyoLat,
          gpsLongitude: _tokyoLng,
        ),
        trip: trip,
      );

      expect(result.outcome, PhotoDayAssignmentOutcome.assigned);
      expect(result.dayNumber, 3);
      expect(result.method, PhotoDayAssignmentMethod.gpsTimezone);
      expect(result.confidence, PhotoDayAssignmentConfidence.high);
      expect(result.needsConfirmation, isFalse);
      expect(result.resolvedTimeZoneName, 'Asia/Tokyo');
    });

    test(
      '23:50 and 00:10 the same night land on two different, correct days',
      () {
        final lateNight = assignPhotoToDay(
          photo: PhotoMetadata(
            exifLocalTimestamp: const LocalDateTime(
              year: 2026,
              month: 3,
              day: 11,
              hour: 23,
              minute: 50,
            ),
            gpsLatitude: _tokyoLat,
            gpsLongitude: _tokyoLng,
          ),
          trip: trip,
        );
        final justAfterMidnight = assignPhotoToDay(
          photo: PhotoMetadata(
            exifLocalTimestamp: const LocalDateTime(
              year: 2026,
              month: 3,
              day: 12,
              hour: 0,
              minute: 10,
            ),
            gpsLatitude: _tokyoLat,
            gpsLongitude: _tokyoLng,
          ),
          trip: trip,
        );

        expect(lateNight.dayNumber, 2);
        expect(justAfterMidnight.dayNumber, 3);
        expect(justAfterMidnight.dayNumber, isNot(equals(lateNight.dayNumber)));
      },
    );

    test('crossing a timezone mid-trip: GPS gets it right, the trip-timezone '
        'fallback gets it wrong — this is the case the ladder exists for', () {
      // The traveller flew from Tokyo to London and, at what their camera
      // clock reads as "2026-03-14 20:00", is actually standing in London
      // (still GMT in March, no DST yet) — not Tokyo.
      const cameraReading = LocalDateTime(
        year: 2026,
        month: 3,
        day: 14,
        hour: 20,
      );

      final withGps = assignPhotoToDay(
        photo: PhotoMetadata(
          exifLocalTimestamp: cameraReading,
          gpsLatitude: _londonLat,
          gpsLongitude: _londonLng,
        ),
        trip: trip,
      );
      final gpsStripped = assignPhotoToDay(
        photo: PhotoMetadata(exifLocalTimestamp: cameraReading),
        trip: trip,
      );

      // Correct: GPS shows this instant is actually deep into day 6.
      expect(withGps.method, PhotoDayAssignmentMethod.gpsTimezone);
      expect(withGps.confidence, PhotoDayAssignmentConfidence.high);
      expect(withGps.dayNumber, 6);
      expect(withGps.resolvedTimeZoneName, 'Europe/London');

      // Wrong-if-trusted-blindly: without GPS, the same camera reading is
      // interpreted as Tokyo wall-clock time and lands a full day earlier.
      expect(gpsStripped.method, PhotoDayAssignmentMethod.tripTimezoneFallback);
      expect(gpsStripped.confidence, PhotoDayAssignmentConfidence.medium);
      expect(gpsStripped.needsConfirmation, isTrue);
      expect(gpsStripped.dayNumber, 5);

      expect(withGps.dayNumber, isNot(equals(gpsStripped.dayNumber)));
    });

    test('GPS-stripped photo (the common WhatsApp case): medium confidence, '
        'flagged, placed via the trip timezone', () {
      final result = assignPhotoToDay(
        photo: PhotoMetadata(
          exifLocalTimestamp: const LocalDateTime(
            year: 2026,
            month: 3,
            day: 11,
            hour: 9,
            minute: 15,
          ),
          // No gpsLatitude/gpsLongitude: stripped by WhatsApp, as ~89% of
          // forwarded photos are.
        ),
        trip: trip,
      );

      expect(result.outcome, PhotoDayAssignmentOutcome.assigned);
      expect(result.dayNumber, 2);
      expect(result.method, PhotoDayAssignmentMethod.tripTimezoneFallback);
      expect(result.confidence, PhotoDayAssignmentConfidence.medium);
      expect(result.needsConfirmation, isTrue);
      expect(result.resolvedTimeZoneName, 'Asia/Tokyo');
    });

    test('GPS present but unresolved (open ocean) falls through to the trip '
        'timezone, same as if GPS were absent', () {
      final result = assignPhotoToDay(
        photo: PhotoMetadata(
          exifLocalTimestamp: const LocalDateTime(
            year: 2026,
            month: 3,
            day: 11,
            hour: 9,
            minute: 15,
          ),
          gpsLatitude: _midPacificLat,
          gpsLongitude: _midPacificLng,
        ),
        trip: trip,
      );

      expect(result.method, PhotoDayAssignmentMethod.tripTimezoneFallback);
      expect(result.confidence, PhotoDayAssignmentConfidence.medium);
      expect(result.dayNumber, 2);
    });

    test('no EXIF timestamp: falls back to file-modified time, lowest '
        'confidence, always flagged', () {
      final result = assignPhotoToDay(
        photo: PhotoMetadata(
          fileModifiedTime: DateTime.utc(2026, 3, 13, 2, 0, 0),
        ),
        trip: trip,
      );

      expect(result.outcome, PhotoDayAssignmentOutcome.assigned);
      expect(result.dayNumber, 4);
      expect(result.method, PhotoDayAssignmentMethod.fileTimeFallback);
      expect(result.confidence, PhotoDayAssignmentConfidence.low);
      expect(result.needsConfirmation, isTrue);
      expect(result.resolvedTimeZoneName, isNull);
    });

    test('a photo with no usable metadata at all cannot be placed', () {
      final result = assignPhotoToDay(photo: const PhotoMetadata(), trip: trip);

      expect(result.outcome, PhotoDayAssignmentOutcome.insufficientMetadata);
      expect(result.dayNumber, isNull);
      expect(result.method, isNull);
      expect(result.confidence, isNull);
      expect(result.needsConfirmation, isTrue);
    });

    test('a photo dated before the trip is refused, not clamped to day 1', () {
      final result = assignPhotoToDay(
        photo: PhotoMetadata(
          exifLocalTimestamp: const LocalDateTime(
            year: 2026,
            month: 3,
            day: 5,
            hour: 10,
          ),
        ),
        trip: trip,
      );

      expect(result.outcome, PhotoDayAssignmentOutcome.outsideTrip);
      expect(result.dayNumber, isNull);
      expect(result.method, PhotoDayAssignmentMethod.tripTimezoneFallback);
      expect(result.needsConfirmation, isFalse);
    });

    test(
      'a photo dated after the trip is refused, not clamped to the last day',
      () {
        final result = assignPhotoToDay(
          photo: PhotoMetadata(
            exifLocalTimestamp: const LocalDateTime(
              year: 2026,
              month: 3,
              day: 20,
              hour: 10,
            ),
          ),
          trip: trip,
        );

        expect(result.outcome, PhotoDayAssignmentOutcome.outsideTrip);
        expect(result.dayNumber, isNull);
        expect(result.method, PhotoDayAssignmentMethod.tripTimezoneFallback);
      },
    );
  });

  group(
    'a trip that itself spans two timezones (New York, then Los Angeles)',
    () {
      // Days 1-3 in New York, days 4-6 in Los Angeles: a real multi-city
      // itinerary, not just "a photo happened to be taken abroad".
      final splitTrip = TripDefinition(
        startDate: DateTime(2026, 6, 1),
        numberOfDays: 6,
        defaultTimeZoneName: 'America/New_York',
        timeZoneOverridesByDay: const {
          4: 'America/Los_Angeles',
          5: 'America/Los_Angeles',
          6: 'America/Los_Angeles',
        },
      );
      final singleZoneTrip = TripDefinition(
        startDate: DateTime(2026, 6, 1),
        numberOfDays: 6,
        defaultTimeZoneName: 'America/New_York',
      );

      // 9:30pm local Los Angeles time on the LA leg's first calendar day.
      final lateLaEvening = PhotoMetadata(
        exifLocalTimestamp: const LocalDateTime(
          year: 2026,
          month: 6,
          day: 4,
          hour: 21,
          minute: 30,
        ),
        gpsLatitude: _losAngelesLat,
        gpsLongitude: _losAngelesLng,
      );

      test('with the per-day override, day 4 boundaries use Los Angeles time '
          'and the photo lands on day 4', () {
        final result = assignPhotoToDay(photo: lateLaEvening, trip: splitTrip);

        expect(result.outcome, PhotoDayAssignmentOutcome.assigned);
        expect(result.dayNumber, 4);
        expect(result.method, PhotoDayAssignmentMethod.gpsTimezone);
        expect(result.resolvedTimeZoneName, 'America/Los_Angeles');
      });

      test('without the override, the same photo — evaluated against day '
          "boundaries drawn in New York time — spills into day 5, proving "
          'the per-day override is what fixed it', () {
        final result = assignPhotoToDay(
          photo: lateLaEvening,
          trip: singleZoneTrip,
        );

        expect(result.dayNumber, 5);
      });
    },
  );
}
