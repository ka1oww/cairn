// The measurement behind docs/storage-and-cost.md.
//
// The number in that file is only worth what its arithmetic is worth, and the
// arithmetic is the thing nobody re-checks once a figure is written down. So
// the statistics, the walk and the pricing are pinned here — including the
// two mistakes the measurement actually made on the way: taking a median over
// a whole photo library rather than over camera originals, and treating R2's
// 10 GB as a lifetime allowance rather than a monthly one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/measure_photo_corpus.dart';

void main() {
  group('the corpus statistics', () {
    test('an empty corpus answers zero rather than throwing', () {
      final stats = CorpusStats.of(const []);
      expect(stats.count, 0);
      expect(stats.totalBytes, 0);
      expect(stats.median, 0);
      expect(stats.mean, 0);
      expect(stats.percentile(90), 0);
    });

    test('a percentile is a real file size, never an interpolation', () {
      // Nearest rank on purpose: "the median photo is 2.80 MB" should name a
      // photograph that exists, not a point between two of them.
      final stats = CorpusStats.of([10, 20, 30, 40]);
      expect(stats.median, 20);
      expect(stats.percentile(100), 40);
      expect(stats.percentile(1), 10);
      expect(stats.sizes, [10, 20, 30, 40]);
    });

    test('sizes are sorted however they arrive', () {
      final stats = CorpusStats.of([40, 10, 30, 20]);
      expect(stats.min, 10);
      expect(stats.max, 40);
      expect(stats.median, 20);
      expect(stats.mean, 25);
    });

    test('a median is not a mean, and a skewed library is why it matters', () {
      // The shape of the real library: a long tail of small re-compressions
      // under a handful of camera originals. Quoting the wrong one is how
      // the estimate this file exists to replace went wrong.
      final stats = CorpusStats.of([
        for (var i = 0; i < 90; i++) 50000,
        for (var i = 0; i < 10; i++) 3000000,
      ]);
      expect(stats.median, 50000);
      expect(stats.mean, greaterThan(stats.median * 5));
    });
  });

  group('walking a directory', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('cairn_corpus'));
    tearDown(() => root.deleteSync(recursive: true));

    void write(String name, int bytes) {
      final file = File('${root.path}/$name');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(List.filled(bytes, 0));
    }

    test('only image files count, and they count once each', () {
      write('a.jpg', 100);
      write('nested/b.HEIC', 200);
      write('notes.txt', 999);
      write('no-extension', 999);

      final measured = measureDirectories([root.path]);
      expect(measured.stats.count, 2);
      expect(measured.stats.totalBytes, 300);
      // The extension is folded to lower case, so a corpus does not split
      // itself in two over how a phone happened to name its files.
      expect(measured.stats.byExtension.keys, containsAll(['jpg', 'heic']));
    });

    test('a size floor is how camera originals are separated out', () {
      write('screenshot.png', 20000);
      write('whatsapp.jpg', 60000);
      write('camera.heic', 2200000);

      expect(measureDirectories([root.path]).stats.count, 3);
      final originals =
          measureDirectories([root.path], minBytes: 1000000).stats;
      expect(originals.count, 1);
      expect(originals.median, 2200000);
    });

    test('a directory that is not there is skipped, not fatal', () {
      write('a.jpg', 100);
      final measured =
          measureDirectories([root.path, '${root.path}/nope-not-here']);
      expect(measured.stats.count, 1);
    });
  });

  group('the bill', () {
    // Eight people, a fortnight, at the ping's own volume: the shape the app
    // actually produces today, priced off the measured median original.
    const measuredMedianBytes = 2800000;
    const trip = TripEstimate(
      people: 8,
      days: 14,
      photosPerPersonPerDay: 1,
      bytesPerPhoto: measuredMedianBytes,
    );

    test('a trip is people x days x photos each', () {
      expect(trip.photos, 112);
      expect(trip.bytes, 112 * measuredMedianBytes);
      expect(trip.gb, closeTo(0.31, 0.01));
    });

    test('the free tier holds about thirty-two such trips', () {
      // The headline in docs/storage-and-cost.md. If this moves, that file
      // is wrong.
      expect(trip.tripsInsideFreeTier, closeTo(31.9, 0.5));
    });

    test('importing a whole roll is what moves the bill, not the trip', () {
      const imported = TripEstimate(
        people: 8,
        days: 14,
        photosPerPersonPerDay: 10,
        bytesPerPhoto: measuredMedianBytes,
      );
      expect(imported.gb, closeTo(3.14, 0.01));
      expect(imported.tripsInsideFreeTier, closeTo(3.2, 0.1));
    });

    test('the 10 GB is a standing monthly allowance, not a lifetime one', () {
      // Read as a lifetime budget it would look like the archive stops being
      // free forever after the first few trips. It does not: the bill is
      // whatever is held *this month*, minus the allowance.
      expect(archiveUsdPerMonth(9.9), 0);
      expect(archiveUsdPerMonth(10), 0);
      expect(archiveUsdPerMonth(110), closeTo(1.5, 0.001));
    });

    test('an archive under the allowance bills nothing at all', () {
      // Five trips a year at the ping's volume: 1.6 GB in year one, and
      // still under 10 GB in year five.
      expect(archiveUsdPerMonth(trip.gb * 5), 0);
      expect(archiveUsdPerMonth(trip.gb * 5 * 5), 0);
      expect(archiveUsdPerMonth(trip.gb * 5 * 7), greaterThan(0));
    });

    test('egress is free, which is the whole reason the bytes are on R2', () {
      expect(R2Pricing.usdPerGbEgress, 0);
    });
  });
}
