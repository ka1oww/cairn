// Measures a real corpus of photographs, then prices what a Cairn trip's
// pool of them costs to keep.
//
// Why this exists: the repo carried two written guesses at the storage bill
// that disagreed by about two years, and neither had been measured. The pool
// keeps **originals** (docs/decisions/2026-08-22-grill-round-one.md §3), so
// the bill is a function of what an original actually weighs, which is a fact
// about phones and not a thing to reason about from an armchair.
//
// Run it against any directory of photographs:
//
//     dart run tool/measure_photo_corpus.dart <dir> [<dir> ...]
//
// e.g. a Photos library's untouched originals on macOS:
//
//     dart run tool/measure_photo_corpus.dart \
//       ~/Pictures/'Photos Library.photoslibrary'/originals
//
// It reads sizes only. It never opens a file, never copies one, and prints
// no filename -- the output is aggregate statistics, so pointing it at a
// private library leaks nothing into a terminal or a commit.
//
// The trip model is tunable, because a trip is not one shape:
//
//     --people 8 --days 14 --per-person-per-day 1 --trips-per-year 5
//
// The recorded result and the conclusions drawn from it live in
// docs/storage-and-cost.md. Re-run this before editing that number.
import 'dart:io';
import 'dart:math' as math;

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

/// What counts as a photograph for this measurement.
///
/// Raw formats are in deliberately: a phone set to shoot ProRAW writes them
/// into the same roll, and the pool would keep those originals too.
const photoExtensions = {
  'jpg',
  'jpeg',
  'heic',
  'heif',
  'png',
  'dng',
  'tif',
  'tiff',
  'webp',
};

/// The size distribution of one corpus of photographs.
class CorpusStats {
  CorpusStats._(this.sizes, this.byExtension);

  /// Every file's size in bytes, ascending.
  final List<int> sizes;

  /// Sizes per lower-cased extension, ascending within each.
  final Map<String, List<int>> byExtension;

  factory CorpusStats.of(
    Iterable<int> sizes, {
    Map<String, List<int>> byExtension = const {},
  }) {
    final sorted = sizes.toList()..sort();
    final grouped = {
      for (final entry in byExtension.entries)
        entry.key: (entry.value.toList()..sort()),
    };
    return CorpusStats._(sorted, grouped);
  }

  int get count => sizes.length;
  int get totalBytes => sizes.fold(0, (a, b) => a + b);
  int get min => sizes.isEmpty ? 0 : sizes.first;
  int get max => sizes.isEmpty ? 0 : sizes.last;
  double get mean => sizes.isEmpty ? 0 : totalBytes / sizes.length;

  /// The [p]th percentile by nearest rank, so every value returned is a real
  /// file's size rather than an interpolation between two of them.
  int percentile(double p) {
    if (sizes.isEmpty) return 0;
    final rank = (p / 100 * sizes.length).ceil();
    return sizes[math.max(0, math.min(sizes.length - 1, rank - 1))];
  }

  int get median => percentile(50);
}

/// Walks [roots] and measures every photograph under them.
///
/// Unreadable entries are counted and skipped rather than thrown on: a photo
/// library is full of directories a user process may not enter, and a
/// measurement that dies on the first of them measures nothing.
({CorpusStats stats, int skipped}) measureDirectories(
  Iterable<String> roots, {
  int minBytes = 0,
}) {
  final sizes = <int>[];
  final byExtension = <String, List<int>>{};
  var skipped = 0;

  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      stderr.writeln('no such directory: $root');
      continue;
    }
    late final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      skipped++;
      continue;
    }
    for (final entity in entries) {
      if (entity is! File) continue;
      final ext = _extensionOf(entity.path);
      if (!photoExtensions.contains(ext)) continue;
      try {
        final size = entity.lengthSync();
        if (size < minBytes) continue;
        sizes.add(size);
        (byExtension[ext] ??= <int>[]).add(size);
      } on FileSystemException {
        skipped++;
      }
    }
  }
  return (
    stats: CorpusStats.of(sizes, byExtension: byExtension),
    skipped: skipped,
  );
}

