// APP STATE band (docs/architecture.md): Riverpod providers. One source of
// truth per question; screens watch these and nothing below them.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/trip_repository.dart';
import 'date_labels.dart';

/// Bound to the real repository by the composition root (`bootstrap.dart`),
/// and to fakes by tests. Left unbound it throws, loudly and immediately,
/// which is the correct behaviour for a wiring mistake.
final tripRepositoryProvider = Provider<TripRepository>(
  (ref) => throw UnimplementedError(
    'tripRepositoryProvider is bound in bootstrap.dart (or a test override)',
  ),
);

/// The itinerary saved on this phone, summarised for the screens — or null
/// while none has been accepted. This is the app's launch question: the root
/// screen watches it to choose between the paste flow and the saved trip.
final savedItineraryProvider = StreamProvider<SavedItinerarySummary?>(
  (ref) => ref
      .watch(tripRepositoryProvider)
      .watchItinerary()
      .map(_summarise),
);

/// What the saved-trip surface shows, spoken in screen terms. Deliberately a
/// summary: the surface it feeds is the placeholder that proves persistence,
/// not the Trail — that is a later slice.
class SavedItinerarySummary {
  final List<SavedDayLine> days;
  final int stopCount;
  final int starredCount;
  final int keptAsideCount;

  const SavedItinerarySummary({
    required this.days,
    required this.stopCount,
    required this.starredCount,
    required this.keptAsideCount,
  });

  int get dayCount => days.length;
}

class SavedDayLine {
  final int number;

  /// `Monday · Tokyo`, or the place, or `Day 3`.
  final String title;

  /// `14 June`, or null where the date was accepted still open.
  final String? dateLabel;

  final int stopCount;

  const SavedDayLine({
    required this.number,
    required this.title,
    this.dateLabel,
    required this.stopCount,
  });
}

SavedItinerarySummary? _summarise(ConfirmedItinerary? itinerary) {
  if (itinerary == null) return null;
  var stopCount = 0;
  var starredCount = 0;
  final days = <SavedDayLine>[];
  for (final day in itinerary.days) {
    stopCount += day.stops.length;
    starredCount += day.stops.where((s) => s.isStarred).length;
    final date = day.date;
    final weekday = date == null
        ? null
        : weekdayName(DateTime.utc(date.year, date.month, date.day).weekday);
    final title = switch ((weekday, day.place)) {
      (final w?, final p?) => '$w · $p',
      (final w?, null) => w,
      (null, final p?) => p,
      (null, null) => 'Day ${day.number}',
    };
    days.add(SavedDayLine(
      number: day.number,
      title: title,
      dateLabel: date == null
          ? null
          : dayMonthLabel(DateTime.utc(date.year, date.month, date.day)),
      stopCount: day.stops.length,
    ));
  }
  return SavedItinerarySummary(
    days: days,
    stopCount: stopCount,
    starredCount: starredCount,
    keptAsideCount: itinerary.keptAside.length,
  );
}
