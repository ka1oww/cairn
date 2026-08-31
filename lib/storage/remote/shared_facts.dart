// STORAGE band (docs/architecture.md): the *other* backend. The map has drawn
// a "Supabase/R2 client adapter" node beside the Drift store since it was
// first written; this file is the half of it the shared facts need.
//
// It knows Supabase and knows nothing of Cairn's screens, providers or
// features — exactly as `drift/app_database.dart` knows SQLite and nothing
// else. The only band allowed to import it is `repositories/`, which is the
// one layer that knows both backends exist.
//
// **What a shared fact is.** Four things move: the trip's own row (its name
// and who started it), the roster, the itinerary, and the photographs —
// which were the founding shared fact all along; the pool is the product.
// Nothing else does. The trail, the stars, the gate and the ping schedule
// are computed on the phone and must never move server-side without a
// deliberate decision (AGENTS.md); storing a shared fact is not computing on
// the server (docs/decisions/2026-08-22-grill-round-one.md §2).
//
// **Nothing here holds a secret.** [SharedFactsConfig] still reads the project
// URL and the publishable anon key out of `--dart-define`s; what changed on
// 2026-08-26 is that the defines now *default* to the hosted project, so an
// ordinary `flutter run` reaches it. The anon key is publishable by design —
// it identifies the project and grants nothing on its own, because every
// table in `supabase/migrations/` is behind row-level security keyed on
// `auth.uid()` and a request without a session reaches zero rows. The
// service-role key and the database password are a different kind of thing
// and must never appear here, in a define, or anywhere else in this
// repository.
import 'dart:typed_data';

import 'package:cairn_model/cairn_model.dart';

/// Where the backend is, if there is one.
///
/// The defaults below are the hosted project, so an ordinary build reaches it
/// with nothing passed. Point a build somewhere else — a branch project, a
/// `supabase start` stack — by overriding either define:
///
/// ```sh
/// flutter run --dart-define=CAIRN_SUPABASE_URL=https://<ref>.supabase.co \
///             --dart-define=CAIRN_SUPABASE_ANON_KEY=<publishable key>
/// ```
///
/// Passing an empty URL is how a build asks for *no* backend at all, which is
/// what the app did before the project existed: the sync reports itself
/// dormant and the phone is entirely local. It is not how the test suite stays
/// offline — `flutter test` passes no defines, so this is the hosted project
/// there too, and what keeps it from reaching out is that every test binds
/// [NoSession] (`bootstrap.dart`).
class SharedFactsConfig {
  final String url;
  final String anonKey;

  const SharedFactsConfig({required this.url, required this.anonKey});

  /// The hosted project, unless the build said otherwise.
  ///
  /// Both values are public: the URL is a hostname and the key is the
  /// *publishable* anon key, which is designed to ship inside a client. See
  /// this file's header for why that is safe and what is not.
  static const fromEnvironment = SharedFactsConfig(
    url: String.fromEnvironment('CAIRN_SUPABASE_URL', defaultValue: hostedUrl),
    anonKey: String.fromEnvironment(
      'CAIRN_SUPABASE_ANON_KEY',
      defaultValue: hostedAnonKey,
    ),
  );

  /// The project `supabase/migrations/` has actually been applied to.
  static const hostedUrl = 'https://nswcgzhynclrrunekskh.supabase.co';

  /// Its publishable anon key. Not a secret; see the header.
  static const hostedAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
      'eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5zd2Nnemh5bmNscnJ1bmVrc2toIiwicm9sZS'
      'I6ImFub24iLCJpYXQiOjE3ODc2OTQyMzMsImV4cCI6MjEwMzI3MDIzM30.'
      'VdEogHbh-HNzjcAwXXHuE0FBPh_f3fHJDNHHC-w_sS4';

  bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}

/// Who the phone is signed in as, and the token it speaks with.
///
/// Every policy in the schema is written against `auth.uid()`, so a request
/// without one of these reaches nothing at all — not "reads less", *nothing*,
/// because row-level security refuses by filtering to zero rows.
class SharedFactsSession {
  /// The GoTrue access token, sent as `Authorization: Bearer`.
  final String accessToken;

  /// `auth.users.id`, which is also `profiles.id` and the member id every
  /// roster row is keyed by.
  final MemberId userId;

  const SharedFactsSession({required this.accessToken, required this.userId});
}

