// APP STATE band (docs/architecture.md): Riverpod providers. One source of
// truth per question; screens watch these and nothing below them.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/trip_repository.dart';

/// Bound to the real repository by the composition root (`bootstrap.dart`),
/// and to fakes by tests. Left unbound it throws, loudly and immediately,
/// which is the correct behaviour for a wiring mistake.
final tripRepositoryProvider = Provider<TripRepository>(
  (ref) => throw UnimplementedError(
    'tripRepositoryProvider is bound in bootstrap.dart (or a test override)',
  ),
);

/// The itinerary saved on this phone, in screen terms — or null while none
/// has been accepted. This is the app's launch question: the root screen
/// watches it to choose between the paste flow and Today.
///
/// One stream over the store serves every question the trip surfaces ask, so
/// the day page adds no second subscription: `dayViewProvider` derives from
/// this, and the Trail will too.
final savedItineraryProvider = StreamProvider<TripPlan?>(
  (ref) => ref.watch(tripRepositoryProvider).watchItinerary().map(_toPlan),
);

/// The accepted plan as the app state layer speaks it: days in trip order,
/// each with its stops as pasted. Deliberately not the seam's
/// `ConfirmedItinerary` and not `cairn_model` — nothing below this band may
/// reach a screen.
class TripPlan {
  final List<PlanDay> days;

  const TripPlan({required this.days});
}

class PlanDay {
  /// 1-based, as the plan was pasted.
  final int number;

  /// UTC midnight — a bare calendar date carried in a core type, never an
  /// instant to do arithmetic on. Null where the person accepted the plan
  /// with this day's date still open.
  final DateTime? date;

  final String? place;

  final List<PlanStop> stops;

  const PlanDay({
    required this.number,
    this.date,
    this.place,
    required this.stops,
  });
}

class PlanStop {
  final String text;

  /// `16:40`, present exactly when the stop is starred. See [DayStop] in
  /// `day_view.dart` for the star rule.
  final String? timeLabel;

  const PlanStop({required this.text, this.timeLabel});
}

TripPlan? _toPlan(ConfirmedItinerary? itinerary) {
  if (itinerary == null) return null;
  return TripPlan(
    days: [
      for (final day in itinerary.days)
        PlanDay(
          number: day.number,
          date: switch (day.date) {
            null => null,
            final d => DateTime.utc(d.year, d.month, d.day),
          },
          place: day.place,
          stops: [
            for (final stop in day.stops)
              PlanStop(text: stop.text, timeLabel: stop.time?.iso),
          ],
        ),
    ],
  );
}
