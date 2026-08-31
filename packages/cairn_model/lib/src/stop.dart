import 'clock_time.dart';

/// A place on a day, as the itinerary describes it.
///
/// A stop is what someone wrote in the plan they pasted in, kept as they wrote
/// it. It is not a place lookup, a booking, or anything the app verifies —
/// see the "What this parser cannot do" section of
/// `packages/itinerary_parser/README.md`, which is the authority on how little
/// is known about a stop.
///
/// This is the domain-side shape of `itinerary_parser`'s `Stop`. The two carry
/// the same [text] and the same [time]; what the parser additionally keeps —
/// the verbatim `SourceLine` each stop came from, and the `Confidence` it
/// assigns — is evidence about the *parse*, and stays in the parser with the
/// confirmation screen that reads it.
/// Where [Stop.area] came from.
enum AreaSource {
  /// The person's own `(near Akihabara)` on the pasted line itself.
  travellerOwn,

  /// Confirmed, corrected, added or cleared by a person in the app.
  human,

  /// Assigned by the running-area extractor, unreviewed.
  parser,
}

final class Stop {
  /// The stop line as written, with any bullet marker stripped but nothing
  /// else rewritten. `itinerary_parser` never normalises this and neither
  /// does the app.
  final String text;

  /// The clock time on the stop's line, if it had one.
  final ClockTime? time;

  /// The area in force for this stop — what a Maps search appends.
  /// Null means "send the stop's own words alone".
  final String? area;

  /// Where [area] came from. Null exactly when [area] is null.
  final AreaSource? areaSource;

  Stop({required this.text, this.time, this.area, this.areaSource}) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'a stop must have text');
    }
    if (area == null && areaSource != null) {
      throw ArgumentError.value(
        areaSource,
        'areaSource',
        'areaSource must be null when area is null',
      );
    }
    if (area != null && areaSource == null) {
      throw ArgumentError.value(
        area,
        'area',
        'areaSource must be present when area is present',
      );
    }
  }

  /// True exactly when [time] is present.
  ///
  /// **This is the star rule, and it is the only one.** A stop is starred
  /// because it is time-anchored in the source text, never because anything
  /// judged it important; there is no keyword list and no separate flag to set
  /// out of step with the time. `itinerary_parser` states the same rule and
  /// this getter is why it cannot drift here: there is no field to disagree
  /// with.
  bool get isStarred => time != null;

  @override
  bool operator ==(Object other) =>
      other is Stop &&
      other.text == text &&
      other.time == time &&
      other.area == area &&
      other.areaSource == areaSource;

  @override
  int get hashCode => Object.hash(text, time, area, areaSource);

  @override
  String toString() =>
      'Stop(${time == null ? '' : '${time!.iso} '}$text'
      '${area == null ? '' : ' [$area:${areaSource?.name}]'})';
}
