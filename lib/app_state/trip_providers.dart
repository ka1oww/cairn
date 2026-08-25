// APP STATE band (docs/architecture.md): Riverpod providers. One source of
// truth per question; screens watch these and nothing below them.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/photo_repository.dart';
import '../repositories/trip_repository.dart';

/// Bound to the real repository by the composition root (`bootstrap.dart`),
/// and to fakes by tests. Left unbound it throws, loudly and immediately,
/// which is the correct behaviour for a wiring mistake.
final tripRepositoryProvider = Provider<TripRepository>(
  (ref) => throw UnimplementedError(
    'tripRepositoryProvider is bound in bootstrap.dart (or a test override)',
  ),
);

/// The photo pool's seam, read-only, bound by the composition root the same
/// way. Kept a second repository rather than a second method on the first:
/// the plan is replaced wholesale and the pool only ever accumulates, and one
/// class that did both would have to explain that in every doc comment.
///
/// It lives here rather than beside one feature's view models because two
/// bands above it read the pool for different reasons — the Pool draws it, and
/// capture asks it whether today's moment has already been answered — and a
/// seam provider owned by whichever feature happened to arrive first is a seam
/// provider the next feature has to import sideways to reach.
final photoRepositoryProvider = Provider<PhotoRepository>(
  (ref) => throw UnimplementedError(
    'photoRepositoryProvider is bound in bootstrap.dart (or a test override)',
  ),
);

/// The same pool, with its write path: keeping a frame and writing a word.
///
/// Separate from [photoRepositoryProvider] because reading the pool and adding
/// to it are different privileges, and only capture holds the second one. In
/// the app both are bound to the same `PhotoStore`, so what capture writes is
/// what the Pool reads; a test may bind a seeded in-memory pool to the read
/// side alone.
final photoStoreProvider = Provider<PhotoStore>(
  (ref) => throw UnimplementedError(
    'photoStoreProvider is bound in bootstrap.dart (or a test override)',
  ),
);

/// Every photo in the trip's pool, straight off the seam.
///
/// One subscription for the whole app, for the same reason
/// [savedItineraryProvider] is one: two streams over the same store are two
/// chances to disagree about what the trip holds.
final tripPhotosProvider = StreamProvider<List<PooledPhoto>>(
  (ref) => ref.watch(photoRepositoryProvider).watchTripPhotos(),
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
