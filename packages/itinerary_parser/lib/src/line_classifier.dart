/// Pure syntactic helpers for classifying one line of pasted text. No
/// state, no lookahead — [ItineraryParser] (in parser.dart) is the only
/// place that sequences these into a document-level parse.
library;

import 'time_parser.dart';

final RegExp _decorativeSeparator = RegExp(r'^([-=_*~.•])\1{2,}$');

bool isBlank(String line) => line.trim().isEmpty;

bool isDecorativeSeparator(String line) =>
    _decorativeSeparator.hasMatch(line.trim());

final RegExp _whatsAppPrefix = RegExp(
  r'^\[\d{1,2}/\d{1,2}/\d{2,4},?\s*\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AaPp][Mm])?\]\s*[^:]{1,60}:\s*(.*)$',
);

/// Strips a WhatsApp export prefix (`[03/11/2026, 14:22] Mum: `) if present,
/// returning the remainder. Returns null if the line has no such prefix.
String? stripWhatsAppPrefix(String line) {
  final m = _whatsAppPrefix.firstMatch(line.trim());
  return m?.group(1);
}

final RegExp _whatsAppPlaceholder = RegExp(
  r'^(<media omitted>|image omitted|video omitted|audio omitted|sticker omitted|gif omitted|document omitted|this message was deleted|missed voice call|missed video call)\.?$',
  caseSensitive: false,
);

bool isWhatsAppPlaceholder(String remainder) =>
    _whatsAppPlaceholder.hasMatch(remainder.trim());

final RegExp _signatureLine = RegExp(
  r'^(sent from my \w+.*|get outlook for \w+.*)$',
  caseSensitive: false,
);

bool isSignatureLine(String line) => _signatureLine.hasMatch(line.trim());

final RegExp _hotelBookingKeywords = RegExp(
  r'\b(confirmation\s*(number|no\.?|code)|booking\s*(number|no\.?|ref(erence)?)|reservation\s*(number|no\.?|id)|\bpnr\b)\b',
  caseSensitive: false,
);

bool isHotelBookingReference(String line) =>
    _hotelBookingKeywords.hasMatch(line);

final RegExp _url = RegExp(r'(https?://\S+|www\.\S+)', caseSensitive: false);

class UrlStripResult {
  final String textWithoutUrl;
  final bool hadUrl;
  const UrlStripResult(this.textWithoutUrl, this.hadUrl);
}

/// Removes any URL substring from [line] and reports whether one was
/// found, so callers can decide whether what remains is still meaningful.
UrlStripResult stripUrls(String line) {
  final hadUrl = _url.hasMatch(line);
  if (!hadUrl) return UrlStripResult(line, false);
  final cleaned = line.replaceAll(_url, '').trim();
  return UrlStripResult(cleaned, true);
}

/// True when, after removing punctuation, a line has essentially no
/// content left worth keeping as a stop.
bool isTriviallyEmpty(String text) =>
    text.trim().replaceAll(RegExp(r'[\s\-–—:,.]'), '').isEmpty;

final RegExp _dayNumberHeader = RegExp(
  r'^day\s*[:\-]?\s*(\d{1,3})\b\s*(?:[-:–—]\s*)?(.*)$',
  caseSensitive: false,
);

class DayNumberMatch {
  final int dayNumber;
  final String? trailingText;
  const DayNumberMatch(this.dayNumber, this.trailingText);
}

DayNumberMatch? tryParseDayNumberHeader(String line) {
  final m = _dayNumberHeader.firstMatch(line.trim());
  if (m == null) return null;
  final trailing = m.group(2)?.trim();
  return DayNumberMatch(
    int.parse(m.group(1)!),
    (trailing == null || trailing.isEmpty) ? null : trailing,
  );
}

final RegExp _bulletPrefix = RegExp(
  r'^(?:[-*•–—]|\(\d{1,3}\)|\d{1,3}[.)]|\d{1,3}(?=\s))\s*',
);

bool startsWithBullet(String line) {
  final trimmed = line.trim();
  final m = _bulletPrefix.firstMatch(trimmed);
  if (m == null) return false;
  final matched = m.group(0)!;
  if (RegExp(r'^\d{1,3}(?=\s)').hasMatch(matched)) {
    final after = trimmed.substring(m.end).trimLeft();
    if (after.isEmpty) return true;
    // Tightened: bare-number bullet only when remainder starts with
    // capitalized word or bullet-like, NOT a time/digit/month or lowercase.
    // This prevents eating "3 November" date headers and "10 am" times.
    if (RegExp(r'^(?:am|pm|:\d)', caseSensitive: false).hasMatch(after)) return false;
    // If remainder starts with digit or lowercase, not a bullet list item
    if (RegExp(r'^[a-z]').hasMatch(after)) return false;
    if (RegExp(r'^\d').hasMatch(after)) return false;
    // Month words are not bullet items
    if (RegExp(r'^(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)', caseSensitive: false).hasMatch(after)) return false;
  }
  return true;
}

/// Strips exactly one leading bullet marker (`-`, `*`, `•`, `1.`, `1)`,
/// `(1)`, ...) and the whitespace following it, if present.
String stripBullet(String line) {
  final trimmed = line.trim();
  if (!startsWithBullet(trimmed)) return trimmed;
  final m = _bulletPrefix.firstMatch(trimmed)!;
  return trimmed.substring(m.end).trim();
}

/// Folio-after-URL guard: after stripping URL, remainder like "4/24" is urlOnly.
bool isFolioAfterUrl(String textWithoutUrl) =>
    RegExp(r'^\d{1,3}/\d{1,3}$').hasMatch(textWithoutUrl.trim());

final RegExp _properNounWord = RegExp(r"^[A-Z][A-Za-z'.]*$");
final RegExp _allCapsWord = RegExp(r'^[A-Z]{2,}$');

/// Heuristic for a bare place-name line acting as a day header (`Kyoto`
/// with no `Day N` or date around it): every word capitalized like a
/// proper noun, no digits, not bulleted, short.
bool looksLikeProperNounHeader(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return false;
  if (startsWithBullet(trimmed)) return false;
  if (RegExp(r'\d').hasMatch(trimmed)) return false;
  if (extractTime(trimmed) != null) return false;
  final words = trimmed.split(RegExp(r'\s+'));
  if (words.isEmpty || words.length > 5) return false;
  for (final w in words) {
    if (!_properNounWord.hasMatch(w) && !_allCapsWord.hasMatch(w)) {
      return false;
    }
  }
  return true;
}
