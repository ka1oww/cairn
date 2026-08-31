// APP STATE band (docs/architecture.md): Riverpod providers. One source of
// truth per question; screens watch these and nothing below them.
import 'package:cairn_model/cairn_model.dart' show AreaSource, StopKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/itinerary_sync.dart';
import '../repositories/membership_repository.dart';
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

/// The trip's roster and its codes, read-only, bound by the composition root
/// the same way. Kept a third repository rather than a method on the trip's:
/// the itinerary is replaced wholesale, the pool only accumulates, and who is
/// here changes for reasons that have nothing to do with either.
final membershipRepositoryProvider = Provider<MembershipRepository>(
  (ref) => throw UnimplementedError(
    'membershipRepositoryProvider is bound in bootstrap.dart (or a test override)',
  ),
);

/// The same trip, with its write path: starting it, naming it, minting and
/// revoking a code, deleting it.
///
/// Separate from [membershipRepositoryProvider] for the reason the photo
/// store is separate from the pool's read side — reading who is here and
/// changing it are different privileges — and so a test can seed a party of
/// eight through the read side alone.
final membershipStoreProvider = Provider<MembershipStore>(
  (ref) => throw UnimplementedError(
    'membershipStoreProvider is bound in bootstrap.dart (or a test override)',
  ),
);

/// Where the last reconcile with the server got to, or nothing while no
/// reconcile has happened.
///
/// **The only thing above the seam that knows the sync exists**, and it is
/// read-only in both directions: nothing here can make a sync happen, and
/// nothing here re-decides what a standing means. Bound by the composition
/// root to the live `TripSync`'s own stream; left unbound — and bound to an
/// empty stream in every test that does not care — it never emits, and every
/// surface over it stays silent rather than claiming the plan did or did not
/// go up.
///
/// It exists because of the defect it answers: with no way to hear this, a
/// plan that never reached the server looked exactly like one that had.
final sharedFactsStandingProvider = StreamProvider<SyncOutcome>(
  (ref) => const Stream<SyncOutcome>.empty(),
);

/// The trip on this phone, or null while none has been started.
///
/// One subscription for the whole app, for the reason [savedItineraryProvider]
/// is one: the roster feeds the ping's deal *and* the trip's own surface, and
/// two streams over one store are two chances to disagree about who is here.
final tripMembershipProvider = StreamProvider<TripMembership?>(
  (ref) => ref.watch(membershipRepositoryProvider).watchMembership(),
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

  /// The lines the plan carries but no day does: what the parser could not
  /// place, and what the person took out of a day themselves. Kept with the
  /// plan because nothing pasted is ever deleted, and read back by the
  /// whole-plan editor so re-opening it shows the tray as it was left.
  final List<PlanKeptLine> keptAside;

  const TripPlan({required this.days, this.keptAside = const []});
}

/// One line of the plan's set-aside tray, in screen terms.
class PlanKeptLine {
  final int sourceLineNumber;
  final String text;
  final String explanation;

  const PlanKeptLine({
    required this.sourceLineNumber,
    required this.text,
    required this.explanation,
  });
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

  /// What the line is, decided by the parser at the paste and carried since.
  final StopKind kind;

  /// The area in force for this stop, and whose it is. Null is an answer: it
  /// means a search goes out as the stop's own words alone.
  final String? area;
  final AreaSource? areaSource;

  const PlanStop({
    required this.text,
    this.timeLabel,
    this.kind = StopKind.place,
    this.area,
    this.areaSource,
  });
}

TripPlan? _toPlan(ConfirmedItinerary? itinerary) {
  if (itinerary == null) return null;
  return TripPlan(
    keptAside: [
      for (final line in itinerary.keptAside)
        PlanKeptLine(
          sourceLineNumber: line.sourceLineNumber,
          text: line.text,
          explanation: line.explanation,
        ),
    ],
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
              PlanStop(
                text: stop.text,
                timeLabel: stop.time?.iso,
                kind: stop.kind,
                area: stop.area,
                areaSource: stop.areaSource,
              ),
          ],
        ),
    ],
  );
}
