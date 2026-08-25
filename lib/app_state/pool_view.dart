// APP STATE band (docs/architecture.md): the Pool's whole brain.
//
// The Pool is the trip's shared photo pool — every photo everyone took, in
// one place everybody can see. **It is plumbing, not a destination**
// (`docs/decisions/2026-08-21-first-calls.md`, "The Pool is plumbing"): plain,
// correct and fast, and deliberately not somewhere design effort goes. It is
// also what the book is later made from, which is the reason it holds the
// whole trip rather than only today.
//
// It derives from `photoRepositoryProvider`, `savedItineraryProvider` and
// `todayProvider` — the same two plan sources Today and the Trail use, so no
// two surfaces can disagree about which day it is.
//
// **Which day a photo belongs to is not decided here.** It was decided when
// the photo entered the pool, by `packages/photo_day_assignment`'s
// degradation ladder, and a person can override it by hand afterwards; by the
// time a photo is a `PhotoRef` the question is settled. Re-deriving it on
// read would silently overrule that override and would make the Pool disagree
// with the day page about the same photo. So this groups on the day number
// already on the photo, and nothing here imports the ladder.
//
// **The gate applies here, because the gate is about photographs.** A day
// that is shut to you withholds its pictures wherever they would be drawn, not
// only on its own page — the server makes that literal by gating the signature
// on the bytes themselves (`supabase/migrations/0007_day_unlocks.sql`), so a
// Pool that drew them anyway would be showing what the server refuses. The
// rule is not restated here: it comes from `day_gate.dart`, which is the app's
// one answer to it.
//
// Deliberately absent, because nothing in the app has them yet: the taker's
// initial chip the design puts on every tile (no roster is stored, and this
// layer invents nothing — the photo names its contributor by id, and an id is
// not a person's initial), and the dashed "+" tile, which is an invitation to
// a capture screen that does not exist.
import 'package:cairn_model/cairn_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/photo_repository.dart';
import 'date_labels.dart';
import 'day_gate.dart';
import 'day_view.dart';
import 'trip_providers.dart';

// ---------------------------------------------------------------------------
// View models — everything a screen may see, spoken in screen terms.
// ---------------------------------------------------------------------------

/// One photo, as a tile.
class PoolPhoto {
  /// The photo's id, as the storage layer spells it — an opaque string here,
  /// used as the tile's key and nothing else.
  final String id;

  /// Where the image file is on this phone, or null when its bytes are not
  /// here. A tile without bytes is drawn as a tile waiting for them, never as
  /// a missing photo: the row is real either way.
  ///
  /// Null on a shut day too, and that is the point of a gate rather than a
  /// curtain: the screen is not handed the bytes and told not to look at them.
  /// [PoolDay.isOpen] is what tells the two apart.
  final String? imagePath;

  const PoolPhoto({required this.id, this.imagePath});
}

/// One day's slice of the pool.
class PoolDay {
  /// 1-based, as the plan was pasted — the `04` the design sets beside the
  /// day. A photo can carry a day number the plan no longer claims; such a
  /// day still gets a section, because the Pool shows every photo of the trip
  /// and dropping one silently is the one thing it must never do.
  final int number;

  /// `Wednesday, Kyoto`, `Kyoto`, or `Day 4` — the day page's own spelling of
  /// a day's identity, so the two surfaces name a day the same way.
  final String title;

  /// `14 June`, or null when this day's date is still open.
  final String? dateLabel;

  /// `today`, or `43 photos`. The design writes one or the other beside a
  /// day, never both.
  final String detail;

  /// Oldest first, by `cairn_model.DayPool`'s rule — the order things
  /// happened, which is the order the day page and the book read them in.
  final List<PoolPhoto> photos;

  /// Whether this day's photographs are yours to see.
  ///
  /// False only for the day being lived, and only until you put something into
  /// it (`day_gate.dart`). The day is still listed, still named, still counted
  /// — a shut gate shows the shape of the day and withholds the images
  /// (`docs/decisions/2026-08-22-design-calls.md` §4), so hiding the section
  /// would be hiding the wrong thing.
  final bool isOpen;

