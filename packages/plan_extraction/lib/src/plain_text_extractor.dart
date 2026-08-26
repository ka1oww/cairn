// The plain-text extractor: slice A's debugging baseline for every other
// format. A `.txt` *is* the paste, so the extractor's whole job is decoding
// honestly — sniff the encoding, hand back the lines, refuse binary garbage
// rather than mojibake-ing it into the paste box.
//
// The decode ladder, tried in order:
//
//   1. UTF-8 with BOM            (EF BB BF)
//   2. UTF-16 LE / BE with BOM   (FF FE / FE FF)
//   3. UTF-16 without BOM        (NUL-byte-position heuristic — what Windows'
//                                 "Unicode" saves without a BOM look like)
//   4. strict UTF-8              (the overwhelming default)
//   5. Latin-1 fallback          (never fails; see _decodeLatin1Wide)
//
// Two refusals sit on top of the ladder: bytes that carry a known binary
// container's magic number are refused before any decoding (so a mis-named
// PDF never fills the box with `%PDF-1.7` junk), and decoded text whose
// control-character ratio says "binary" is refused after it. Both return the
// unreadable failure with its person-showable sentence.
import 'dart:convert';
import 'dart:typed_data';

import '../plan_extraction.dart';

/// The sentence §2.6 of the import plan spells for an unreadable file.
const String unreadableFileSentence =
    "Couldn't read that file — it may be damaged or password-protected.";

/// The sentence §2.6 spells for a file that held no text at all.
const String emptyFileSentence = "That file didn't contain any text.";

/// Files above this size are refused before reading (the plan's risk 7):
/// extraction loads everything into memory, and no itinerary lives anywhere
/// near this.
const int maxPlainBytes = 25 * 1024 * 1024;

/// How much of a file [PlanTextExtractor.matches] looks at. Routing happens
/// on the UI thread, before the isolate hop, so the sniff decodes a prefix
/// and never the whole file; an encoding is decided in the first few lines
/// or not at all.
const int _sniffBytes = 64 * 1024;

class PlainTextExtractor implements PlanTextExtractor {
  const PlainTextExtractor();

  @override
  Set<String> get extensions => const {'txt'};

  @override
  bool matches(PickedBytes file) {
    if (_hasBinaryMagic(file.bytes)) return false;
    final text = _tryDecode(_sniffPrefix(file.bytes));
    if (text == null) return false;
    return !_readsAsBinaryGarbage(text);
  }

  @override
  ExtractionResult extract(PickedBytes file) {
    if (file.bytes.length > maxPlainBytes) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        'That file is larger than 25 MB — too big to read.',
      );
    }
    if (file.bytes.isEmpty || _hasBinaryMagic(file.bytes)) {
      return _unreadableOrEmpty(file.bytes);
    }

    final String? decoded = _tryDecode(file.bytes);
    if (decoded == null || _readsAsBinaryGarbage(decoded)) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }
    // CRLF and lone CR become LF. The parser normalizes line endings too
    // (parser.dart does exactly this split), but the box should show what
    // the parser will see, not two slightly different texts.
    final text =
        decoded.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.trim().isEmpty) {
      return const ExtractionFailure(
        ExtractionFailureKind.empty,
        emptyFileSentence,
      );
    }
    return ExtractedText(text: text);
  }

  ExtractionFailure _unreadableOrEmpty(Uint8List bytes) => bytes.isEmpty
      ? const ExtractionFailure(ExtractionFailureKind.empty, emptyFileSentence)
      : const ExtractionFailure(
          ExtractionFailureKind.unreadable,
          unreadableFileSentence,
        );
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// The leading slice [PlanTextExtractor.matches] sniffs. A cut mid-character
/// would read as garbage to the ladder, so the slice steps back off a partial
/// UTF-8 sequence and keeps an even length for the UTF-16 rungs.
Uint8List _sniffPrefix(Uint8List bytes) {
  if (bytes.length <= _sniffBytes) return bytes;
  var end = _sniffBytes;
  var stepped = 0;
  while (end > 0 &&
      stepped < 4 &&
      bytes[end - 1] >= 0x80 &&
      bytes[end - 1] < 0xC0) {
    end--;
    stepped++;
  }
  if (end > 0 && bytes[end - 1] >= 0xC0) end--;
  if (end.isOdd) end--;
  return Uint8List.sublistView(bytes, 0, end);
}

/// The ladder's answer: the decoded text, or null when no rung could hold
/// the bytes as text.
String? _tryDecode(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    try {
      return utf8.decode(bytes.sublist(3));
    } on FormatException {
      return null;
    }
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }
  switch (_utf16WithoutBomEndianness(bytes)) {
    case _Endianness.little:
      return _decodeUtf16(bytes, littleEndian: true);
    case _Endianness.big:
      return _decodeUtf16(bytes, littleEndian: false);
    case _Endianness.none:
      break;
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _decodeLatin1Wide(bytes);
  }
}

