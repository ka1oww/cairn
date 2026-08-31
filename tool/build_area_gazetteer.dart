// Builds a compact area-gazetteer asset from a GeoNames country dump.
//
// Run by hand, never in CI — the input is the ~80 MB per-country dump from
// https://download.geonames.org/export/dump/ (e.g. JP.zip -> JP.txt), which
// is downloaded locally and never committed. Only the built asset is:
//
//   dart run tool/build_area_gazetteer.dart <dump.txt> <country> \
//       [assets/area_gazetteer/<cc>.txt.gz]
//
// e.g.  dart run tool/build_area_gazetteer.dart /tmp/JP.txt JP
//
// What it keeps, and why, is the measured recipe of the tap-to-Maps plan
// (§9.2) — the C10 gazetteer validator was scored against exactly this set,
// so changing any rule here is a re-measurement event, not a tidy-up:
//
//  - Feature classes P and A, plus feature codes RSTN ST SQR AREA LCTY PPLX
//    from any class. Columns 2 (name) and 3 (asciiname) only — the
//    alternate-names column measurably injects junk ('art' hits France
//    through an alternate name).
//  - The hamlet filter (measured 2026-08-31, the UNAGI/UDON fix): P-class
//    rows whose feature code is in the plain-settlement family
//    {PPL, PPLL, PPLF, PPLH, PPLQ, PPLW} are dropped when their population
//    is under 500. PPLX (city districts — often population 0 in Japan and
//    the validator's whole value), PPLA*, PPLC and everything in class A /
//    station / square / locality are kept regardless of population.
//  - Names are normalised with the parser package's own `areaTokens` — one
//    normaliser, never a second copy — and a name ending in a trailing
//    generic ('Shimokitazawa Eki') also indexes its trimmed form
//    ('shimokitazawa'). Single-word names shorter than 3 characters are
//    dropped (measured: zero effect on the corpus, and they are junk-prone
//    parenthetical matches — 'no', 'la').
//
// Output: '#'-prefixed header (attribution — GeoNames data is CC-BY 4.0 and
// the header must survive into the shipped asset), then the deduped names,
// sorted with String.compareTo (the binary search in
// SortedListAreaGazetteer depends on exactly this order), one per line,
// gzip-compressed.

import 'dart:convert';
import 'dart:io';

import 'package:itinerary_parser/itinerary_parser.dart';

const _keptCodesAnyClass = {'RSTN', 'ST', 'SQR', 'AREA', 'LCTY', 'PPLX'};
const _plainSettlementCodes = {'PPL', 'PPLL', 'PPLF', 'PPLH', 'PPLQ', 'PPLW'};
const _hamletPopulationFloor = 500;

Future<void> main(List<String> args) async {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'usage: dart run tool/build_area_gazetteer.dart '
      '<dump.txt> <country> [out.txt.gz]',
    );
    exitCode = 64;
    return;
  }
  final dump = File(args[0]);
  final country = args[1].toUpperCase();
  final outPath = args.length == 3
      ? args[2]
      : 'assets/area_gazetteer/${country.toLowerCase()}.txt.gz';

  final trailingGenerics = {...venueGenericWords, 'eki', 'dori', 'doori'};
  final names = <String>{};
  var rowsRead = 0, rowsKept = 0;

  await for (final line
      in dump
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    rowsRead++;
    final cols = line.split('\t');
    if (cols.length < 15) continue;
    final featureClass = cols[6];
    final featureCode = cols[7];
    final keptByClass = featureClass == 'P' || featureClass == 'A';
    if (!keptByClass && !_keptCodesAnyClass.contains(featureCode)) continue;
    if (featureClass == 'P' && _plainSettlementCodes.contains(featureCode)) {
      final population = int.tryParse(cols[14]) ?? 0;
      if (population < _hamletPopulationFloor) continue;
    }
    rowsKept++;
    for (final raw in [cols[1], cols[2]]) {
      final ws = areaTokens(raw);
      if (ws.isEmpty) continue;
      names.add(ws.join(' '));
      if (ws.length > 1 && trailingGenerics.contains(ws.last)) {
        names.add(ws.sublist(0, ws.length - 1).join(' '));
      }
    }
  }

  final kept = names.where((n) => n.contains(' ') || n.length >= 3).toList()
    ..sort();

  final header =
      '# Area gazetteer for $country — built by '
      'tool/build_area_gazetteer.dart from the GeoNames gazetteer\n'
      '# (https://www.geonames.org/), licensed CC-BY 4.0 '
      '(https://creativecommons.org/licenses/by/4.0/).\n'
      '# This file contains GeoNames data, modified: filtered and '
      'normalised for area-name validation.\n';
  final body = '$header${kept.join('\n')}\n';
  final gz = GZipCodec(level: 9).encode(utf8.encode(body));
  final out = File(outPath)..createSync(recursive: true);
  out.writeAsBytesSync(gz);

  stdout.writeln(
    '$country: $rowsRead rows read, $rowsKept kept, '
    '${kept.length} names, ${gz.length} bytes gzipped -> $outPath',
  );
}
