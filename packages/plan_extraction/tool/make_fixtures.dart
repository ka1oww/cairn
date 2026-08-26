// Slice A's fixtures, generated once and committed as binaries; this script
// is the record of how each was made (the plan's test strategy §7). Run from
// inside packages/plan_extraction:
//
//   dart run tool/make_fixtures.dart
//
// Everything here is deterministic: re-running rewrites byte-identical
// fixtures.
import 'dart:convert';
import 'dart:io';

/// The tidy itinerary shared by the encoding fixtures: dated headers parse
/// high-confidence, so any decode mistake shows up immediately in the
/// extractor round-trip.
const tidyPlan = '''
Mon 14 June 2027 - Tokyo
- Senso-ji at 9:00
- Ueno Park picnic
- Caf\u00e9 stop on the way

Tue 15 June 2027 - Kyoto
- Fushimi Inari at dawn
''';

void main() {
  final fixtures = Directory('test/fixtures');
  if (!fixtures.existsSync()) fixtures.createSync(recursive: true);

  void write(String name, List<int> bytes) =>
      File('test/fixtures/$name').writeAsBytesSync(bytes);

  // UTF-8 without BOM — the overwhelming default.
  write('tidy-utf8.txt', utf8.encode(tidyPlan));

  // UTF-8 with BOM — what plenty of Windows editors still write.
  write(
    'tidy-utf8-bom.txt',
    [0xEF, 0xBB, 0xBF, ...utf8.encode(tidyPlan)],
  );

  // Windows line endings: CRLF is what Notepad has always produced.
  write(
    'tidy-crlf.txt',
    utf8.encode(tidyPlan.replaceAll('\n', '\r\n')),
  );

  // UTF-16 LE with BOM — Windows' "Unicode" save.
  write(
    'tidy-utf16le-bom.txt',
    [0xFF, 0xFE, ..._utf16CodeUnits(tidyPlan, littleEndian: true)],
  );

  // UTF-16 BE with BOM — rare, but PowerTools and network tools emit it.
  write(
    'tidy-utf16be-bom.txt',
    [0xFE, 0xFF, ..._utf16CodeUnits(tidyPlan, littleEndian: false)],
  );

  // Latin-1 / Windows-1252: the same plan with é as one byte (0xE9), which
  // strict UTF-8 decoding would refuse and the ladder must catch.
  write(
    'cafe-latin1.txt',
    tidyPlan.codeUnits.map((u) => u > 0xFF ? 0x3F : u).toList(),
  );

  // Empty and whitespace-only files: the honest empty-file sentence.
  write('empty.txt', const []);
  write('blank.txt', utf8.encode('\n   \n\t\n'));

  stdout.writeln('fixtures written under test/fixtures/');
}

List<int> _utf16CodeUnits(String text, {required bool littleEndian}) {
  final bytes = <int>[];
  for (final unit in text.codeUnits) {
    final hi = (unit >> 8) & 0xFF;
    final lo = unit & 0xFF;
    bytes.addAll(littleEndian ? [lo, hi] : [hi, lo]);
  }
  return bytes;
}
