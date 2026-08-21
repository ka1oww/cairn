import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone_finder/timezone_finder.dart' as tzf;

import 'local_date_time.dart';
import 'photo_metadata.dart';
import 'result.dart';
import 'trip_definition.dart';

bool _initialized = false;

/// Loads the IANA timezone database used for every zone lookup in this
/// package. Idempotent and cheap to call more than once. [assignPhotoToDay]
/// calls this lazily on first use, so calling it explicitly is only useful
/// to pay the (small, one-time) decode cost at a predictable moment, e.g.
/// app startup.
///
/// Uses `timezone`'s `latest_all` database rather than the default `latest`
/// one: `timezone_finder`'s land-boundary data references 106 IANA
/// identifiers that `latest` omits, and a lookup landing on one of those
/// would throw instead of returning a zone. See the README's "timezone
/// lookup" section.
void initializePhotoDayAssignment() {
  if (_initialized) return;
  tzdata.initializeTimeZones();
  _initialized = true;
}

/// Decides which day of [trip] the photo described by [photo] belongs to.
///
/// Walks the degradation ladder described in the README, best evidence
/// first:
///
/// 1. GPS present and it resolves to a land timezone, and an EXIF timestamp
///    is present: interpret the EXIF wall-clock time in that timezone.
/// 2. GPS absent (or present but unresolved — open ocean, etc.), EXIF
///    present: interpret the EXIF wall-clock time in the *trip's* timezone
///    instead.
/// 3. No EXIF timestamp: fall back to [PhotoMetadata.fileModifiedTime].
/// 4. Nothing usable at all: [PhotoDayAssignmentOutcome.insufficientMetadata].
///
/// Whichever rung produces a candidate instant, that instant is then checked
/// against the trip's day windows. An instant before day 1's start or at/after
/// the last day's end is never clamped to a boundary day — it comes back as
/// [PhotoDayAssignmentOutcome.outsideTrip].
PhotoDayAssignmentResult assignPhotoToDay({
  required PhotoMetadata photo,
  required TripDefinition trip,
}) {
  initializePhotoDayAssignment();

  final exif = photo.exifLocalTimestamp;

  if (exif != null && photo.hasUsableGps) {
    final zone = tzf.findLocation(photo.gpsLongitude!, photo.gpsLatitude!);
    if (zone != null) {
      final instant = _interpretLocalAsUtc(exif, zone);
      return _place(
        trip: trip,
        instantUtc: instant,
        method: PhotoDayAssignmentMethod.gpsTimezone,
        confidence: PhotoDayAssignmentConfidence.high,
        resolvedTimeZoneName: zone.name,
        assignedExplanation: (day) =>
            'Placed on day $day because of where it was taken '
            '(GPS resolved to ${zone.name}).',
        outsideExplanation: () =>
            "GPS resolved to ${zone.name}; the resulting time falls outside "
            "the trip's date range, so it was not placed on any day.",
      );
    }
    // GPS present but didn't resolve to a land timezone (open ocean, or
    // outside the ~22km coastal buffer around the nearest land polygon) —
    // fall through to rung 2, same as if GPS were absent.
  }

  if (exif != null) {
    final zone = tz.getLocation(trip.defaultTimeZoneName);
    final instant = _interpretLocalAsUtc(exif, zone);
    return _place(
      trip: trip,
      instantUtc: instant,
      method: PhotoDayAssignmentMethod.tripTimezoneFallback,
      confidence: PhotoDayAssignmentConfidence.medium,
      resolvedTimeZoneName: zone.name,
      assignedExplanation: (day) =>
          "Guessed day $day from the EXIF date alone, interpreted in the "
          "trip's timezone (${zone.name}) because no GPS location was "
          "available. Flagged for confirmation: if this photo was actually "
          "taken in a different timezone, it may be on the wrong day.",
      outsideExplanation: () =>
          "EXIF time interpreted in the trip's timezone (${zone.name}) "
          "falls outside the trip's date range.",
    );
  }

  final fileTime = photo.fileModifiedTime;
  if (fileTime != null) {
    final instant = fileTime.toUtc();
    return _place(
      trip: trip,
      instantUtc: instant,
      method: PhotoDayAssignmentMethod.fileTimeFallback,
      confidence: PhotoDayAssignmentConfidence.low,
      resolvedTimeZoneName: null,
      assignedExplanation: (day) =>
          "Guessed day $day from the file's last-modified time only — no "
          "EXIF timestamp was available. This is the lowest-confidence "
          "placement and is always flagged for confirmation.",
      outsideExplanation: () =>
          "The file's last-modified time falls outside the trip's date "
          "range.",
    );
  }

  return PhotoDayAssignmentResult.insufficientMetadata();
}

DateTime _interpretLocalAsUtc(LocalDateTime local, tz.Location location) {
  final zoned = tz.TZDateTime(
    location,
    local.year,
    local.month,
    local.day,
    local.hour,
    local.minute,
    local.second,
  );
  return zoned.toUtc();
}

PhotoDayAssignmentResult _place({
  required TripDefinition trip,
  required DateTime instantUtc,
  required PhotoDayAssignmentMethod method,
  required PhotoDayAssignmentConfidence confidence,
  required String? resolvedTimeZoneName,
  required String Function(int day) assignedExplanation,
  required String Function() outsideExplanation,
}) {
  final day = _findDay(trip, instantUtc);
  if (day != null) {
    return PhotoDayAssignmentResult.assignedTo(
      dayNumber: day,
      method: method,
      confidence: confidence,
      explanation: assignedExplanation(day),
      resolvedTimeZoneName: resolvedTimeZoneName,
      resolvedInstantUtc: instantUtc,
    );
  }
  return PhotoDayAssignmentResult.outsideTrip(
    method: method,
    confidence: confidence,
    explanation: outsideExplanation(),
    resolvedTimeZoneName: resolvedTimeZoneName,
    resolvedInstantUtc: instantUtc,
  );
}

/// Finds the 1-based day number whose [midnight, next midnight) window (each
/// computed in that day's own timezone — see [TripDefinition]) contains
/// [instantUtc], or `null` if no day's window contains it.
int? _findDay(TripDefinition trip, DateTime instantUtc) {
  for (var day = 1; day <= trip.numberOfDays; day++) {
    final zoneName = trip.timeZoneNameForDay(day);
    final location = tz.getLocation(zoneName);
    final date = trip.calendarDateForDay(day);
    final start = tz.TZDateTime(
      location,
      date.year,
      date.month,
      date.day,
    ).toUtc();
    final end = tz.TZDateTime(
      location,
      date.year,
      date.month,
      date.day + 1,
    ).toUtc();
    if (!instantUtc.isBefore(start) && instantUtc.isBefore(end)) {
      return day;
    }
  }
  return null;
}
