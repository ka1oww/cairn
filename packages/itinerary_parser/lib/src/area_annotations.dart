/// Traveller-annotation grammar and in-tail locality extraction.
///
/// Ported from scorer.py lines 59-71, 122-153, 185-215.
library;

import 'area_words.dart';

/// Result of [annotations]: a traveller annotation found on a line.
class TravellerAnnotation {
  /// 'declared' (suggested area) or 'proximity' (near/opposite/from).
  final String kind;
  final String capture;
  const TravellerAnnotation(this.kind, this.capture);
}

/// Scorer's IN_TAIL_RE: `in <Capitalized Area>` at end of a comma/paren
/// segment, at most 3 words, capitalized tail, not furniture/month.
final RegExp _inTailRe = RegExp(
  r"\bin\s+((?:(?:[A-Za-z][A-Za-z'’‘\-]*|le|la|les|de|du|des)\s+){0,2}[A-Za-z][A-Za-z'’‘\-]*)\s*$",
);

/// Returns the traveller's own locality suffix at end of [text], or null.
///
/// Mirrors scorer's `in_tail`: splits on `,;()` and checks each segment's
/// tail for `in <Capitalized>`. Guards: not furniture, no month/weekday.
String? inTail(String text) {
  for (final segment in text.split(RegExp(r'[,;()]'))) {
    final seg = segment.trim();
    final m = _inTailRe.firstMatch(seg);
    if (m != null) {
      final cap = m.group(1)!.trim();
      final ws = areaTokens(cap);
      if (ws.isNotEmpty &&
          !isFurniture(cap) &&
          !ws.any((w) => monthWeekdayWords.contains(w))) {
        // Capitalization check: the captured tail must start with uppercase
        // or be a French article. Scorer's pattern requires [A-Z] for the
        // area words; we enforce by checking first char is uppercase or
        // the word is a French article (which the pattern allows lowercase).
        final firstWord = cap.split(RegExp(r'\s+')).first;
        if (firstWord.isNotEmpty) {
          final isFrenchArticle = {
            'le',
            'la',
            'les',
            'de',
            'du',
            'des',
          }.contains(firstWord.toLowerCase());
          final isCapitalized = firstWord[0].toUpperCase() == firstWord[0] &&
              firstWord[0].toLowerCase() != firstWord[0];
          if (isCapitalized || isFrenchArticle) {
            // Also verify every non-article word is capitalized
            var ok = true;
            for (final w in cap.split(RegExp(r'\s+'))) {
              if (w.isEmpty) continue;
              if ({
                'le',
                'la',
                'les',
                'de',
                'du',
                'des',
              }.contains(w.toLowerCase())) continue;
              if (w[0].toUpperCase() != w[0] ||
                  w[0].toLowerCase() == w[0]) {
                ok = false;
                break;
              }
            }
            if (ok) return cap;
          }
        }
      }
    }
  }
  return null;
}

/// Traveller annotations on [raw]: (kind, capture) pairs, best first.
///
/// Mirrors scorer's `annotations()`: declared > proximity-near > proximity-from.
/// Captures >3 content words are refused (description, not area).
List<TravellerAnnotation> travellerAnnotations(String raw) {
  final out = <TravellerAnnotation>[];
  final patterns = [
    ('declared', suggRegExp),
    ('proximity', nearXRegExp),
    ('proximity', fromXRegExp),
  ];
  for (final entry in patterns) {
    final kind = entry.$1;
    final rx = entry.$2;
    for (final m in rx.allMatches(raw)) {
      var cap = m.group(1)!.split(',').first.trim();
      if (cap.isEmpty || isFurniture(cap)) continue;
      final content = [
        for (final w in areaTokens(cap))
          if (!genericStopWords.contains(w)) w
      ];
      if (content.isNotEmpty && content.length <= 3) {
        out.add(TravellerAnnotation(kind, cap));
      }
    }
  }
  return out;
}

// Helpers for the assignment engine: clean stop text

final RegExp _urlRe = RegExp(r'https?://\S+');
final RegExp _timeLeadRe = RegExp(
  r'^\s*(?:~?\d{1,2}[:.]\d{2}\s*(?:am|pm|AM|PM)?|\d{1,2}\s*(?:am|pm|AM|PM))\s*[-–—:]*\s*',
);
final RegExp _bulletRe = RegExp(
  r'^\s*(?:[-*•–—]+|\(\d{1,3}\)|\d{1,3}[.)]|\d{1,3}(?=\s))\s*',
);
final RegExp _parenRe = RegExp(r'\(([^)]*)\)');

class CleanStopResult {
  final String clean;
  final List<String> parens;
  const CleanStopResult(this.clean, this.parens);
}

/// Mirrors scorer's `clean_stop_text`: strip URLs, parens, bullet, time lead.
CleanStopResult cleanStopText(String raw) {
  var s = raw.replaceAll(_urlRe, ' ');
  final parens = [
    for (final m in _parenRe.allMatches(s)) m.group(1)!.trim(),
  ];
  s = s.replaceAll(_parenRe, ' ');
  s = s.replaceAll(_bulletRe, '').trim();
  s = s.replaceAll(_timeLeadRe, '');
  s = s.trim().replaceAll(RegExp(r'^[ \t\-–—:·]+|[ \t\-–—:·]+$'), '');
  return CleanStopResult(s, parens);
}