  const PoolDay({
    required this.number,
    required this.title,
    this.dateLabel,
    required this.detail,
    required this.photos,
    required this.isOpen,
  });
}

/// The whole screen.
class PoolView {
  /// `128 photos`, or null while the pool is empty — an empty pool says so in
  /// words rather than counting to zero.
  final String? countLabel;

  /// One per day that has photos in it, **most recent first**: the pool is
  /// read from the top, and the top is where the trip is now.
  final List<PoolDay> days;

  const PoolView({this.countLabel, required this.days});

  bool get isEmpty => days.isEmpty;
}

// ---------------------------------------------------------------------------
// Providers.
// ---------------------------------------------------------------------------

// `photoRepositoryProvider` and `tripPhotosProvider` are declared in
// `trip_providers.dart`: capture reads the pool too, and a seam provider owned
// by one feature is one the next feature has to import sideways to reach.

/// The Pool, or null while no plan is saved.
final poolViewProvider = Provider<AsyncValue<PoolView?>>((ref) {
  final today = ref.watch(todayProvider);
  final plan = ref.watch(savedItineraryProvider);
  final photos = ref.watch(tripPhotosProvider);

  // Either read failing fails the screen; either still loading leaves it
  // loading. Written out rather than folded together so the order — error
  // before loading — is visible.
  if (plan case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  if (photos case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  if (plan case AsyncData(value: final savedPlan)) {
    if (photos case AsyncData(value: final pooled)) {
      return AsyncData(
        poolViewFor(
          savedPlan,
          pooled,
          today,
          viewer: ref.watch(viewerProvider),
        ),
      );
    }
  }
  return const AsyncLoading();
});

// ---------------------------------------------------------------------------
// The derivation, kept a pure function so it can be read in one sitting.
// ---------------------------------------------------------------------------

/// The Pool for [plan] and [photos], with [today] deciding which day wears the
/// word "today" and, through the gate, which day is still [viewer]'s to earn.
PoolView? poolViewFor(
  TripPlan? plan,
  List<PooledPhoto> photos,
  DateTime today, {
  required MemberId viewer,
}) {
  if (plan == null || plan.days.isEmpty) return null;
  if (photos.isEmpty) return const PoolView(days: []);

  final byDay = <int, List<PooledPhoto>>{};
  for (final photo in photos) {
    byDay.putIfAbsent(photo.ref.dayNumber, () => []).add(photo);
  }

  final planDays = {for (final day in plan.days) day.number: day};
  final numbers = byDay.keys.toList()..sort((a, b) => b.compareTo(a));

  return PoolView(
    countLabel: _photoCount(photos.length),
    days: [
      for (final number in numbers)
        _day(
          number,
          byDay[number]!,
          planDays[number],
          today,
          gateForPlanDay(
            number: number,
            planDay: planDays[number],
            today: today,
            photos: photos,
            viewer: viewer,
          ),
        ),
    ],
  );
}

PoolDay _day(
  int number,
  List<PooledPhoto> photos,
  PlanDay? planDay,
  DateTime today,
  GateState gate,
) {
  // The order of a day's photos is the domain's rule, not this layer's:
  // oldest first, ties broken on id. Asking `DayPool` for it is what keeps
  // the Pool, the day page and the book from each sorting slightly
  // differently.
  final ordered = DayPool.of(number, [for (final photo in photos) photo.ref]);
  final paths = {for (final photo in photos) photo.ref.id: photo.localPath};

  final date = planDay?.date;
  return PoolDay(
    number: number,
    title: dayPageTitle(
      weekday: date == null ? null : weekdayName(date.weekday),
      place: planDay?.place,
      number: number,
    ),
    dateLabel: date == null ? null : dayMonthLabel(date),
    detail: date == today ? 'today' : _photoCount(photos.length),
    photos: [
      for (final ref in ordered.photos)
        PoolPhoto(
          id: ref.id.value,
          imagePath: gate.isOpen ? paths[ref.id] : null,
        ),
    ],
    isOpen: gate.isOpen,
  );
}

String _photoCount(int count) => count == 1 ? '1 photo' : '$count photos';
