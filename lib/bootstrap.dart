// The composition root: the one file allowed to know every layer, because
// something has to assemble the stack in dependency order. The map's rule
// ("a layer may only know the layers beneath it", docs/architecture.md)
// governs the layers; this file is where the layers are put together, and
// confining that knowledge here is what keeps it out of everywhere else.
// See lib/README.md.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app_state/camera_source.dart';
import 'app_state/day_view.dart';
import 'app_state/ping_schedule.dart';
import 'app_state/trip_providers.dart';
import 'repositories/itinerary_sync.dart';
import 'repositories/membership_repository.dart';
import 'repositories/photo_repository.dart';
import 'repositories/trip_repository.dart';
import 'storage/drift/app_database.dart';
import 'storage/remote/gotrue_sessions.dart';
import 'storage/remote/postgrest_shared_facts.dart';
import 'storage/remote/shared_facts.dart';

/// Builds the whole app: storage → seam → providers → shell.
///
/// [database] exists for tests, which pass an in-memory database instead of
/// the on-device file. [today] likewise: a widget test pins the date the day
/// page reads, because a page deriving today from the real device clock
/// would otherwise assert different things in June 2027 than it does now.
/// [now] and [utcOffset] pin the other two clock reads for the same reason —
/// a test that walked the capture window against the real wall clock would
/// pass or fail by the hour it ran at. [camera] lets a test hand the flow a
/// frame without a device; the app takes [DeviceCameraSource], which is the
/// real back camera on a phone and the stand-in where there is no camera.
///
/// [photos] overrides the **read** side of the pool alone, for a test that
/// wants a pool of a known shape without writing one. The app passes nothing
/// and both sides are bound to the same [PhotoStore], which is what makes the
/// photo capture writes the photo the Pool draws — the two features share a
/// store, not a wire between them.
///
/// [membership] is the same trick for the roster, and it is the only way to
/// stand the party up at the size the product is for: this phone can write
/// exactly one member row, so a test that wants to watch eight people get
/// eight different minutes seeds the read side and leaves the write side
/// bound to the store. Bind them to two different objects in the app and the
/// trip's own surface would go blank the moment somebody renamed it.
///
/// [sessions] and [memberId] arrive together and must never disagree: the
/// first is what the sync speaks to the server with, the second is who the
/// app thinks it is, and they are the same account. `main` acquires the
/// session, reads the id off it and hands both in; a test hands in neither
/// and gets [NoSession] and the local stand-in, which is the same pair.
Widget bootstrapApp({
  AppDatabase? database,
  DateTime? today,
  DateTime? now,
  Duration? utcOffset,
  CameraSource? camera,
  PhotoRepository? photos,
  MembershipRepository? membership,
  SessionSource? sessions,
  String? memberId,
}) {
  final db = database ?? openAppDatabase();
  final store = PhotoStore(db);
  final roster = MembershipStore(db);
  _startSharedFactsSync(db, sessions ?? const NoSession());
  return ProviderScope(
    overrides: [
      tripRepositoryProvider.overrideWithValue(TripRepository(db)),
      photoRepositoryProvider.overrideWithValue(photos ?? store),
      photoStoreProvider.overrideWithValue(store),
      membershipRepositoryProvider.overrideWithValue(membership ?? roster),
      membershipStoreProvider.overrideWithValue(roster),
      if (today != null) todayProvider.overrideWithValue(today),
      if (now != null) nowProvider.overrideWithValue(now),
      if (utcOffset != null) tripUtcOffsetProvider.overrideWithValue(utcOffset),
      if (camera != null) cameraSourceProvider.overrideWithValue(camera),
      if (memberId != null) localMemberIdProvider.overrideWithValue(memberId),
    ],
    child: const CairnApp(),
  );
}

/// Starts keeping the trip's shared facts in step with the server's, if there
/// is a server and somebody to be on it.
///
/// The URL and the publishable key default to the hosted project
/// ([SharedFactsConfig.fromEnvironment]), so this runs in an ordinary build.
/// It does not run in a test: every test binds [NoSession] and passes an
/// in-memory database, and the guard below is what keeps a sync from leaving
/// a timer pending and hanging the test at teardown. A build that wants the
/// old inert behaviour asks for it with `--dart-define=CAIRN_SUPABASE_URL=`.
///
/// It is started here rather than exposed as a provider because no surface
/// consumes it. The sync's whole job is to make the Drift store agree with
/// seven other phones; every screen already reads that store, and a provider
/// nobody watched would only invite one to.
void _startSharedFactsSync(AppDatabase db, SessionSource sessions) {
  const config = SharedFactsConfig.fromEnvironment;
  if (!config.isConfigured || sessions is NoSession) return;
  TripSync(
    database: db,
    facts: PostgrestSharedFacts(config: config, sessions: sessions),
    tripRow: _tripRowFromEnvironment,
  ).start(pollEvery: const Duration(minutes: 2));
}

/// The trip's clock, if the build was told it.
///
/// ```sh
/// flutter run --dart-define=CAIRN_TRIP_TIMEZONE=Asia/Tokyo
/// ```
///
/// Absent by default, and that is honest rather than lazy: `trips.timezone`
/// is the one clock eight phones agree on, the app asks for country and city
/// and derives the zone from them, and that question is asked at sign-in —
/// which does not exist (`SyncStanding.awaitingTripRow` names this exact
/// gap). Deriving `Etc/GMT-9` from the device's UTC offset would be a lie the
/// first time somebody crossed a border. So the build may *tell* the app the
/// zone, and until sign-in asks, nothing guesses it.
const _tripTimeZone = String.fromEnvironment('CAIRN_TRIP_TIMEZONE');

/// Answers with the shared `trips` row to create, or null to say "not yet".
///
/// Three things must be known and none of them is invented here:
///
///  * the zone, from the define above;
///  * the trip's first and last dates, which are the plan's own resolved
///    dates — a plan whose every date is still open cannot be a `trips` row,
///    because `start_date` and `end_date` are `not null`;
///  * the name, because `trips.name` is `not null` and the phone's is
///    nullable. Pushing the app's own word for an unnamed trip would come
///    back through the roster apply and *rename* the trip, so an unnamed trip
///    waits instead. Naming it in the trip sheet is what starts the sync.
Future<RemoteTripDraft?> _tripRowFromEnvironment(PendingTripRow pending) async {
  final name = pending.name;
  final first = pending.firstDateIso;
  final last = pending.lastDateIso;
  if (_tripTimeZone.isEmpty || name == null || first == null || last == null) {
    return null;
  }
  return RemoteTripDraft(
    id: pending.tripId,
    name: name,
    createdBy: pending.startedBy,
    timeZone: _tripTimeZone,
    startDateIso: first,
    endDateIso: last,
  );
}

/// Signs the phone in, or answers null when it cannot.
///
/// Called by `main` before the app is built, because the account's id *is*
/// this phone's member id and a surface that drew itself as `me` and then
/// became a uuid would have credited a photo to a member the roster does not
/// hold. Null is an ordinary answer — no backend configured, or no route to
/// one — and the app then runs entirely locally, which is the whole
/// offline-first story.
Future<SharedFactsSession?> signIn(SessionSource sessions) =>
    sessions.current();

/// The app's own [SessionSource]: an anonymous GoTrue account, kept across
/// launches. See `storage/remote/gotrue_sessions.dart` for why it is
/// anonymous and what Apple sign-in replaces.
SessionSource deviceSessions() {
  const config = SharedFactsConfig.fromEnvironment;
  if (!config.isConfigured) return const NoSession();
  return GotrueSessions(config: config, vault: FileSessionVault());
}
