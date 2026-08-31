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
import 'app_state/device_prefs.dart';
import 'app_state/device_time_zone.dart';
import 'app_state/file_picker_edge.dart';
import 'app_state/import_flow.dart';
import 'app_state/link_opener_edge.dart';
import 'app_state/ping_schedule.dart';
import 'app_state/plan_draft.dart';
import 'app_state/text_recognition_edge.dart';
import 'app_state/trip_providers.dart';
import 'repositories/itinerary_sync.dart';
import 'repositories/membership_repository.dart';
import 'repositories/photo_repository.dart';
import 'repositories/photo_sync.dart';
import 'repositories/plan_draft_repository.dart';
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
/// [picker] and [extraction] are the import feature's two seams, on the
/// camera's pattern: the fake picker hands over fixture bytes from memory,
/// and the test extraction runner calls the pure extractor directly — a real
/// isolate under the widget tests' fake clock hangs silently (see
/// import_flow.dart). The app passes neither and gets the native document
/// picker plus `Isolate.run`. [textRecognition] is the third: Apple Vision
/// behind `text_recognition_edge.dart`, whose real channel is judged on a
/// device only, so every automated test binds a fake here.
///
/// [sessions] and [memberId] arrive together and must never disagree: the
/// first is what the sync speaks to the server with, the second is who the
/// app thinks it is, and they are the same account. `main` acquires the
/// session, reads the id off it and hands both in; a test hands in neither
/// and gets [NoSession] and the local stand-in, which is the same pair.
///
/// [sharing] is how a test says where the plan stands with the server without
/// a server: the app binds the real sync's own [TripSync.standings], and a
/// test hands in a stream of its own. Passing nothing means nothing is ever
/// said about sharing, which is exactly right for a suite in which no sync
/// runs — the trip's surfaces stay silent rather than claiming either way.
Widget bootstrapApp({
  AppDatabase? database,
  DateTime? today,
  DateTime? now,
  Duration? utcOffset,
  CameraSource? camera,
  PhotoRepository? photos,
  MembershipRepository? membership,
  FilePickerEdge? picker,
  ExtractionRunner? extraction,
  TextRecognitionEdge? textRecognition,
  SessionSource? sessions,
  String? memberId,
  Stream<SyncOutcome>? sharing,
  LinkOpenerEdge? linkOpener,
}) {
  final db = database ?? openAppDatabase();
  final store = PhotoStore(db);
  final roster = MembershipStore(db);
  final sync = _startSharedFactsSync(db, sessions ?? const NoSession());
  // Always bound, and never conditionally: Riverpod refuses to update a scope
  // whose override *count* changed, and a test that pumps its own scope over
  // this one would break on a binding that came and went.
  final standings =
      sharing ?? sync?.standings ?? const Stream<SyncOutcome>.empty();
  return ProviderScope(
    overrides: [
      sharedFactsStandingProvider.overrideWith((ref) => standings),
      tripRepositoryProvider.overrideWithValue(TripRepository(db)),
      planDraftRepositoryProvider.overrideWithValue(PlanDraftRepository(db)),
      devicePrefsRepositoryProvider.overrideWithValue(
        DevicePrefsRepository(db),
      ),
      linkOpenerEdgeProvider.overrideWithValue(
        linkOpener ?? DeviceLinkOpener(),
      ),
      photoRepositoryProvider.overrideWithValue(photos ?? store),
      photoStoreProvider.overrideWithValue(store),
      membershipRepositoryProvider.overrideWithValue(membership ?? roster),
      membershipStoreProvider.overrideWithValue(roster),
      if (today != null) todayProvider.overrideWithValue(today),
      if (now != null) nowProvider.overrideWithValue(now),
      if (utcOffset != null) tripUtcOffsetProvider.overrideWithValue(utcOffset),
      if (camera != null) cameraSourceProvider.overrideWithValue(camera),
      if (picker != null) filePickerEdgeProvider.overrideWithValue(picker),
      if (extraction != null)
        extractionRunnerProvider.overrideWithValue(extraction),
      if (textRecognition != null)
        textRecognitionEdgeProvider.overrideWithValue(textRecognition),
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
/// The sync itself is still not a provider, and nothing above the seam may
/// ask it to do anything: the class's whole job is to make the Drift store
/// agree with seven other phones, and every screen already reads that store.
/// What *is* handed up is one read-only stream — where each reconcile got to
/// ([TripSync.standings]) — because a plan that never left the phone looked
/// identical to one that had, on every screen, and that silence was the
/// defect (`docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md`).
///
/// Returns null when nothing syncs, which is every test.
TripSync? _startSharedFactsSync(AppDatabase db, SessionSource sessions) {
  const config = SharedFactsConfig.fromEnvironment;
  if (!config.isConfigured || sessions is NoSession) return null;
  final facts = PostgrestSharedFacts(config: config, sessions: sessions);
  // The photographs' own push loop, beside the plan's and under the same
  // guard, sharing one adapter (and so one HTTP client). It exposes nothing
  // upward — no provider, no stream — so this call is the only place the
  // app knows it exists.
  PhotoSync(
    database: db,
    facts: facts,
  ).start(pollEvery: const Duration(minutes: 2));
  return TripSync(
    database: db,
    facts: facts,
    tripRow: tripRowFor(_tripTimeZoneOfThisPhone),
  )..start(pollEvery: const Duration(minutes: 2));
}

/// The trip's clock, if the build insists on one.
///
/// ```sh
/// flutter run --dart-define=CAIRN_TRIP_TIMEZONE=Asia/Tokyo
/// ```
///
/// **No longer a gate**, and that is the whole of defect D3's first half. It
/// used to be a compile-time constant with no default, so an ordinary
/// `flutter build ios` produced a binary that could never create the shared
/// `trips` row and never said so. It survives as an *override* rather than a
/// requirement, because it is the one way to pin the destination's zone on a
/// plan made at home, and pinning it is strictly better than the phone's own
/// answer. Left unset — which is every ordinary build — the phone answers
/// (`_tripTimeZoneOfThisPhone`).
const _tripTimeZoneOverride = String.fromEnvironment('CAIRN_TRIP_TIMEZONE');

/// Which zone the app takes as the trip's, when nothing was passed.
///
/// The phone's own, read through the platform
/// (`app_state/device_time_zone.dart`). Not the device's UTC *offset*: a
/// fixed offset carries no daylight saving and `Etc/GMT±N` cannot spell the
/// half-hour zones a billion people live in, and `trips.timezone` is checked
/// against `pg_timezone_names` at write time anyway. See
/// `docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md` for what this
/// is right about and what it is not.
const _tripTimeZoneOfThisPhone = DeviceTimeZone();

/// Answers with the shared `trips` row to create, or null to say "not yet".
///
/// A function of the [TimeZoneEdge] rather than a bare one, so the app's own
/// answer is the thing a test drives (`test/shared_facts_sync_test.dart`
/// hands it a [FixedTimeZone] and asserts the plan reaches the server on a
/// build with no defines at all).
///
/// **One thing can still be missing, and only one.** The trip's first and
/// last dates are the plan's own resolved dates: `start_date` and `end_date`
/// are `not null` on the server, and inventing a date is the guess the whole
/// paste flow exists to refuse. So a plan that has not said when it happens
/// waits — visibly now, in the trip's own sheet.
///
/// The name is deliberately **not** among them any more. `trips.name` is
/// `not null`, so an unnamed trip is published under
/// [unnamedTripPlaceholder] — the same word the app already shows over a trip
/// nobody has named — and the sync refuses to adopt it back, so nothing here
/// invents a name. A plan that never leaves the phone because nobody typed a
/// title is the worse of the two lies.
TripRowSource tripRowFor(TimeZoneEdge clock) => (pending) async {
  final first = pending.firstDateIso;
  final last = pending.lastDateIso;
  if (first == null || last == null) return null;
  final zone = _tripTimeZoneOverride.isNotEmpty
      ? _tripTimeZoneOverride
      : await clock.ianaName();
  if (zone == null || zone.isEmpty) return null;
  return RemoteTripDraft(
    id: pending.tripId,
    name: pending.name ?? unnamedTripPlaceholder,
    createdBy: pending.startedBy,
    timeZone: zone,
    startDateIso: first,
    endDateIso: last,
  );
};

/// How long a first-ever launch may wait for an account before it gives up
/// and runs as the stand-in.
///
/// Only a phone with nothing in its vault ever waits at all, and this is not
/// the request timeout: `GotrueSessions` keeps its own ten seconds for the
/// round trip, and ten seconds of blank screen on the boot path is well into
/// the launch watchdog's territory. When the budget runs out the sign-in
/// carries on behind the first frame — `GotrueSessions` serialises its calls,
/// so the sync's next reconcile joins the same request rather than minting a
/// second account — and the id it lands lands in the vault for the *next*
/// launch. This one behaves like an offline one.
const _startupSignInBudget = Duration(seconds: 3);

/// Who this phone is, as every surface will ask it for the rest of the launch.
///
/// Resolved before the app is built, because the account's id *is* this
/// phone's member id and a surface that drew itself as `me` and then became a
/// uuid would have credited a photo to a member the roster does not hold. That
/// is also why nothing here adopts an id that arrives *later*: the identity is
/// fixed for the life of the launch, and a session that lands after the budget
/// is picked up next time.
///
/// The vault is asked first and it usually answers: a phone that has signed in
/// before knows its own id from a local file, with no network in it at all, so
/// the boot path does not wait on a server to find out who it is. Refreshing
/// the token is then the sync's business, behind the first frame.
///
/// Null is an ordinary answer — no backend configured, a first launch with no
/// route to one — and the app then runs entirely locally under
/// [localMemberId], which is the whole offline-first story.
Future<String?> resolveMemberId(
  SessionSource sessions,
  SessionVault vault, {
  Duration budget = _startupSignInBudget,
}) async {
  if (sessions is NoSession) return null;
  final stored = await vault.read();
  if (stored != null) return stored.userId;
  final session = await sessions.current().timeout(
    budget,
    onTimeout: () => null,
  );
  return session?.userId.value;
}

/// Where this phone's account is kept between launches.
SessionVault deviceVault() => FileSessionVault();

/// The app's own [SessionSource]: an anonymous GoTrue account, kept across
/// launches. See `storage/remote/gotrue_sessions.dart` for why it is
/// anonymous and what Apple sign-in replaces.
SessionSource deviceSessions({
  SharedFactsConfig config = SharedFactsConfig.fromEnvironment,
  SessionVault? vault,
}) {
  if (!config.isConfigured) return const NoSession();
  return GotrueSessions(config: config, vault: vault ?? deviceVault());
}
