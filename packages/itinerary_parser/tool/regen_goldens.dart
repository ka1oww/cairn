import 'dart:convert';
import 'dart:io';

import 'package:itinerary_parser/itinerary_parser.dart';

/// Regenerates every `test/fixtures/*.expected.json` from the current
/// parser output. Run it only when a behavior change is intended, then
/// review the diff by hand before committing — the goldens are the spec,
/// not a cache.
void main() {
  final files = Directory('test/fixtures')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.input.txt'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  const encoder = JsonEncoder.withIndent('  ');
  for (final f in files) {
    final base = f.path.substring(0, f.path.length - '.input.txt'.length);
    DateTime? tripStartDate;
    final meta = File('$base.meta.json');
    if (meta.existsSync()) {
      final raw = (jsonDecode(meta.readAsStringSync())
          as Map<String, dynamic>)['tripStartDate'] as String?;
      if (raw != null) tripStartDate = DateTime.parse(raw);
    }
    final result =
        parseItinerary(f.readAsStringSync(), tripStartDate: tripStartDate);
    File('$base.expected.json')
        .writeAsStringSync('${encoder.convert(result.toJson())}\n');
    stdout.writeln('regenerated $base.expected.json');
  }
}
