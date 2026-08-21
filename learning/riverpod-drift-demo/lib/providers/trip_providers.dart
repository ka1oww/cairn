// This file is the seam between Drift (data) and Riverpod (state). Every
// provider here is thin on purpose: it just exposes a database query. The
// interesting behaviour — screens updating without knowing about each other
// — lives entirely in how widgets *watch* these providers, not in the
// providers themselves.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';

// `WidgetRef` (used by addTodaysPhoto below) lives in flutter_riverpod, not
// the plain `riverpod` package `Provider` callbacks receive their `Ref`
// from — the app-facing package re-exports everything from `riverpod`, so
// this single import covers both.

/// "Today" is hardcoded to day 1 of the fake trip. In the real app this
/// would be computed from the current date vs. the trip's start date; that
/// logic isn't the point of this demo, so it's a constant.
const int kTodayDayNumber = 1;

/// A single shared [AppDatabase] instance for the whole app.
///
/// `Provider` (not `StateProvider` or `NotifierProvider`) is Riverpod's tool
/// for "build this object once, hand the same instance to everyone who asks
/// for it." Every other provider in this file calls `ref.watch(databaseProvider)`
/// to get at the same open database connection rather than each opening its
/// own — opening a SQLite connection is expensive and stateful, so it must
/// be shared.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  // Providers can react to being torn down. Riverpod disposes a provider
  // when nothing is watching it anymore (or never, for one kept alive for
  // the app's lifetime, which is the case here) — `ref.onDispose` is where
  // you release whatever resource `ref` handed out, mirroring `dispose()`
  // on a StatefulWidget.
  ref.onDispose(db.close);
  return db;
});

/// Live count of photos taken on "today" (day 1). This is a `StreamProvider`
/// because the underlying value is a `Stream<int>` from Drift, not a single
/// value — Riverpod wraps each event from that stream in an `AsyncValue`
/// (loading / data / error) automatically, which is why the widgets that use
/// this provider call `.when(...)` rather than reading an `int` directly.
///
/// THE key thing to notice: this provider is watched from two unrelated
/// widgets (the Today screen's "N photos today" line, and the bottom nav
/// badge on the Pool tab). Neither widget imports the other, or knows the
/// other exists. Riverpod just re-runs `build()` on every widget currently
/// watching this provider whenever the stream emits — that's the whole
/// mechanism behind "one action, two places update."
final todayPhotoCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db.watchPhotoCountForDay(kTodayDayNumber);
});

/// Live count of every photo across the whole trip. Backs the Pool tab's
/// badge total (as opposed to `todayPhotoCountProvider`, which is
/// today-only) — two different aggregations of the same underlying table,
/// each its own provider, each updating independently when a photo is
/// added.
final totalPhotoCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db.watchTotalPhotoCount();
});

/// Photo counts grouped by day — the join+aggregate query from
/// `database.dart`, exposed the same way as every other query here. The
/// Pool screen renders this as a small per-day breakdown table.
final photoCountsPerDayProvider = StreamProvider<List<DayPhotoCount>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.watchPhotoCountsPerDay();
});

/// All stops on the trip, ordered by day. A `FutureProvider` wraps a
/// one-shot `Future`, unlike the `StreamProvider`s above which keep
/// listening forever — this list doesn't change after the database is
/// seeded, so a single fetch is enough. Used by the Trail screen.
final allStopsProvider = FutureProvider<List<Stop>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.allStopsOrderedByDay();
});

/// Inserts a new photo for "today". This is the function the add-photo
/// button calls.
///
/// It is declared as a plain top-level function taking a `WidgetRef`, not a
/// class or a widget method, and it does not return anything for the UI to
/// use — it just writes to the database and returns. Every screen that
/// cares finds out via the streams above. If a second, third, or tenth
/// screen later wants to react to new photos, this function does not
/// change at all; that's the decoupling the whole Riverpod half of this
/// demo is here to sell.
Future<void> addTodaysPhoto(WidgetRef ref) {
  final db = ref.read(databaseProvider);
  return db.addPhotoToDay(kTodayDayNumber);
}
