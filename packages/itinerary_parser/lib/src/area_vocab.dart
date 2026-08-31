/// Anchor vocabulary builder — the corroboration pass.
///
/// Ported from scorer.py `build_anchor_vocab` (lines 409-476) and
/// `vocab_runs` (478-498).
library;

import 'area_words.dart';
import 'area_annotations.dart';

final RegExp _urlRe = RegExp(r'https?://\S+');
final RegExp _wordRe = RegExp(r"[A-Za-z][A-Za-z'’‘’\-]*");

/// Result of [buildAnchorVocab]: the vocabulary + debug info.
class AnchorVocab {
  final Set<String> vocab;
  /// word -> (line numbers, kinds) for fixture comparison
  final Map<String, List<int>> contribLines;
  final Map<String, Set<String>> contribKinds;
  const AnchorVocab(this.vocab, this.contribLines, this.contribKinds);
}

/// Header kind for day-boundary logic.
String headerKind(String? text) {
  if (text == null) return 'none';
  if (RegExp(r'^\s*(?:###\s*)?day\s*\d+\b', caseSensitive: false).hasMatch(text)) {
    return 'daynum';
  }
  if (RegExp(
    r'\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b|\b(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*day?\b|\d{1,2}/\d{1,2}',
    caseSensitive: false,
  ).hasMatch(text)) {
    return 'date';
  }
  return 'place';
}

String? titleTrailing(String? text) {
  if (text == null) return null;
  final s = text.replaceAll(_urlRe, ' ');
  final parts = s.split(RegExp(r'[-–—:]'));
  if (parts.length >= 2) {
    return parts.sublist(1).join('-').trim();
  }
  return null;
}

/// Builds the anchor vocabulary over [plines] (1-indexed lines) using
/// [parsedDays] (headerText/headerLine info). Mirrors scorer exactly.
AnchorVocab buildAnchorVocab(
  List<String> plines,
  List<ParsedDayInfo> parsedDays,
) {
  final contrib = <String, Set<int>>{};
  final kinds = <String, Set<String>>{};
  final capitalized = <String>{};

  void add(List<String> words, int ln, String kind, String srcText) {
    // Capitalized tokens in srcText
    final capTokens = <String>{};
    for (final m in _wordRe.allMatches(stripDiacritics(srcText))) {
      final w = m.group(0)!;
      if (w.isNotEmpty && w[0].toUpperCase() == w[0] && w[0].toLowerCase() != w[0]) {
        capTokens.addAll(areaTokens(w));
      }
    }
    for (final w in words) {
      if (w.length >= 3 &&
          !genericStopWords.contains(w) &&
          !venueGenericWords.contains(w) &&
          !furnitureWords.contains(w) &&
          !w.codeUnits.any((c) => c >= 48 && c <= 57)) {
        contrib.putIfAbsent(w, () => <int>{}).add(ln);
        kinds.putIfAbsent(w, () => <String>{}).add(kind);
        if (capTokens.contains(w)) capitalized.add(w);
      }
    }
  }

  // (a) doc first non-blank line + day titles + placeHeader text
  final firstIdx = plines.indexWhere((l) => l.trim().isNotEmpty);
  if (firstIdx != -1) {
    final t = plines[firstIdx].replaceAll(_urlRe, ' ');
    add(areaTokens(t), firstIdx + 1, 'title', t);
  }
  for (final day in parsedDays) {
    final kind = headerKind(day.headerText);
    if (kind == 'daynum' || kind == 'date') {
      final t = titleTrailing(day.headerText);
      if (t != null && t.isNotEmpty) {
        add(areaTokens(t), day.headerLine, 'title', t);
      }
    } else if (kind == 'place' && day.headerText != null && day.headerText!.isNotEmpty) {
      final t = day.headerText!.replaceAll(_urlRe, ' ');
      add(areaTokens(t), day.headerLine, 'placeheader', t);
    }
  }

  for (var i = 0; i < plines.length; i++) {
    final ln = i + 1;
    final l = plines[i];
    final stripped = l.replaceAll(_urlRe, ' ');

    // (b) word before Station/STN
    for (final m in stationRegExp.allMatches(stripped)) {
      add(areaTokens(m.group(1)!), ln, 'station', m.group(1)!);
    }
    // (c) hotel name lines: <=9 words, capitalized words only
    if (hotelWordRegExp.hasMatch(stripped) && stripped.trim().isNotEmpty) {
      final origWords = _wordRe.allMatches(stripDiacritics(stripped)).map((m) => m.group(0)!).toList();
      if (origWords.length <= 9) {
        final caps = [for (final w in origWords) if (w.isNotEmpty && w[0].toUpperCase() == w[0] && w[0].toLowerCase() != w[0]) w];
        final toks = [for (final w in caps) ...areaTokens(w)];
        add(toks, ln, 'hotel', stripped);
      }
    }
    // (d) short parentheticals
    for (final m in RegExp(r'\(([^)]*)\)').allMatches(stripped)) {
      final p = m.group(1)!;
      final pw = areaTokens(p);
      if (pw.length >= 1 &&
          pw.length <= 3 &&
          !p.codeUnits.any((c) => c >= 48 && c <= 57)) {
        final real = [for (final w in pw) if (!genericStopWords.contains(w) && !venueGenericWords.contains(w)) w];
        if (real.length >= 1 && real.length <= 2) {
          add(real, ln, 'paren', p);
        }
      }
    }
    // (e) traveller annotations
    for (final ann in travellerAnnotations(stripped)) {
      add(areaTokens(ann.capture), ln, 'annotation', ann.capture);
    }
  }

  final vocab = <String>{};
  final contribLines = <String, List<int>>{};
  final contribKindsOut = <String, Set<String>>{};
  for (final entry in contrib.entries) {
    if (entry.value.length >= 2 && capitalized.contains(entry.key)) {
      vocab.add(entry.key);
      contribLines[entry.key] = entry.value.toList()..sort();
      contribKindsOut[entry.key] = kinds[entry.key]!;
    }
  }
  return AnchorVocab(vocab, contribLines, contribKindsOut);
}

/// Minimal day header info needed by vocab builder.
class ParsedDayInfo {
  final String? headerText;
  final int headerLine;
  final String? place;
  const ParsedDayInfo({this.headerText, required this.headerLine, this.place});
}

/// Maximal runs of consecutive vocab words -> candidate strings.
/// Mirrors scorer's `vocab_runs`.
List<String> vocabRuns(String text, Set<String> vocab) {
  final runs = <String>[];
  for (final segment in text.split(RegExp(r'[/,+&;]'))) {
    var cur = <String>[];
    for (final w in areaTokens(segment)) {
      if (vocab.contains(w)) {
        cur.add(w);
      } else {
        if (cur.isNotEmpty) {
          runs.add(cur.join(' '));
        }
        cur = [];
      }
    }
    if (cur.isNotEmpty) runs.add(cur.join(' '));
  }
  // Deduplicate by joined form (shimo kitazawa vs shimokitazawa)
  final uniq = <String, String>{};
  for (final r in runs) {
    uniq[joinedAreaWords(r)] = r;
  }
  return uniq.values.toList();
}

/// Seed for a day's place — in-tail first, else single vocab run.
/// Mirrors scorer's `seed_for`.
String? seedFor(String? place, Set<String> vocab) {
  if (place == null || isFurniture(place)) return null;
  final t = inTail(place);
  if (t != null) return t;
  final cands = vocabRuns(place, vocab);
  if (cands.length != 1) return null;
  return cands.first;
}
