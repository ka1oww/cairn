// STORAGE band (docs/architecture.md): the *other* backend. The map has drawn
// a "Supabase/R2 client adapter" node beside the Drift store since it was
// first written; this file is the half of it the shared facts need.
//
// It knows Supabase and knows nothing of Cairn's screens, providers or
// features — exactly as `drift/app_database.dart` knows SQLite and nothing
// else. The only band allowed to import it is `repositories/`, which is the
// one layer that knows both backends exist.
//
// **What a shared fact is.** Three things move: the trip's own row (its name
// and who started it), the roster, and the itinerary. Nothing else does. The
// trail, the stars, the gate and the ping schedule are computed on the phone
// and must never move server-side without a deliberate decision (AGENTS.md);
// storing a shared fact is not computing on the server
// (docs/decisions/2026-08-22-grill-round-one.md §2).
//
// **Nothing here holds a key.** [SharedFactsConfig] reads the project URL and
// the publishable anon key out of `--dart-define`s, so neither is ever in the
// repository, and both are absent by default — an app built without them has
// no backend at all and behaves exactly as it did before this file existed.
import 'package:cairn_model/cairn_model.dart';

/// Where the backend is, if there is one.
///
/// Supplied at build time:
///
/// ```sh
/// flutter run --dart-define=CAIRN_SUPABASE_URL=https://<ref>.supabase.co \
///             --dart-define=CAIRN_SUPABASE_ANON_KEY=<publishable key>
/// ```
///
/// The anon key is the *publishable* one — it is designed to ship inside a
/// client and grants nothing on its own, because every table in
/// `supabase/migrations/` is behind row-level security keyed on `auth.uid()`.
/// The service-role key must never appear here, in a define, or anywhere else
/// in this repository.
class SharedFactsConfig {
  final String url;
  final String anonKey;

  const SharedFactsConfig({required this.url, required this.anonKey});

  /// What the build was told. Both blank is the ordinary case today: no
  /// Supabase project has been created (`supabase/README.md`).
  static const fromEnvironment = SharedFactsConfig(
    url: String.fromEnvironment('CAIRN_SUPABASE_URL'),
    anonKey: String.fromEnvironment('CAIRN_SUPABASE_ANON_KEY'),
  );

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
/// Deliberately an interface with no real implementation in this slice.
/// Sign in with Apple is the first auth route and is not built
/// (docs/architecture.md, "Platform edges"), so the app binds [NoSession] and
/// every sync is dormant rather than pretending. This is the same shape the
/// notification edge has: the machine above it is real and tested, and the
/// last inch is honestly absent.
abstract interface class SessionSource {
  Future<SharedFactsSession?> current();
}

/// Nobody is signed in, and nothing is pending. What the app binds today.
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

  const RemoteStop({required this.position, required this.text, this.timeIso});
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
}