/// True when the zero-byte positions say "UTF-16 saved without a BOM": ASCII-
/// range text in UTF-16LE puts a NUL after every character, BE before it.
/// Real Latin-1/UTF-8 text has no NULs at all, so the bar is set high enough
/// that only genuinely half-zero streams trip it.
_Endianness _utf16WithoutBomEndianness(Uint8List bytes) {
  final length = bytes.length;
  if (length < 4 || length.isOdd) return _Endianness.none;
  var zerosAtOdd = 0;
  var zerosAtEven = 0;
  for (var i = 0; i < length; i++) {
    if (bytes[i] != 0) continue;
    if (i.isOdd) {
      zerosAtOdd++;
    } else {
      zerosAtEven++;
    }
  }
  // At least a quarter of the byte positions NUL, and overwhelmingly on one
  // side — a heuristic tuned for prose, which is all these files ever hold.
  if (zerosAtOdd > length ~/ 4 && zerosAtOdd > zerosAtEven * 4) {
    return _Endianness.little;
  }
  if (zerosAtEven > length ~/ 4 && zerosAtEven > zerosAtOdd * 4) {
    return _Endianness.big;
  }
  return _Endianness.none;
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final buffer = StringBuffer();
  var i = 0;
  while (i + 1 < bytes.length) {
    final unit = littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1];
    i += 2;
    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < bytes.length) {
      final low = littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1];
      if (low >= 0xDC00 && low <= 0xDFFF) {
        i += 2;
        buffer.writeCharCode(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
        continue;
      }
    }
    // Unpaired surrogates become U+FFFD rather than throwing: a damaged
    // trail of a file still shows its readable remainder in the box.
    buffer.writeCharCode(unit >= 0xD800 && unit <= 0xDFFF ? 0xFFFD : unit);
  }
  return buffer.toString();
}

/// The Latin-1 rung. Files called "Latin-1" in the wild are almost always
/// Windows-1252 (what Windows calls ANSI), so the undefined-in-Latin-1
/// 0x80–0x9F range maps through cp1252 first and falls back to the identity
/// mapping where cp1252 is itself undefined — strictly more honest than
/// emitting invisible C1 controls for a curly quote.
String _decodeLatin1Wide(Uint8List bytes) {
  final units = <int>[];
  for (final b in bytes) {
    if (b < 0x80 || b >= 0xA0) {
      units.add(b);
    } else {
      units.add(_cp1252High[b - 0x80] ?? b);
    }
  }
  return String.fromCharCodes(units);
}

const List<int?> _cp1252High = [
  0x20AC, null, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, null, 0x017D, null,
  null, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, null, 0x017E, 0x0178,
];

enum _Endianness { none, little, big }

// ---------------------------------------------------------------------------
// Binary refusal
// ---------------------------------------------------------------------------

bool _hasBinaryMagic(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith([0x25, 0x50, 0x44, 0x46, 0x2D])) return true; // %PDF-
  if (startsWith([0x50, 0x4B])) return true; // PK.. — zip: docx/xlsx/jar
  if (startsWith([0xFF, 0xD8, 0xFF])) return true; // JPEG
  if (startsWith([0x89, 0x50, 0x4E, 0x47])) return true; // PNG
  if (startsWith(_ascii('GIF8'))) return true; // GIF87a/GIF89a
  if (startsWith([0x49, 0x49, 0x2A, 0x00])) return true; // TIFF II
  if (startsWith([0x4D, 0x4D, 0x00, 0x2A])) return true; // TIFF MM
  if (startsWith(_ascii('ftyp'), 4)) return true; // HEIC/HEIF/MP4/MOV
  if (startsWith(_ascii('RIFF'))) return true; // WEBP/WAV/AVI
  if (startsWith(_ascii('OggS'))) return true;
  if (startsWith(_ascii('ID3'))) return true; // MP3
  if (startsWith(_ascii('fLaC'))) return true;
  if (startsWith([0x1F, 0x8B])) return true; // gzip
  if (startsWith(_ascii('BZh'))) return true; // bzip2
  if (startsWith([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) return true; // xz
  if (startsWith(_ascii('SQLite format 3'))) return true;
  if (startsWith([0x00, 0x00, 0x01, 0x00])) return true; // ICO
  if (startsWith([0x78, 0xDA]) ||
      startsWith([0x78, 0x9C]) ||
      startsWith([0x78, 0x5E])) {
    return true; // zlib stream (docx parts, PNG chunks)
  }
  return false;
}

List<int> _ascii(String s) => s.codeUnits;

/// A decoded string that still reads like bytes — control characters beyond
/// the whitespace family, or U+FFFD flood from lenient surrogate repair — is
/// binary wearing a .txt name. Honest refusal beats filling the box with it.
bool _readsAsBinaryGarbage(String text) {
  if (text.contains('\x00')) return true;
  if (text.isEmpty) return false;
  var suspicious = 0;
  for (final rune in text.runes) {
    if (rune == 0xFFFD) suspicious++;
    if (rune <= 0x1F &&
        rune != 0x09 &&
        rune != 0x0A &&
        rune != 0x0C &&
        rune != 0x0D) {
      suspicious++;
    } else if (rune >= 0x7F && rune < 0xA0) {
      suspicious++;
    }
  }
  return suspicious > text.length * 0.05;
}