String _extensionOf(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

// ---------------------------------------------------------------------------
// The bill
// ---------------------------------------------------------------------------

/// Cloudflare R2 pricing, Standard storage, read 2026-08-25 from
/// https://developers.cloudflare.com/r2/pricing/ (unchanged from the
/// 2026-08-21 reading recorded in supabase/README.md).
class R2Pricing {
  /// The free allowance, per month.
  static const freeStorageGbMonth = 10.0;
  static const freeClassAOpsPerMonth = 1000000;
  static const freeClassBOpsPerMonth = 10000000;

  /// USD per GB-month beyond the allowance.
  static const usdPerGbMonth = 0.015;

  /// USD per million operations beyond the allowance. Class A is
  /// writes/lists, Class B is reads.
  static const usdPerMillionClassA = 4.50;
  static const usdPerMillionClassB = 0.36;

  /// R2 charges nothing for bandwidth out, at any tier. This is the whole
  /// reason the bytes are here rather than in Supabase storage.
  static const usdPerGbEgress = 0.0;
}

const bytesPerGb = 1000 * 1000 * 1000;

/// One trip's shape, and what its pool weighs.
class TripEstimate {
  const TripEstimate({
    required this.people,
    required this.days,
    required this.photosPerPersonPerDay,
    required this.bytesPerPhoto,
  });

  final int people;
  final int days;
  final double photosPerPersonPerDay;

  /// The measured size of one original.
  final int bytesPerPhoto;

  double get photos => people * days * photosPerPersonPerDay;
  double get bytes => photos * bytesPerPhoto;
  double get gb => bytes / bytesPerGb;

  /// What one such trip costs to keep for a month, once the free allowance
  /// is already spent by earlier trips.
  double get marginalUsdPerMonth => gb * R2Pricing.usdPerGbMonth;

  /// How many trips of this shape fit inside the free 10 GB-month.
  double get tripsInsideFreeTier => R2Pricing.freeStorageGbMonth / gb;
}

/// What a whole archive costs in the month it reaches [totalGb], counting the
/// free allowance.
double archiveUsdPerMonth(double totalGb) =>
    math.max(0, totalGb - R2Pricing.freeStorageGbMonth) *
    R2Pricing.usdPerGbMonth;

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

String mb(num bytes) => '${(bytes / (1000 * 1000)).toStringAsFixed(2)} MB';
String gbOf(num bytes) => '${(bytes / bytesPerGb).toStringAsFixed(2)} GB';
String usd(num amount) => '\$${amount.toStringAsFixed(2)}';

void main(List<String> args) {
  final roots = <String>[];
  var people = 8;
  var days = 14;
  var perPersonPerDay = 1.0;
  var tripsPerYear = 5;
  var minBytes = 0;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String next() {
      if (i + 1 >= args.length) {
        stderr.writeln('$arg needs a value');
        exit(2);
      }
      return args[++i];
    }

    switch (arg) {
      case '--people':
        people = int.parse(next());
      case '--days':
        days = int.parse(next());
      case '--per-person-per-day':
        perPersonPerDay = double.parse(next());
      case '--trips-per-year':
        tripsPerYear = int.parse(next());
      case '--min-bytes':
        minBytes = int.parse(next());
      case '--help' || '-h':
        stdout.writeln(_usage);
        return;
      default:
        if (arg.startsWith('-')) {
          stderr.writeln('unknown flag: $arg\n\n$_usage');
          exit(2);
        }
        roots.add(arg);
    }
  }

  if (roots.isEmpty) {
    stderr.writeln(_usage);
    exit(2);
  }

  final measured = measureDirectories(roots, minBytes: minBytes);
  final stats = measured.stats;
  if (stats.count == 0) {
    stderr.writeln('no photographs found under: ${roots.join(', ')}');
    exit(1);
  }

  stdout.writeln('CORPUS');
  stdout.writeln('  files          ${stats.count}');
  stdout.writeln('  total          ${gbOf(stats.totalBytes)}');
  stdout.writeln('  mean           ${mb(stats.mean)}');
  stdout.writeln('  median         ${mb(stats.median)}');
  stdout.writeln('  p10            ${mb(stats.percentile(10))}');
  stdout.writeln('  p90            ${mb(stats.percentile(90))}');
  stdout.writeln('  p99            ${mb(stats.percentile(99))}');
  stdout.writeln('  min / max      ${mb(stats.min)} / ${mb(stats.max)}');
  if (measured.skipped > 0) {
    stdout.writeln('  unreadable     ${measured.skipped} (skipped)');
  }

  stdout.writeln('\nBY FORMAT (count, median, mean)');
  final formats = stats.byExtension.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final entry in formats) {
    final sub = CorpusStats.of(entry.value);
    stdout.writeln(
      '  ${entry.key.padRight(6)} '
      '${sub.count.toString().padLeft(7)}  '
      '${mb(sub.median).padLeft(10)}  ${mb(sub.mean).padLeft(10)}',
    );
  }

  stdout.writeln(
    '\nONE TRIP: $people people x $days days x $perPersonPerDay photo(s)/person/day',
  );
  for (final reading in [
    ('median original', stats.median),
    ('mean original', stats.mean.round()),
    ('p90 original', stats.percentile(90)),
  ]) {
    final estimate = TripEstimate(
      people: people,
      days: days,
      photosPerPersonPerDay: perPersonPerDay,
      bytesPerPhoto: reading.$2,
    );
    stdout.writeln(
      '  ${reading.$1.padRight(18)}'
      '${estimate.photos.round()} photos  '
      '${gbOf(estimate.bytes).padLeft(9)}  '
      'free tier holds ${estimate.tripsInsideFreeTier.toStringAsFixed(1)} trips  '
      '${usd(estimate.marginalUsdPerMonth)}/month each beyond it',
    );
  }

  stdout.writeln('\nARCHIVE at $tripsPerYear trips/year (median original)');
  final perTrip = TripEstimate(
    people: people,
    days: days,
    photosPerPersonPerDay: perPersonPerDay,
    bytesPerPhoto: stats.median,
  );
  for (final year in [1, 2, 3, 5]) {
    final totalGb = perTrip.gb * tripsPerYear * year;
    final monthly = archiveUsdPerMonth(totalGb);
    stdout.writeln(
      '  year ${year.toString().padRight(2)} '
      '${totalGb.toStringAsFixed(1).padLeft(7)} GB stored   '
      '${usd(monthly).padLeft(8)}/month   '
      '${usd(monthly * 12).padLeft(8)}/year',
    );
  }
}

const _usage = '''
Measures a corpus of photographs and prices a Cairn trip's pool of them.

  dart run tool/measure_photo_corpus.dart <dir> [<dir> ...] [flags]

Flags (defaults in brackets):
  --people N                 people on the trip [8]
  --days N                   days of the trip [14]
  --per-person-per-day N     photos each person contributes a day [1]
  --trips-per-year N         trips the archive accumulates a year [5]
  --min-bytes N              ignore files smaller than this [0]

Reads sizes only. Prints no filename.''';
