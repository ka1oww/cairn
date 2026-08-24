// THE SEAM (docs/architecture.md): the only layer that knows storage
// backends exist. Above it, a provider asks a question and cannot tell where
// the answer came from; below it, the store never learns who asked. When the
// Supabase/R2 adapter is built, it is consumed here and nowhere else.
//
// This is also where dialects are translated (the map's "Translation" note):
// the itinerary arrives already spoken in `cairn_model` vocabulary — the app
// state layer converts the parser's `ParsedDay`/`Stop` dialect before it
// reaches this seam — and leaves here as Drift companions.
import 'package:cairn_model/cairn_model.dart';

import '../storage/drift/app_database.dart';

/// The itinerary as the person confirmed it on the paste-and-confirm screen:
/// days in trip order, and every pasted line the parser set aside, kept with
/// its reason. This is both what gets saved and what a watch returns — the
/// round trip is deliberately lossless.
class ConfirmedItinerary {
  final List<ConfirmedDay> days;
  final List<KeptLine> keptAside;

  ConfirmedItinerary({required List<ConfirmedDay> days, List<KeptLine> keptAside = const []})
      : days = List.unmodifiable(days),
        keptAside = List.unmodifiable(keptAside);
}

/// One confirmed day. [date] stays null when the person accepted the plan
/// with that day's date still open — the parser never guesses and neither
/// does this layer. Deliberately not a `cairn_model.TripDay`: a TripDay
/// requires a resolved date and a trip clock, and neither exists yet in this
/// local-only slice.
class ConfirmedDay {
  final int number;
  final CalendarDate? date;
  final String? place;
  final List<Stop> stops;

  ConfirmedDay({
    required this.number,
    this.date,
    this.place,
    List<Stop> stops = const [],
  }) : stops = List.unmodifiable(stops);
}

/// A pasted line kept aside instead of placed, with the parser's
/// person-showable reason. Never silently dropped; a later slice lets the
/// person place these by hand.
class KeptLine {
  final int sourceLineNumber;
  final String text;
  final String explanation;

  KeptLine({
    required this.sourceLineNumber,
    required this.text,
    required this.explanation,
  });
}

class TripRepository {
  TripRepository(this._db);

  final AppDatabase _db;

  /// The itinerary saved on this phone, or null while none has been
  /// accepted. Re-emits after every save.
  ///
  /// Hangs on the days table's stream: every write path replaces all three
  /// itinerary tables in one transaction, so stops and kept lines can be
  /// read in the same emission without a second watch.
  Stream<ConfirmedItinerary?> watchItinerary() =>
      _db.watchItineraryDays().asyncMap((dayRows) async {
        if (dayRows.isEmpty) return null;
        final stopRows = await _db.readItineraryStops();
        final asideRows = await _db.readItinerarySetAsides();
        return ConfirmedItinerary(
          days: [
            for (final day in dayRows)
              ConfirmedDay(
                number: day.number,
                date: _parseDate(day.dateIso),
                place: day.place,
                stops: [
                  for (final stop in stopRows)
                    if (stop.dayNumber == day.number)
                      Stop(text: stop.stopText, time: _parseTime(stop.timeIso)),
                ],
              ),
          ],
          keptAside: [
            for (final line in asideRows)
              KeptLine(
                sourceLineNumber: line.sourceLineNumber,
                text: line.lineText,
                explanation: line.explanation,
              ),
          ],
        );
      });

  /// Persists the confirmed itinerary, replacing whatever was saved before.
  Future<void> saveItinerary(ConfirmedItinerary itinerary) {
    var asidePosition = 0;
    return _db.replaceItinerary(
      days: [
        for (final day in itinerary.days)
          (number: day.number, dateIso: day.date?.iso, place: day.place),
      ],
      stops: [
        for (final day in itinerary.days)
          for (final (position, stop) in day.stops.indexed)
            (
              dayNumber: day.number,
              position: position,
              text: stop.text,
              timeIso: stop.time?.iso,
            ),
      ],
      setAsides: [
        for (final line in itinerary.keptAside)
          (
            position: asidePosition++,
            sourceLineNumber: line.sourceLineNumber,
            text: line.text,
            explanation: line.explanation,
          ),
      ],
    );
  }

  static CalendarDate? _parseDate(String? iso) {
    if (iso == null) return null;
    final parts = iso.split('-');
    return CalendarDate(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  static ClockTime? _parseTime(String? iso) {
    if (iso == null) return null;
    final parts = iso.split(':');
    return ClockTime(int.parse(parts[0]), int.parse(parts[1]));
  }
}