/// Where a session comes from.
///
/// Two implementations, and the difference between them is the whole of the
/// app's auth story today. [NoSession] is what a test and a backend-less
/// build get. `GotrueSessions` (`gotrue_sessions.dart`) is what a real build
/// gets: an *anonymous* account, which is the dev and test stand-in for Sign
/// in with Apple until Apple lands (docs/architecture.md, "Platform edges").
///
/// A source must answer null rather than throw when the phone simply cannot
/// reach the server. The sync reads that as dormant and leaves the local copy
/// alone, which is the offline story; an exception here would surface a
/// network blip as a fault.
abstract interface class SessionSource {
  Future<SharedFactsSession?> current();
}

/// Nobody is signed in, and nothing is pending. What a test binds, and what a
/// build told `CAIRN_SUPABASE_URL=` (empty) gets.
class NoSession implements SessionSource {
  const NoSession();

  @override
  Future<SharedFactsSession?> current() async => null;
}

/// The server could not be reached, or answered in a way that says "later":
/// no connection, a timeout, a 5xx, a project resumed from its free-tier
/// pause. The caller's contract is to leave the local copy exactly as it is
/// and try again — never to surface an error to a person who is simply on a
/// train.
class SharedFactsUnavailable implements Exception {
  final String reason;
  const SharedFactsUnavailable(this.reason);

  @override
  String toString() => 'SharedFactsUnavailable: $reason';
}

/// The server understood and said no: not a member, a code that is not a
/// code, a row that already exists. Retrying changes nothing, so the caller
/// must not.
class SharedFactsRefused implements Exception {
  final String reason;
  const SharedFactsRefused(this.reason);

  @override
  String toString() => 'SharedFactsRefused: $reason';
}

/// The object store said no to a PUT — which is the opposite of what a
/// refusal means everywhere else, and why this is its own type rather than a
/// [SharedFactsRefused].
///
/// A 4xx at the presigned PUT almost always means the *ticket* died — its
/// five minutes ran out, or a clock skewed — not that the photograph is
/// unwelcome. The outbox answers it by minting a fresh ticket and trying
/// again on its backoff; surrendering here would terminally refuse a
/// photograph over a slow lift lobby.
class UploadTicketRejected implements Exception {
  final String reason;
  const UploadTicketRejected(this.reason);

  @override
  String toString() => 'UploadTicketRejected: $reason';
}

// ---------------------------------------------------------------------------
// What crosses the wire
// ---------------------------------------------------------------------------

/// One day of the shared itinerary, with the clock the merge is decided on.
///
/// Dates and times are ISO strings rather than `CalendarDate`/`ClockTime`
/// because this is the storage band: it speaks the wire's spelling, and the
/// seam above translates. (The same division the Drift store makes — it
/// stores `dateIso`, not a `CalendarDate`.)
class RemoteDay {
  final int number;

  /// `YYYY-MM-DD`, or null while this day's date is still open.
  final String? dateIso;

  final String? place;

  /// When this day was last changed, on whichever phone changed it. UTC.
  final DateTime revisedAt;

  final List<RemoteStop> stops;

  RemoteDay({
    required this.number,
    this.dateIso,
    this.place,
    required this.revisedAt,
    List<RemoteStop> stops = const [],
  }) : stops = List.unmodifiable(stops);
}

/// One stop under a day, in the day's own order. No clock of its own: the day
/// is the merge atom, so a stop cannot win or lose independently of it.
class RemoteStop {
  final int position;
  final String text;

  /// `HH:MM`, or null for an untimed stop. A stop is starred exactly when
  /// this is present — the rule lives in `cairn_model.Stop.isStarred` and is
  /// never a column, here or in Postgres.
  final String? timeIso;
  final String? area;
  final String? areaSource;

  const RemoteStop({required this.position, required this.text, this.timeIso, this.area, this.areaSource});
}

/// A line the parser could not place, or one somebody took out of a day.
/// Nothing pasted is ever deleted (AGENTS.md), so the pocket travels too.
class RemoteSetAside {
  final int position;
  final int sourceLineNumber;
  final String text;
  final String explanation;

  const RemoteSetAside({
    required this.position,
    required this.sourceLineNumber,
    required this.text,
    required this.explanation,
  });
}

/// The whole plan as the trip holds it, either being pushed or handed back.
class RemoteItinerary {
  /// The plan's *shape* revision: when its set of day numbers last moved.
  final DateTime planRevisedAt;

  /// The set-aside pocket's own clock — one atom, so one instant.
  final DateTime pocketRevisedAt;

  final List<RemoteDay> days;
  final List<RemoteSetAside> setAside;

  RemoteItinerary({
    required this.planRevisedAt,
    required this.pocketRevisedAt,
    List<RemoteDay> days = const [],
    List<RemoteSetAside> setAside = const [],
  }) : days = List.unmodifiable(days),
       setAside = List.unmodifiable(setAside);
}

