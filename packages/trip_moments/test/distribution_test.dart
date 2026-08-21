// Daily moments must be spread across the quiet window, not clustered
// near one edge or one hour. We check this by bucketing many dates'
// moments and asserting no bucket is wildly over/under-represented, plus
// that the values actually span close to the full window.

import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  test('daily moments across many dates spread across the window', () {
    const tripId = 'trip-distribution';
    const window = QuietWindow.standard; // 09:00-21:00, 12h span
    const offset = Duration.zero;

    const sampleCount = 400;
    final start = DateTime(2024, 1, 1);
    final fractions = <double>[];

    for (var i = 0; i < sampleCount; i++) {
      final date = start.add(Duration(days: i));
      final moment = dailyMoment(
        tripId: tripId,
        date: date,
        tripUtcOffset: offset,
        window: window,
      );
      final minutesIntoWindow = moment
              .difference(DateTime.utc(date.year, date.month, date.day))
              .inMinutes -
          window.start.inMinutes;
      final fraction = minutesIntoWindow / window.span.inMinutes;
      expect(fraction, inInclusiveRange(0.0, 1.0));
      fractions.add(fraction);
    }

    // 1. The samples should cover close to the whole window, not just a
    // sliver of it.
    fractions.sort();
    expect(fractions.first, lessThan(0.05));
    expect(fractions.last, greaterThan(0.95));

    // 2. Bucket into deciles and check no bucket is drastically over- or
    // under-populated compared to a uniform expectation, i.e. no
    // clustering.
    const bucketCount = 10;
    final buckets = List<int>.filled(bucketCount, 0);
    for (final f in fractions) {
      var idx = (f * bucketCount).floor();
      if (idx >= bucketCount) idx = bucketCount - 1;
      buckets[idx]++;
    }
    final expectedPerBucket = sampleCount / bucketCount;
    for (final count in buckets) {
      // Generous tolerance: within 60% of the uniform expectation. This
      // is a sanity check against gross clustering, not a strict
      // statistical uniformity test.
      expect(
        count,
        inInclusiveRange(expectedPerBucket * 0.4, expectedPerBucket * 1.6),
      );
    }

    // 3. The mean fraction should be roughly centered.
    final mean = fractions.reduce((a, b) => a + b) / fractions.length;
    expect(mean, inInclusiveRange(0.35, 0.65));
  });

  test('every daily moment falls strictly inside the configured window', () {
    const tripId = 'trip-window-bounds';
    const window = QuietWindow(
      start: Duration(hours: 10),
      end: Duration(hours: 18),
    );
    const offset = Duration(hours: -5);
    final start = DateTime(2025, 6, 1);

    for (var i = 0; i < 200; i++) {
      final date = start.add(Duration(days: i));
      final moment = dailyMoment(
        tripId: tripId,
        date: date,
        tripUtcOffset: offset,
        window: window,
      );
      final localMidnight =
          DateTime.utc(date.year, date.month, date.day).subtract(offset);
      final sinceMidnight = moment.difference(localMidnight);
      expect(sinceMidnight, greaterThanOrEqualTo(window.start));
      expect(sinceMidnight, lessThanOrEqualTo(window.end));
    }
  });
}
