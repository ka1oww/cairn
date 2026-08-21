/// Which rung of the degradation ladder produced the candidate instant that
/// [PhotoDayAssignmentResult] was placed (or refused) with.
///
/// There is deliberately no "rung 4" value here for "outside the trip" — that
/// is an [PhotoDayAssignmentOutcome], not a method, because a candidate
/// instant computed by *any* of these three methods can turn out to fall
/// outside the trip.
enum PhotoDayAssignmentMethod {
  /// Rung 1. GPS coordinates resolved to a timezone; the EXIF local time was
  /// interpreted in that zone.
  gpsTimezone,

  /// Rung 2. No usable GPS (absent, or present but not resolvable to a land
  /// timezone — e.g. open ocean); the EXIF local time was interpreted in the
  /// *trip's* timezone instead. This is where a cross-timezone photo can land
  /// on the wrong day — see the README.
  tripTimezoneFallback,

  /// Rung 3. No EXIF timestamp at all; fell back to the file's last-modified
  /// time, which is a real instant but usually reflects when the file was
  /// saved/forwarded/re-encoded, not when the photo was taken.
  fileTimeFallback,
}

/// How much to trust a [PhotoDayAssignmentResult]'s day placement.
enum PhotoDayAssignmentConfidence {
  /// Rung 1 (GPS resolved). Both "where" and "when" are known.
  high,

  /// Rung 2 (trip-timezone fallback). "When" (the wall clock reading) is
  /// known but "where" was assumed, not observed — assumed wrong for a
  /// cross-timezone photo.
  medium,

  /// Rung 3 (file-time fallback). Neither "where" nor the true "when" is
  /// known; only when the file was last touched.
  low,
}

/// The top-level shape of a placement attempt.
enum PhotoDayAssignmentOutcome {
  /// A day number was assigned. Check [PhotoDayAssignmentResult.confidence]
  /// and [PhotoDayAssignmentResult.needsConfirmation] before treating it as
  /// final.
  assigned,

  /// A candidate instant was computed (via [PhotoDayAssignmentResult.method])
  /// but it falls before the trip's first day or after its last day. Never
  /// clamped to day 1 or the last day — the photo is reported as not part of
  /// this trip so the app layer can decide what to do (e.g. offer it to a
  /// different trip, or let the user attach it manually).
  outsideTrip,

  /// No usable timestamp existed at all: no EXIF local time and no file
  /// modified time. There is nothing to place — this is not the same as
  /// [outsideTrip], which means a timestamp *was* placed, just outside the
  /// trip's range.
  insufficientMetadata,
}

/// The result of attempting to place one photo on one trip day.
///
/// Every result carries [outcome], and whenever a candidate instant was
/// actually computed ([outcome] is [PhotoDayAssignmentOutcome.assigned] or
/// [PhotoDayAssignmentOutcome.outsideTrip]) it also carries [method] and
/// [confidence] — the "how it was decided" and "how confident" the task
/// requires. Only [PhotoDayAssignmentOutcome.insufficientMetadata] leaves
/// those `null`, because no method was ever tried.
class PhotoDayAssignmentResult {
  final PhotoDayAssignmentOutcome outcome;

  /// The assigned day number (1-based), non-null iff [outcome] is
  /// [PhotoDayAssignmentOutcome.assigned].
  final int? dayNumber;

  /// Which ladder rung produced [resolvedInstantUtc]. Null only for
  /// [PhotoDayAssignmentOutcome.insufficientMetadata].
  final PhotoDayAssignmentMethod? method;

  /// How much to trust this placement. Null only for
  /// [PhotoDayAssignmentOutcome.insufficientMetadata].
  final PhotoDayAssignmentConfidence? confidence;

  /// True when the confirmation UI should ask the user before treating this
  /// placement as final: every [PhotoDayAssignmentConfidence.medium] or
  /// [PhotoDayAssignmentConfidence.low] result, and every
  /// [PhotoDayAssignmentOutcome.insufficientMetadata] result (which needs a
  /// day chosen manually, not merely confirmed). High-confidence assignments
  /// and confident exclusions ([PhotoDayAssignmentOutcome.outsideTrip]) do
  /// not need confirmation.
  final bool needsConfirmation;

  /// A human-readable explanation, safe to show directly in a debug view or
  /// adapt for the confirmation UI (e.g. "we placed this on Day 4 because of
  /// where it was taken" vs. "we guessed Day 4 from the date alone").
  final String explanation;

  /// The IANA zone name actually used to interpret the EXIF local time, when
  /// one was used (rungs 1 and 2). Null for [PhotoDayAssignmentMethod.fileTimeFallback]
  /// (no local-time interpretation happens) and for
  /// [PhotoDayAssignmentOutcome.insufficientMetadata].
  final String? resolvedTimeZoneName;

  /// The candidate instant (in UTC) that was compared against the trip's day
  /// windows, when one was computed. Exposed mainly for debugging/testing.
  final DateTime? resolvedInstantUtc;

  const PhotoDayAssignmentResult._({
    required this.outcome,
    required this.dayNumber,
    required this.method,
    required this.confidence,
    required this.needsConfirmation,
    required this.explanation,
    required this.resolvedTimeZoneName,
    required this.resolvedInstantUtc,
  });

  factory PhotoDayAssignmentResult.assignedTo({
    required int dayNumber,
    required PhotoDayAssignmentMethod method,
    required PhotoDayAssignmentConfidence confidence,
    required String explanation,
    required String? resolvedTimeZoneName,
    required DateTime resolvedInstantUtc,
  }) => PhotoDayAssignmentResult._(
    outcome: PhotoDayAssignmentOutcome.assigned,
    dayNumber: dayNumber,
    method: method,
    confidence: confidence,
    needsConfirmation: confidence != PhotoDayAssignmentConfidence.high,
    explanation: explanation,
    resolvedTimeZoneName: resolvedTimeZoneName,
    resolvedInstantUtc: resolvedInstantUtc,
  );

  factory PhotoDayAssignmentResult.outsideTrip({
    required PhotoDayAssignmentMethod method,
    required PhotoDayAssignmentConfidence confidence,
    required String explanation,
    required String? resolvedTimeZoneName,
    required DateTime resolvedInstantUtc,
  }) => PhotoDayAssignmentResult._(
    outcome: PhotoDayAssignmentOutcome.outsideTrip,
    dayNumber: null,
    method: method,
    confidence: confidence,
    needsConfirmation: false,
    explanation: explanation,
    resolvedTimeZoneName: resolvedTimeZoneName,
    resolvedInstantUtc: resolvedInstantUtc,
  );

  factory PhotoDayAssignmentResult.insufficientMetadata({
    String? explanation,
  }) => PhotoDayAssignmentResult._(
    outcome: PhotoDayAssignmentOutcome.insufficientMetadata,
    dayNumber: null,
    method: null,
    confidence: null,
    needsConfirmation: true,
    explanation:
        explanation ??
        'No EXIF timestamp and no file modified time were available; '
            'this photo cannot be placed automatically.',
    resolvedTimeZoneName: null,
    resolvedInstantUtc: null,
  );

  @override
  String toString() =>
      'PhotoDayAssignmentResult('
      'outcome: $outcome, day: $dayNumber, method: $method, '
      'confidence: $confidence, needsConfirmation: $needsConfirmation)';
}