/// One person on the trip, as the server knows them.
///
/// It carries the *instant* they joined and not the trip day, deliberately:
/// which day of the trip that instant falls on is a function of the itinerary
/// and the trip's clock, and both of those are the phone's to read. The
/// server hands over the fact; the phone counts the days
/// (`supabase/migrations/0010_trip_itinerary.sql`, `trip_roster`).
class RemoteMember {
  final MemberId id;
  final String displayName;
  final DateTime joinedAt;

  const RemoteMember({
    required this.id,
    required this.displayName,
    required this.joinedAt,
  });
}

/// The trip's own shared facts: what it is called, who started it, and who is
/// on it.
class RemoteTrip {
  final TripId id;
  final String? name;
  final MemberId startedBy;
  final List<RemoteMember> members;

  RemoteTrip({
    required this.id,
    this.name,
    required this.startedBy,
    List<RemoteMember> members = const [],
  }) : members = List.unmodifiable(members);
}

/// Everything the shared `trips` row needs that the phone does not already
/// have in `trip_facts`: the trip's clock and its dates.
///
/// A separate type because it is the one input this slice cannot supply. The
/// app asks for country and city and derives the IANA zone from them
/// (`supabase/README.md`) — and it asks at sign-in, which does not exist.
/// Until it does, nothing constructs one of these outside a test, and
/// `TripSync` says so rather than inventing a zone.
class RemoteTripDraft {
  final TripId id;
  final String name;
  final MemberId createdBy;

  /// An IANA name (`Asia/Tokyo`). Validated at write time by a trigger, so a
  /// wrong one fails here rather than on eight phones later
  /// (`supabase/migrations/0003_trips.sql`).
  final String timeZone;

  final String? country;
  final String? city;

  /// `YYYY-MM-DD`. The trip's first and last dated day.
  final String startDateIso;
  final String endDateIso;

  const RemoteTripDraft({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.timeZone,
    this.country,
    this.city,
    required this.startDateIso,
    required this.endDateIso,
  });
}

/// One row of the trip's shared photo index, spelled as the wire spells it.
///
/// The *index* and never the image: the bytes live in the object store under
/// [r2ObjectKey], and a row exists only once they do — bytes first, row
/// second is the seam's ordering rule (docs/architecture.md, "The outbox").
class RemotePhoto {
  /// Dashed lower-case uuid, minted on the phone (`mintPhotoId`).
  final String id;

  final String tripId;
  final String contributorId;

  /// Where the bytes are. **Server-derived**: the upload ticket named it and
  /// the phone carried it, because the key-derivation rule lives in
  /// `r2-upload-url` and a second copy could drift.
  final String r2ObjectKey;

  final String contentType;
  final int byteSize;

  /// Pixel dimensions, when known. This slice sends null — nothing decodes
  /// the frame at enqueue.
  final int? width, height;

  /// When it was taken, as a UTC instant. Null tolerated on a pull.
  final String? capturedAtIso;

  final double? capturedLatitude, capturedLongitude;
  final String? captureTimezone;

  /// The photograph's home (`photo-day-key`, settled): the 1-based day of
  /// the plan. **Always present** — a photo is taken on a day whether or not
  /// that day has a date, and uploading never waits on one.
  final int dayNumber;

  /// The derived calendar view of [dayNumber], or null while that day's date
  /// is still open. Along for the ride, never the identity.
  final String? tripDayIso;

  /// The capture word (`caption-travels`, settled): single-owner, the
  /// contributor's latest write wins, no conflict machinery.
  final String? caption;

  /// The server's `updated_at` — the pull cursor's clock. Ignored on a push:
  /// the server's touch trigger owns it.
  final String updatedAtIso;

  const RemotePhoto({
    required this.id,
    required this.tripId,
    required this.contributorId,
    required this.r2ObjectKey,
    required this.contentType,
    required this.byteSize,
    this.width,
    this.height,
    this.capturedAtIso,
    this.capturedLatitude,
    this.capturedLongitude,
    this.captureTimezone,
    required this.dayNumber,
    this.tripDayIso,
    this.caption,
    required this.updatedAtIso,
  });
}

/// A short-lived, single-object, write-only permission to land one
/// photograph's bytes.
///
/// **A bearer capability, and never persisted**: it lives five minutes, so
/// the outbox mints one per attempt and a crash simply lets it expire
/// harmlessly. [contentType] and [byteSize] are the two facts the signature
/// covers — the PUT must repeat exactly these, or the store refuses it.
class RemoteUploadTicket {
  final Uri uploadUrl;

