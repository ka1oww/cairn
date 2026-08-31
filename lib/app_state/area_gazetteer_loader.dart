// APP STATE band (docs/architecture.md): the area gazetteer's one load.
//
// The C10 validator (the tap-to-Maps plan §9) checks a candidate area name
// against a real gazetteer before it is allowed to become an area, which is
// what kills the junk the vocabulary run alone admits ('UNAGI', 'UDON').
// The gazetteer is ~1 MB of compressed asset per country and a few hundred
// thousand names once inflated, so *when* it is read is a decision, not a
// detail. Three rules, and all three are load-bearing:
//
//  1. **On import only.** A person who typed their plan by hand parses with
//     no gazetteer at all, exactly as phase 1 did — `gazetteer: null` is
//     phase-1 behaviour and the parser's C7t floors are pinned without one
//     forever. Reading a file is already a slow, explicitly-asked-for act
//     with a progress pill in front of it, so it is the one place a load
//     this size is free.
//  2. **Never at launch, and never on the day or trail path.** Nothing in
//     `main()` or `bootstrap.dart` touches this file; the app opens on the
//     paste box without a byte of it read.
//  3. **Off the UI thread**, on `import_flow.dart`'s own seam: production
//     hands the inflate-and-sort to `Isolate.run`, tests inject the direct
//     call, because a real isolate under the widget tests' fake clock hangs
//     silently (CLAUDE.md). Only the `rootBundle` read stays on the UI
//     thread, because an asset read is a platform channel and cannot leave
//     it — it is a byte copy, not the work.
//
// The load happens once per launch and is remembered: [AreaGazetteerLoader]
// is a `Notifier` holding a nullable gazetteer, null until the first import
// finishes filling it, and `PasteFlow` reads whatever is there when it
// parses. So the failure mode of every part of this file is *phase-1
// behaviour*, never a broken parse — a missing asset, a corrupt asset or a
// dead isolate all leave the value null and the parser reads the plan the
// way it read it before phase 2 existed.
import 'dart:convert';
// `gzip` only — the app is iOS-only (CLAUDE.md) and this is a byte codec,
// not a file-system reach.
import 'dart:io' show gzip;
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

/// The committed assets, by name. One per country, and the country set is
/// the plan's recommendation (§9.2) — the three countries the area corpus
/// actually measured — not a limit of anything here: adding a country is a
/// `tool/build_area_gazetteer.dart` run and one line in this list.
const List<String> areaGazetteerAssets = [
  'assets/area_gazetteer/jp.txt.gz',
  'assets/area_gazetteer/fr.txt.gz',
  'assets/area_gazetteer/kr.txt.gz',
];

/// What one load cost, so that "off the UI thread" is a measurement rather
/// than a claim. Reported once, on the load that filled the gazetteer.
@immutable
class AreaGazetteerLoad {
  final int names;
  final int compressedBytes;
  final Duration elapsed;

  const AreaGazetteerLoad({
    required this.names,
    required this.compressedBytes,
    required this.elapsed,
  });

  @override
  String toString() =>
      'area gazetteer: $names names from $compressedBytes compressed bytes '
      'in ${elapsed.inMilliseconds}ms';
}

/// How the inflate-and-sort reaches a worker. Production hands the pure
/// function to `Isolate.run`; tests inject the direct call, for the reason
/// written on [ExtractionRunner] in `import_flow.dart`.
typedef GazetteerRunner = Future<ip.SortedListAreaGazetteer> Function(
  List<Uint8List> compressed,
);

/// The pure body of the load: gunzip each asset, keep every non-comment
/// line, dedupe and sort. Top-level and free of `ref`, because an
/// `Isolate.run` closure may capture nothing that cannot be sent.
ip.SortedListAreaGazetteer buildAreaGazetteer(List<Uint8List> compressed) {
  return ip.SortedListAreaGazetteer.fromAssetTexts([
    for (final bytes in compressed) utf8.decode(gzip.decode(bytes)),
  ]);
}

final gazetteerRunnerProvider = Provider<GazetteerRunner>((ref) {
  return (compressed) => Isolate.run(() => buildAreaGazetteer(compressed));
});

/// The loaded gazetteer, or null — and null is not an error state, it is
/// "no import has happened yet", which is phase-1 behaviour.
final areaGazetteerProvider =
    NotifierProvider<AreaGazetteerLoader, ip.AreaGazetteer?>(
      AreaGazetteerLoader.new,
    );

class AreaGazetteerLoader extends Notifier<ip.AreaGazetteer?> {
  Future<void>? _inFlight;

  @override
  ip.AreaGazetteer? build() => null;

  /// What the last completed load cost, or null if none has completed.
  AreaGazetteerLoad? get lastLoad => _lastLoad;
  AreaGazetteerLoad? _lastLoad;

  /// Loads the gazetteer once, on the first import that asks. Idempotent and
  /// safe to call on every import: a completed load returns immediately, and
  /// two imports racing share the one in-flight future rather than inflating
  /// the assets twice.
  ///
  /// It never throws and never rethrows. An asset that is missing from the
  /// bundle, or bytes that will not inflate, leave the gazetteer null, and a
  /// null gazetteer is a plan parsed exactly as phase 1 parsed it — a
  /// degraded area column, never a failed import.
  Future<void> ensureLoaded() {
    if (state != null) return Future.value();
    return _inFlight ??= _load();
  }

  Future<void> _load() async {
    final watch = Stopwatch()..start();
    try {
      // The bundle read is the only part that stays here: `rootBundle` is a
      // platform channel and cannot be reached from a spawned isolate.
      final compressed = <Uint8List>[];
      for (final asset in areaGazetteerAssets) {
        final data = await rootBundle.load(asset);
        compressed.add(data.buffer.asUint8List());
      }
      final built = await ref.read(gazetteerRunnerProvider)(compressed);
      watch.stop();
      _lastLoad = AreaGazetteerLoad(
        names: built.length,
        compressedBytes: compressed.fold(0, (n, b) => n + b.length),
        elapsed: watch.elapsed,
      );
      debugPrint('$_lastLoad');
      state = built;
    } catch (error) {
      // Deliberately swallowed — see the doc comment. The import succeeds,
      // the plan parses, the areas are simply the ones phase 1 found.
      debugPrint('area gazetteer unavailable, parsing without it: $error');
    } finally {
      _inFlight = null;
    }
  }
}