  /// Where the bytes will live — the fact the phone keeps once the PUT
  /// lands, since the eventual [RemotePhoto] row must name it.
  final String objectKey;

  final String contentType;
  final int byteSize;
  final DateTime expiresAt;

  const RemoteUploadTicket({
    required this.uploadUrl,
    required this.objectKey,
    required this.contentType,
    required this.byteSize,
    required this.expiresAt,
  });
}

/// The backend, as one interface.
///
/// Nothing above `repositories/` may name it, and nothing in the app outside
/// this directory may import a Supabase or HTTP symbol (docs/architecture.md,
/// the "Supabase/R2 client adapter" row). Its methods are exactly the shared
/// facts and no more.
abstract interface class SharedFacts {
  /// Who this phone is signed in as, or null. Every other method needs one.
  Future<SharedFactsSession?> session();

  /// The trip's shared facts, or null when this server has never heard of it.
  ///
  /// Null is an ordinary answer, not an error: a trip is minted on the phone
  /// and can be walked for a fortnight before anything syncs
  /// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md).
  Future<RemoteTrip?> readTrip(TripId tripId);

  /// Creates the shared `trips` row for a trip the phone already minted.
  ///
  /// **A plain insert, never an upsert.** A uuid collision between two phones
  /// is vanishingly unlikely, but `on conflict do update` would merge two
  /// parties' trips into one where an insert raises
  /// (`supabase/migrations/0003_trips.sql`). A row that already exists comes
  /// back as [SharedFactsRefused], which is the honest answer to "make this".
  Future<void> createTrip(RemoteTripDraft draft);

  /// Pushes this phone's plan and returns the plan the trip holds once it was
  /// merged in — one round trip, both directions.
  ///
  /// The merge is last-write-wins per day and happens inside
  /// `sync_trip_itinerary`, because PostgREST has no client transaction and
  /// cannot express "overwrite only if newer" as an upsert at all. A phone
  /// with no plan of its own pulls by pushing nothing: an empty [days] and a
  /// [planRevisedAt] at the epoch wins nothing and deletes nothing.
  Future<RemoteItinerary> syncItinerary({
    required TripId tripId,
    required DateTime planRevisedAt,
    required List<RemoteDay> days,
    required DateTime pocketRevisedAt,
    required List<RemoteSetAside> setAside,
  });

  /// Mints a ticket to land one photograph's bytes.
  ///
  /// Wraps `r2-upload-url`, which checks membership and the trip's close as
  /// the caller before it signs anything. [byteSize] is required because the
  /// signature covers it — a PUT of any other length is refused by the store
  /// rather than by anyone who could explain.
  ///
  /// A [SharedFactsRefused] here is terminal for the photograph: not a
  /// member, the trip closed past its grace, or the id already claimed by a
  /// row — and the ordering rule is what makes that last refusal cost the
  /// retry path nothing, because a retry of an upload that never landed
  /// happens while no row exists.
  Future<RemoteUploadTicket> photoUploadTicket({
    required TripId tripId,
    required String photoId,
    required String contentType,
    required int byteSize,
  });

  /// Lands the bytes the ticket was minted for.
  ///
  /// Bytes, not a stream: a median original is ~3 MB
  /// (`docs/storage-and-cost.md`, measured) and fits in memory without
  /// ceremony. Idempotent by construction — re-PUTting identical bytes to
  /// the same immutable key is how a lost 200 replays safely. Throws
  /// [UploadTicketRejected] when the store says no, which the caller answers
  /// with a fresh ticket, never with surrender.
  Future<void> putPhotoBytes(RemoteUploadTicket ticket, Uint8List bytes);

  /// Inserts the photo's index row — the second half of the ordering, only
  /// ever called once the bytes have landed.
  ///
  /// Idempotent: an insert that finds its row already there is a silent
  /// success, so a crash between the insert landing and its ack replays as a
  /// no-op. That is what closes the crash matrix, and it is safe *because*
  /// the ticket mint refuses claimed ids — nobody else's bytes can be behind
  /// this phone's id.
  Future<void> recordPhoto(RemotePhoto photo);

  /// Rewrites the caption on this phone's own photo row, or clears it.
  ///
  /// Single-owner by the policy that already exists (`photos` UPDATE is
  /// contributor-only), so "the owner's latest write wins" needs nothing
  /// beyond the row's own `updated_at` touch. No per-field clock, no
  /// editable-shared-field machinery — deliberately.
  Future<void> writePhotoCaption({
    required TripId tripId,
    required String photoId,
    required String? caption,
  });
}
