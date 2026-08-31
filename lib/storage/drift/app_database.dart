// STORAGE band (docs/architecture.md): the Drift store. Knows Drift and the
// device disk; knows nothing of who asks. Queried only by repositories/.
import 'dart:math';

import 'package:cairn_model/cairn_model.dart' show TripId;
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// The instant a row carries before anything has ever synced.
///
/// It is a real timestamp rather than null so the merge comparison is total —
/// `revisedAtUtcIso` is the plan's clock and a null clock would need a special
/// case at every comparison — and it is the epoch so that anything a phone or
/// a server has actually said beats it.
const beforeAnySync = '1970-01-01T00:00:00.000Z';

/// One day of the confirmed itinerary, as accepted on the paste-and-confirm
/// screen. The date is nullable on purpose: the parser never guesses a date
/// it cannot resolve, and a person is allowed to accept the plan with a date
/// still open (docs/decisions/2026-08-22-paste-confirmation.md).
class ItineraryDays extends Table {
  /// 1-based position in the trip; the itinerary's one ordering.
  IntColumn get number => integer()();

  /// `YYYY-MM-DD` (`cairn_model.CalendarDate.iso`), or null while unresolved.
  TextColumn get dateIso => text().nullable()();

  TextColumn get place => text().nullable()();

  /// When this day was last *changed*, on whichever phone changed it.
  ///
  /// **The merge clock**, and the local half of
  /// `supabase/migrations/0010_trip_itinerary.sql`'s
  /// `trip_itinerary_days.revised_at`. The itinerary is a shared stored fact
  /// merged last-write-wins per day, so every day needs its own instant: a
  /// day nobody touched must be able to lose to nothing, and a day this phone
  /// edited offline must be able to win when it reconnects.
  ///
  /// It is stamped only when the day's *content* changes. Saving a plan whose
  /// day 3 is byte-for-byte what was already stored leaves day 3's clock
  /// alone — otherwise every save would claim every day and a phone that
  /// merely re-accepted a plan would clobber everyone else's edits.
  TextColumn get revisedAtUtcIso =>
      text().withDefault(const Constant(beforeAnySync))();

  @override
  Set<Column> get primaryKey => {number};
}

/// A stop under a day, in itinerary order. The star is not a column: a stop
/// is starred exactly when [timeIso] is present — the star rule lives in
/// `cairn_model.Stop.isStarred` and storing it separately would let the two
/// drift apart.
class ItineraryStops extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get dayNumber => integer().references(ItineraryDays, #number)();

  /// Order within the day, 0-based.
  IntColumn get position => integer()();

  TextColumn get stopText => text()();

  /// `HH:MM` (`cairn_model.ClockTime.iso`), or null for an untimed stop.
  TextColumn get timeIso => text().nullable()();

  /// What the stop is: place / areaHeading / mealLabel / note.
  TextColumn get kind => text().withDefault(const Constant('place'))();

  /// Area in force for this stop, or null = send nothing (rule 3).
  TextColumn get areaText => text().nullable()();

  /// Provenance: `traveller-own` | `human` | `parser`, or null when
  /// [areaText] is null.
  TextColumn get areaSource => text().nullable()();
}

/// App-level preferences (one row, id 1). Local-only, never synced.
class AppPreferences extends Table {
  IntColumn get id => integer()();

  /// `googleMaps` | `appleMaps` | `waze`.
  TextColumn get mapsApp => text().withDefault(const Constant('googleMaps'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A pasted line the parser set aside instead of placing — kept with its
/// person-showable reason, never silently dropped ("the trip's pocket" in
/// design round 8). Stored so the kept lines survive the confirmation screen
/// and can be placed by hand in a later slice.
class ItinerarySetAsides extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Order the lines are shown in, 0-based.
  IntColumn get position => integer()();

  /// 1-based line number in the original paste.
  IntColumn get sourceLineNumber => integer()();

  TextColumn get lineText => text()();

  /// The parser's person-showable sentence for why the line was set aside.
  TextColumn get explanation => text()();
}

/// One photo taken on this phone and kept in the trip's pool.
///
/// **The bytes are not here.** They sit on the device disk at [filePath];
/// this row is the index, which is the same division the backend draws
/// (Postgres indexes, R2 holds bytes — `supabase/README.md`). Nothing in
/// this table is ever the image.
///
/// It is written against `cairn_model`'s vocabulary — a row round-trips to a
/// `PhotoRef` plus the two things a `PhotoRef` deliberately does not carry:
/// where the bytes are, and the word.
class Photos extends Table {
  /// The photo's id, minted on this phone. When the pool becomes shared this
  /// is the `photos.id` uuid; until then it is a local one.
  TextColumn get id => text()();

  /// The 1-based day of the plan this photo belongs to.
  ///
  /// For a photo the app took, this is known exactly — it is the day you
  /// were standing in. Deciding it for an *imported* photo is
  /// `packages/photo_day_assignment`'s job, and the import sweep is not
  /// built; nothing here guesses.
  IntColumn get dayNumber => integer()();

  /// Who took it. Accounts do not exist yet, so every row on this phone
  /// carries the same local id — see `localMemberId` in
  /// `lib/app_state/capture_flow.dart`.
  TextColumn get contributorId => text()();

  /// When it was taken, as a UTC ISO-8601 instant.
  ///
  /// Text rather than drift's `dateTime()` on purpose: `PhotoRef` refuses a
  /// non-UTC instant, and a column that stores unix seconds loses the
  /// evidence of which zone the value was built in. What hour a photo
  /// *reads* as is the day's clock's business, never this column's.
  TextColumn get takenAtUtcIso => text()();

  /// `pinged` or `imported` — `cairn_model.PhotoOrigin`'s name. Stored
  /// because it changes how much the instant is worth.
  TextColumn get origin => text()();

  /// The word, if any. Null is the usual: the caption line is skippable by
  /// construction and blank is the common answer (design round 10, `18a`).
  TextColumn get word => text().nullable()();

  /// Where the bytes are on this device, or null when they are not here.
  ///
  /// Nullable since v8, because the pool is becoming shared: a row pulled
  /// from another phone is a real photograph whose bytes have not been
  /// fetched yet, and that is a permanent, legible state — not a defect
  /// (`PooledPhoto.localPath` says the same thing one band up). Every photo
  /// this phone captures still writes a path.
  TextColumn get filePath => text().nullable()();

  /// The frame's MIME type (`image/jpeg`, `image/heic`, `image/png`), or
  /// null for a row written before v8.
  ///
  /// Filled at capture, because the upload needs it twice — the ticket signs
  /// it and the PUT must repeat it exactly — and a pulled row needs it to
  /// name its cache file's extension.
  TextColumn get contentType => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One photograph this phone still owes the shared pool — the outbox.
///
/// **The cursor, not the cargo**, exactly as [SyncStates] is for the plan: a
/// [Photos] row stays a mirror of the shared fact, and what this phone has
/// or has not managed to push lives here beside it. A photo with no row here
/// is settled — either it crossed and the row was deleted, or it was never
/// this phone's to push. That absence being the success state is deliberate:
/// an empty outbox legibly means "nothing pending".
///
/// A durable state is exactly a place a crash can leave you. In-flight facts
/// are not states: an upload ticket lives five minutes and is a bearer
/// capability, so it is minted per attempt and **never written to disk**.
class PhotoOutbox extends Table {
  /// The photo this row is about.
  TextColumn get photoId => text().references(Photos, #id)();

  /// Where the push stands: `queued` (nothing is known to be durable
  /// remotely), `uploaded` (a PUT returned 200; never re-mint past this),
  /// `caption` (the row crossed but its word has changed since), or
  /// `refused` (the server ruled; terminal, never retried).
  TextColumn get state => text()();

  /// How many attempts have failed. Drives the backoff and never
  /// terminates: the real deadline is the server's own close-plus-grace
  /// check, relayed as `refused` when passed.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// When the next attempt is due. Set to "now" at enqueue; pushed out by
  /// the backoff on failure.
  TextColumn get nextAttemptAtUtcIso => text()();

  /// The object key the bytes landed under, set with `uploaded`.
  ///
  /// Persisted because it is part of what `uploaded` durably means — "the
  /// bytes are at this key" — and the record insert must name it after a
  /// crash. The ticket handed it over; the phone never derives a key of its
  /// own, because the derivation rule lives in `r2-upload-url` and a second
  /// copy here could drift.
  TextColumn get r2ObjectKey => text().nullable()();

  /// How many bytes landed, set with `r2ObjectKey` and for the same reason:
  /// the record insert must say `byte_size`, and reading the file again
  /// after a crash assumes a file the crash may have taken.
  IntColumn get uploadedByteSize => integer().nullable()();

  /// Why the last attempt failed, for a log or a test. **Never rendered** —
  /// the `SyncOutcome.detail` rule.
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {photoId};
}

/// The trip itself: the facts that are true of it rather than of any one day.
///
/// **Exactly one row, always id 1.** There is one trip per phone until trips
/// are shared (Phase 2, `docs/roadmap.md`), and a table with a fixed key is
/// how that stays a fact the schema states rather than a convention the code
/// remembers. When a phone can be on two trips this grows a real key and
/// everything above it already asks for a trip by id.
class TripFacts extends Table {
  /// Always 1. See the class comment.
  IntColumn get id => integer()();

  /// The trip's id, as the ping derivation seeds itself from.
  ///
  /// **Minted here, and never reissued.** The phone writes a real uuid the
  /// moment the trip is started, with no connection and nothing to ask
  /// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md); when the trip
  /// first syncs, `trips.id` takes this string rather than handing back
  /// another. It is not "local until Postgres mints one" — there is one mint,
  /// it happens here, and this row is where it becomes durable.
  TextColumn get tripId => text()();

  /// What the trip is called, or null while nobody has named it. Any member
  /// may rename it (docs/decisions/2026-08-22-starter-and-container.md §2),
  /// so this column is not the starter's.
  TextColumn get name => text().nullable()();

  /// Who started the trip.
  ///
  /// A fact about the trip, never a rank on a membership row — which is why
  /// it is a column here and there is no role column on [TripMembers]. They
  /// may have left; see `cairn_model`'s `removalPowerHolder`.
  TextColumn get startedByMemberId => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Who is on this trip.
///
/// **There is no role column and there must never be one.** Roles are flat
/// (docs/decisions/2026-08-22-last-calls.md §1): the one asymmetry is who
/// started the trip, and that is a column on [TripFacts]. A role here would
/// be a rank a person carries, which is the thing the record refuses.
///
/// Only one row can be written today — this phone's own — because nothing
/// carries anyone else's membership here yet. That is Phase 2's job, and
/// this table is the shape it lands in.
class TripMembers extends Table {
  /// The member's id. The local person's is `localMemberId`; when accounts
  /// exist this is the `profiles.id` uuid.
  TextColumn get id => text()();

  /// The name credited under this person's photos.
  TextColumn get displayName => text()();

  /// The 1-based day of the trip this person joined on. 1 for everyone who
  /// was here before it started; a day-3 joiner gets days 1 and 2 freely.
  IntColumn get joinedOnDay => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {id};
}

/// The invite codes minted for this trip.
///
/// **No expiry column.** A code dies when the trip closes and at no other
/// time (`cairn_model`'s `tripClosesAt`), so storing an expiry here would be
/// a second copy of the trip's ending, free to disagree with the first. The
/// server's table has none either, for the same reason: it derives the close
/// from the trip (`trip_closes_at` in
/// `supabase/migrations/0005_trip_invites.sql`) every time a code is
/// redeemed.
class TripInviteCodes extends Table {
  /// The code as it is written down: `otter maple 42`. Canonical, so the
  /// same code said two ways is one row.
  TextColumn get code => text()();

  /// Who minted it. Minting is flat — any member may
  /// (docs/decisions/2026-08-22-starter-and-container.md §3) — and revoking
  /// belongs to whoever minted it or to the starter, which is why this is
  /// kept.
  TextColumn get mintedByMemberId => text()();

  TextColumn get mintedAtUtcIso => text()();

  /// When it was shut, or null while it still admits people. Rotating a code
  /// is minting a new one and revoking the old; a code is never repointed at
  /// another trip, which the server refuses at the database level.
  TextColumn get revokedAtUtcIso => text().nullable()();

  @override
  Set<Column> get primaryKey => {code};
}

/// What this phone knows about the trip's *shared* copy of itself.
///
/// **Exactly one row, always id 1**, for the reason [TripFacts] has one. It is
/// deliberately a table of its own rather than columns on [TripFacts]: the
/// itinerary is written before the trip is started (accepting a plan saves the
/// plan, then starts the trip), so a phone can hold a plan revision before it
/// holds a trip at all.
///
/// Nothing here is a shared fact. Every column is this phone's own record of
/// what it has said to the server and what the server last said back — the
/// cursor, not the cargo.
class SyncStates extends Table {
  /// Always 1.
  IntColumn get id => integer()();

  /// The plan's *shape* revision: when the set of day numbers last changed.
  ///
  /// Separate from any day's own clock because deleting a day is not an edit
  /// to a day — there is no row left to carry the instant. A push hands this
  /// over so the server can tell "I dropped day 4" from "I have never heard
  /// of day 4", which is the difference between removing a day and silently
  /// deleting somebody else's new one
  /// (`supabase/migrations/0010_trip_itinerary.sql`).
  TextColumn get planRevisedAtUtcIso =>
      text().withDefault(const Constant(beforeAnySync))();

  /// The set-aside pocket's clock. The pocket has no days, so it is one atom
  /// with one instant — and the instant lives here rather than on the lines so
  /// that *emptying* the pocket still carries a revision.
  TextColumn get pocketRevisedAtUtcIso =>
      text().withDefault(const Constant(beforeAnySync))();

  /// When the shared `trips` row was last confirmed to exist, or null while
  /// this trip has never been seen by a server.
  TextColumn get tripRowSyncedAtUtcIso => text().nullable()();

  /// When the itinerary and the roster last reconciled successfully. Null
  /// means never; an old value means the phone has been offline since.
  TextColumn get itinerarySyncedAtUtcIso => text().nullable()();
  TextColumn get rosterSyncedAtUtcIso => text().nullable()();

  /// The photo pull's cursor: the highest `photos.updated_at` this phone has
  /// applied, or null while it has never pulled. Written in v8 beside the
  /// outbox because one migration beats two; nothing reads it until the pull
  /// half is built.
  TextColumn get photosUpdatedCursor => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The paste box's pending import, kept across launches.
///
/// This is **not** a shared fact and never becomes one: it is pre-accept
/// text on one phone, it is never pushed anywhere (the sync's cargo is the
/// itinerary and the roster, and this table is not in either), and it stops
/// existing the moment the plan is accepted. What it buys is the one thing
/// the person cannot recreate cheaply: a three-page scan that went through
/// text recognition and then died with the process.
///
/// One row, always id 1, exactly like [SyncStates] — a phone has one paste
/// box, and a second draft would be a second box nobody can reach.
class PlanDrafts extends Table {
  /// Always 1.
  IntColumn get id => integer()();

  /// The box's text as it last stood.
  TextColumn get planText => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    ItineraryDays,
    ItineraryStops,
    ItinerarySetAsides,
    Photos,
    PhotoOutbox,
    TripFacts,
    TripMembers,
    TripInviteCodes,
    SyncStates,
    PlanDrafts,
    AppPreferences,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// [mint] exists for tests, which pin the id so an assertion can name it.
  /// Every other caller takes [mintTripId].
  AppDatabase(super.e, {this.mint = mintTripId});

  /// Where a trip's id comes from. See [mintTripId].
  final TripId Function() mint;

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      // `createTable` builds a table in the *current* schema, so a table
      // created by an earlier branch of this very upgrade must not have a
      // later branch retrofit columns it was born with.
      var photosBornCurrent = false;
      var syncStatesBornCurrent = false;
      if (from < 2) {
        // v1 was the scaffold's single disposable trip_drafts row: a
        // draft with no trip id at all, which is the sidestep
        // docs/decisions/2026-08-25-the-trip-mints-its-own-id.md closed.
        // It was demo data from the day it landed; the itinerary tables
        // replace it and nothing carries over.
        await m.deleteTable('trip_drafts');
        // createAll() builds every table in the *current* schema, photos
        // included, so this branch is finished — falling through would
        // try to create it twice.
        await m.createAll();
        photosBornCurrent = true;
        syncStatesBornCurrent = true;
        return;
      }
      if (from < 3) {
        await m.createTable(photos);
        photosBornCurrent = true;
      }
      if (from < 4) {
        await m.createTable(tripFacts);
        await m.createTable(tripMembers);
        await m.createTable(tripInviteCodes);
        // A phone that already had a plan already had a trip: it was
        // started here, by the person holding it, on the day they
        // accepted the paste. Backfilling it is not inventing a fact --
        // the alternative is a saved itinerary with nobody on it, which
        // would deal no pings and show an empty roster.
        await customStatement(
          // 'local-trip' is what every trip on this phone was called
          // before the mint existed. It is written here as history rather
          // than fixed here, because v5 below is the one place that heals
          // it — a phone that reached v4 on an earlier build needs the
          // same repair and would never run this branch.
          "insert into trip_facts (id, trip_id, started_by_member_id) "
          "select 1, 'local-trip', 'me' "
          "where exists (select 1 from itinerary_days)",
        );
        await customStatement(
          "insert into trip_members (id, display_name, joined_on_day) "
          "select 'me', 'You', 1 "
          "where exists (select 1 from itinerary_days)",
        );
      }
      if (from < 5) {
        // Every trip written before the mint carries the constant
        // 'local-trip', which `trips.id` — a `uuid` column — would refuse
        // the first time anything synced. Give it a real one now, while
        // there is still provably nothing to reconcile with: no Supabase
        // project exists, so no server has ever seen this trip's id.
        //
        // **This is the only time a trip's id changes, and it can only
        // happen before the id has ever left the phone.** After this an id
        // is the trip's for good: re-minting a synced trip would fork it
        // in two on the server and re-deal every remaining ping
        // (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md).
        final trip = await select(tripFacts).getSingleOrNull();
        if (trip != null && !TripId(trip.tripId).isCanonical) {
          await (update(tripFacts)..where((t) => t.id.equals(_theOneTrip)))
              .write(TripFactsCompanion(tripId: Value(mint().value)));
        }
      }
      if (from < 6) {
        // The itinerary becomes a shared stored fact
        // (docs/decisions/2026-08-22-grill-round-one.md §2), so every day
        // grows the clock the merge is decided on and the phone grows a
        // record of what it has told a server.
        await m.addColumn(itineraryDays, itineraryDays.revisedAtUtcIso);
        await m.createTable(syncStates);
        syncStatesBornCurrent = true;
        // A plan already on this phone is the newest plan in existence: no
        // Supabase project has ever been applied, so no server has seen any
        // of it. Stamping it *now* rather than leaving it at the epoch is
        // what stops the first sync of an upgraded phone reading as "I have
        // nothing to say" and losing the whole plan to an empty server.
        await customStatement(
          "update itinerary_days set revised_at_utc_iso = "
          "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
        );
        await customStatement(
          'insert into sync_states (id, plan_revised_at_utc_iso, '
          'pocket_revised_at_utc_iso) '
          "select 1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), "
          "strftime('%Y-%m-%dT%H:%M:%fZ', 'now') "
          'where exists (select 1 from itinerary_days)',
        );
      }
      if (from < 7) {
        // The paste box survives the process now (the import torture-test's
        // R6). Nothing carries over: a phone upgrading here has no pending
        // import, because before this table there was nowhere to put one.
        await m.createTable(planDrafts);
      }
      if (from < 8) {
        // The pool becomes shared: photographs grow an outbox
        // (bytes-first-row-second is the seam's rule; this table is where a
        // crash between the two is recoverable from), `file_path` loosens
        // for rows whose bytes are on another phone, `content_type` arrives
        // for the upload to sign, and `sync_states` takes the pull's cursor.
        //
        // `content_type` must land *before* the rebuild: `alterTable` copies
        // rows by selecting the new shape's columns from the old table, so a
        // rebuild against a table without the column fails mid-migration.
        // Then `alterTable` recreates `photos` in the current shape, which is
        // the only way SQLite loosens `file_path` to nullable. A `photos` or
        // `sync_states` born current in this same upgrade needs none of it.
        await m.createTable(photoOutbox);
        if (!photosBornCurrent) {
          await m.addColumn(photos, photos.contentType);
          await m.alterTable(TableMigration(photos));
        }
        if (!syncStatesBornCurrent) {
          await m.addColumn(syncStates, syncStates.photosUpdatedCursor);
        }
        // Deliberately no backfill of outbox rows: no build that could
        // capture a photo has ever shipped, so a photo already on a phone is
        // a developer's, and enqueueing it against a hosted project it never
        // agreed to reach would be a push nobody asked for.
      }
      if (from < 9) {
        // Area columns on stops + app preferences (tap-to-Maps phase 1).
        // No backfill possible: a plan saved before v9 has no raw text to
        // re-derive areas from, so its stops upgrade with area null (rule 3).
        await m.addColumn(itineraryStops, itineraryStops.kind);
        await m.addColumn(itineraryStops, itineraryStops.areaText);
        await m.addColumn(itineraryStops, itineraryStops.areaSource);
        await m.createTable(appPreferences);
      }
    },
  );

  /// The saved itinerary's days, in trip order. This is the stream the
  /// repository hangs its itinerary watch on: every write path here replaces
  /// all three tables in one transaction, so a change to stops or set-aside
  /// lines always arrives with a change to this table.
  Stream<List<ItineraryDay>> watchItineraryDays() => (select(
    itineraryDays,
  )..orderBy([(t) => OrderingTerm.asc(t.number)])).watch();

  Future<List<ItineraryStop>> readItineraryStops() =>
      (select(itineraryStops)..orderBy([
            (t) => OrderingTerm.asc(t.dayNumber),
            (t) => OrderingTerm.asc(t.position),
          ]))
          .get();

  Future<List<ItinerarySetAside>> readItinerarySetAsides() => (select(
    itinerarySetAsides,
  )..orderBy([(t) => OrderingTerm.asc(t.position)])).get();

  /// The days, read once instead of watched — what the sync hands over, and
  /// what a caller inside a faked clock (a widget test) must use: awaiting a
  /// drift stream's first event there never completes.
  Future<List<ItineraryDay>> readItineraryDays() => (select(
    itineraryDays,
  )..orderBy([(t) => OrderingTerm.asc(t.number)])).get();

  /// Replaces the stored itinerary wholesale, atomically, **and stamps the
  /// merge clocks** for whatever actually changed.
  ///
  /// "Replace" is still how a save is spelled — the confirm screen hands over
  /// the whole plan and always did — but the itinerary is a shared fact now
  /// (`supabase/migrations/0010_trip_itinerary.sql`), so a wholesale replace
  /// that stamped every day would have this phone claim authorship of days it
  /// merely still held, and clobber everyone else's edits on the next push.
  /// So each day is compared with what is stored and only a day whose content
  /// differs takes [nowUtcIso]; the rest keep the instant they came in with.
  ///
  /// The plan's *shape* revision moves only when the set of day numbers moves,
  /// and the pocket's only when the pocket's contents do, for the same reason.
  ///
  /// Takes plain records rather than Drift companions so the repository
  /// above needs no Drift import — the seam may only know this band's
  /// surface, not its library (`lib/README.md`).
  Future<void> replaceItinerary({
    required List<ItineraryDayRecord> days,
    required List<ItineraryStopRecord> stops,
    required List<ItinerarySetAsideRecord> setAsides,
    required String nowUtcIso,
  }) {
    return transaction(() async {
      final storedDays = await readItineraryDays();
      final storedStops = await readItineraryStops();
      final storedAsides = await readItinerarySetAsides();
      final storedSync = await _syncStateRow();

      final storedRevisions = {
        for (final day in storedDays) day.number: day.revisedAtUtcIso,
      };
      final storedSignatures = {
        for (final day in storedDays)
          day.number: _daySignature(
            dateIso: day.dateIso,
            place: day.place,
            stops: [
              for (final stop in storedStops)
                if (stop.dayNumber == day.number)
                  (
                    stop.position,
                    stop.stopText,
                    stop.timeIso,
                    stop.areaText,
                    stop.areaSource,
                  ),
            ],
          ),
      };

      final revisions = <int, String>{};
      for (final day in days) {
        final signature = _daySignature(
          dateIso: day.dateIso,
          place: day.place,
          stops: [
            for (final stop in stops)
              if (stop.dayNumber == day.number)
                (stop.position, stop.text, stop.timeIso, stop.areaText, stop.areaSource),
          ],
        );
        final unchanged = storedSignatures[day.number] == signature;
        revisions[day.number] = unchanged
            ? storedRevisions[day.number] ?? nowUtcIso
            : nowUtcIso;
      }

      final shapeMoved =
          storedRevisions.keys.toSet().length != revisions.length ||
          !storedRevisions.keys.every(revisions.containsKey);
      final pocketMoved =
          _pocketSignature([
            for (final line in storedAsides)
              (
                line.position,
                line.sourceLineNumber,
                line.lineText,
                line.explanation,
              ),
          ]) !=
          _pocketSignature([
            for (final line in setAsides)
              (
                line.position,
                line.sourceLineNumber,
                line.text,
                line.explanation,
              ),
          ]);

      await _writeItinerary(
        days: [
          for (final day in days)
            (
              number: day.number,
              dateIso: day.dateIso,
              place: day.place,
              revisedAtUtcIso: revisions[day.number] ?? nowUtcIso,
            ),
        ],
        stops: stops,
        setAsides: setAsides,
      );
      await _writeSyncState(
        SyncStatesCompanion(
          planRevisedAtUtcIso: Value(
            shapeMoved ? nowUtcIso : storedSync.planRevisedAtUtcIso,
          ),
          pocketRevisedAtUtcIso: Value(
            pocketMoved ? nowUtcIso : storedSync.pocketRevisedAtUtcIso,
          ),
        ),
      );
    });
  }

  /// Writes the itinerary the *server* handed back, carrying its revisions
  /// rather than stamping new ones.
  ///
  /// The counterpart of [replaceItinerary] and deliberately a second method:
  /// a local save decides what changed and stamps it, while an applied merge
  /// has already been decided — re-stamping it here would make every pull
  /// look like a local edit and start a push storm between two phones.
  Future<void> applyRemoteItinerary({
    required List<SyncedDayRecord> days,
    required List<ItineraryStopRecord> stops,
    required List<ItinerarySetAsideRecord> setAsides,
    required String planRevisedAtUtcIso,
    required String pocketRevisedAtUtcIso,
    required String syncedAtUtcIso,
  }) {
    return transaction(() async {
      await _writeItinerary(days: days, stops: stops, setAsides: setAsides);
      await _writeSyncState(
        SyncStatesCompanion(
          planRevisedAtUtcIso: Value(planRevisedAtUtcIso),
          pocketRevisedAtUtcIso: Value(pocketRevisedAtUtcIso),
          itinerarySyncedAtUtcIso: Value(syncedAtUtcIso),
        ),
      );
    });
  }

  Future<void> _writeItinerary({
    required List<SyncedDayRecord> days,
    required List<ItineraryStopRecord> stops,
    required List<ItinerarySetAsideRecord> setAsides,
  }) async {
    await delete(itineraryStops).go();
    await delete(itinerarySetAsides).go();
    await delete(itineraryDays).go();
    await batch((b) {
      b.insertAll(itineraryDays, [
        for (final day in days)
          ItineraryDaysCompanion.insert(
            number: Value(day.number),
            dateIso: Value(day.dateIso),
            place: Value(day.place),
            revisedAtUtcIso: Value(day.revisedAtUtcIso),
          ),
      ]);
      b.insertAll(itineraryStops, [
        for (final stop in stops)
          ItineraryStopsCompanion.insert(
            dayNumber: stop.dayNumber,
            position: stop.position,
            stopText: stop.text,
            timeIso: Value(stop.timeIso),
            kind: stop.kind == null ? const Value.absent() : Value(stop.kind!),
            areaText: Value(stop.areaText),
            areaSource: Value(stop.areaSource),
          ),
      ]);
      b.insertAll(itinerarySetAsides, [
        for (final line in setAsides)
          ItinerarySetAsidesCompanion.insert(
            position: line.position,
            sourceLineNumber: line.sourceLineNumber,
            lineText: line.text,
            explanation: line.explanation,
          ),
      ]);
    });
  }

  /// Everything about a day that two phones could disagree over. Ordering is
  /// part of it: dragging a stop up a day changes nothing else about it.
  static String _daySignature({
    required String? dateIso,
    required String? place,
    required List<(int, String, String?, String?, String?)> stops,
  }) {
    final ordered = [...stops]..sort((a, b) => a.$1.compareTo(b.$1));
    return [
      dateIso ?? '',
      place ?? '',
      for (final (position, text, timeIso, areaText, areaSource) in ordered)
        '$position\u0000$text\u0000${timeIso ?? ''}\u0000${areaText ?? ''}\u0000${areaSource ?? ''}',
    ].join('\u0001');
  }

  static String _pocketSignature(List<(int, int, String, String)> lines) {
    final ordered = [...lines]..sort((a, b) => a.$1.compareTo(b.$1));
    return [
      for (final (position, source, text, explanation) in ordered)
        '$position\u0000$source\u0000$text\u0000$explanation',
    ].join('\u0001');
  }

  // ------------------------------------------------------------ sync state

  /// What this phone has told a server, and heard back. Never null: the row
  /// is created on first read, so no caller has to hold "there is no state
  /// yet" as a separate case from "nothing has synced yet".
  Future<SyncState> readSyncState() => _syncStateRow();

  Future<SyncState> _syncStateRow() async {
    final existing = await (select(
      syncStates,
    )..where((t) => t.id.equals(_theOneTrip))).getSingleOrNull();
    if (existing != null) return existing;
    await into(syncStates)
        .insert(SyncStatesCompanion.insert(id: const Value(_theOneTrip)));
    return (select(
      syncStates,
    )..where((t) => t.id.equals(_theOneTrip))).getSingle();
  }

  /// Records what the last reconcile achieved. Only the fields named are
  /// written, so a roster that synced while the itinerary did not leaves the
  /// itinerary's cursor alone.
  Future<void> markSynced({
    String? tripRowSyncedAtUtcIso,
    String? itinerarySyncedAtUtcIso,
    String? rosterSyncedAtUtcIso,
  }) async {
    await _syncStateRow();
    await _writeSyncState(
      SyncStatesCompanion(
        tripRowSyncedAtUtcIso: tripRowSyncedAtUtcIso == null
            ? const Value.absent()
            : Value(tripRowSyncedAtUtcIso),
        itinerarySyncedAtUtcIso: itinerarySyncedAtUtcIso == null
            ? const Value.absent()
            : Value(itinerarySyncedAtUtcIso),
        rosterSyncedAtUtcIso: rosterSyncedAtUtcIso == null
            ? const Value.absent()
            : Value(rosterSyncedAtUtcIso),
      ),
    );
  }

  Future<void> _writeSyncState(SyncStatesCompanion companion) async {
    await _syncStateRow();
    await (update(
      syncStates,
    )..where((t) => t.id.equals(_theOneTrip))).write(companion);
  }

  /// Every photo on this phone, oldest first.
  ///
  /// Time order, not insertion order: the day is a timeline (design-calls
  /// §1) and the pool is that timeline widened to the trip, so the store
  /// hands them over already in the order every surface reads them in. A
  /// late photo therefore lands at its true hour rather than at the end
  /// (design-calls §7).
  Stream<List<Photo>> watchPhotos() =>
      (select(photos)..orderBy([
            (t) => OrderingTerm.asc(t.takenAtUtcIso),
            // Two photos on the same instant still need one stable order.
            (t) => OrderingTerm.asc(t.id),
          ]))
          .watch();

  /// The same list, read once instead of watched. The pool's surfaces want
  /// the stream; a caller that only needs today's answer wants this.
  Future<List<Photo>> readPhotos() =>
      (select(photos)..orderBy([
            (t) => OrderingTerm.asc(t.takenAtUtcIso),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .get();

  /// Appends one photo. Photos accumulate; nothing here replaces a pool the
  /// way [replaceItinerary] replaces the plan.
  Future<void> insertPhoto(PhotoRecord photo) => into(photos).insert(
    PhotosCompanion.insert(
      id: photo.id,
      dayNumber: photo.dayNumber,
      contributorId: photo.contributorId,
      takenAtUtcIso: photo.takenAtUtcIso,
      origin: photo.origin,
      word: Value(photo.word),
      filePath: Value(photo.filePath),
      contentType: Value(photo.contentType),
    ),
  );

  /// Rewrites one photo's word, or clears it.
  ///
  /// The word stays writable on your own print until the trip closes
  /// (design round 10, `18c`), so this is an ordinary update rather than a
  /// write-once. Whose print may be written on is decided above this band.
  Future<int> updatePhotoWord({required String id, required String? word}) =>
      (update(photos)..where((t) => t.id.equals(id))).write(
        PhotosCompanion(word: Value(word)),
      );

  // ------------------------------------------------------------- the outbox

  /// Keeps one photo *and* the debt to push it, atomically.
  ///
  /// One transaction on purpose, and the whole point: a crash between the
  /// two inserts would leave a photograph that silently never leaves this
  /// phone, and no ordering of two separate writes closes that. The outbox
  /// row is due immediately — capture wants to cross while the wifi it was
  /// taken on is still in range.
  Future<void> insertPhotoWithOutbox(
    PhotoRecord photo, {
    required String nowUtcIso,
  }) {
    return transaction(() async {
      await insertPhoto(photo);
      await into(photoOutbox).insert(
        PhotoOutboxCompanion.insert(
          photoId: photo.id,
          state: 'queued',
          nextAttemptAtUtcIso: nowUtcIso,
        ),
      );
    });
  }

  /// Rewrites one photo's word and, when the photo has already crossed,
  /// files the debt to say so — in one transaction, so the word and the debt
  /// cannot disagree.
  ///
  /// "Already crossed" is exactly "no outbox row": a photo still `queued` or
  /// `uploaded` needs nothing, because the record insert reads the word at
  /// record time; a pending `caption` row already promises to push whatever
  /// the word is by then, so a second edit rides the same row; and a photo
  /// terminally `refused` stays refused — a caption on a photograph that
  /// never crossed has nothing to ride.
  Future<void> updatePhotoWordAndQueueCaption({
    required String id,
    required String? word,
    required String nowUtcIso,
  }) {
    return transaction(() async {
      final changed = await updatePhotoWord(id: id, word: word);
      if (changed == 0) return;
      final pending = await (select(
        photoOutbox,
      )..where((t) => t.photoId.equals(id))).getSingleOrNull();
      if (pending != null) return;
      await into(photoOutbox).insert(
        PhotoOutboxCompanion.insert(
          photoId: id,
          state: 'caption',
          nextAttemptAtUtcIso: nowUtcIso,
        ),
      );
    });
  }

  /// Every push still owed, each with the photo it is about, oldest
  /// photograph first — the order the pool reads in, so the pool fills in
  /// the order it will be looked at. Terminally refused rows are not work
  /// and are not returned; read them with [readOutboxRows] when a test or a
  /// later surface asks what silently never crossed.
  Future<List<OutboxItem>> readOutboxWork() async {
    final rows =
        await (select(photoOutbox).join([
                innerJoin(photos, photos.id.equalsExp(photoOutbox.photoId)),
              ])
              ..where(photoOutbox.state.equals('refused').not())
              ..orderBy([
                OrderingTerm.asc(photos.takenAtUtcIso),
                OrderingTerm.asc(photos.id),
              ]))
            .get();
    return [
      for (final row in rows)
        (outbox: row.readTable(photoOutbox), photo: row.readTable(photos)),
    ];
  }

  /// The whole outbox, refused rows included, read once.
  Future<List<PhotoOutboxData>> readOutboxRows() => select(photoOutbox).get();

  /// Fires whenever the outbox changes — the driver's trigger. Deliberately
  /// a watch on this table alone and never on [photos]: the pull half will
  /// write photo rows, and a driver that watched them would re-trigger
  /// itself on every pull it applied.
  Stream<List<PhotoOutboxData>> watchOutbox() => select(photoOutbox).watch();

  /// Records that a PUT returned 200: [byteSize] bytes are durably at
  /// [r2ObjectKey], and no attempt after this ever mints a ticket again.
  Future<void> markOutboxUploaded({
    required String photoId,
    required String r2ObjectKey,
    required int byteSize,
  }) => (update(photoOutbox)..where((t) => t.photoId.equals(photoId))).write(
    PhotoOutboxCompanion(
      state: const Value('uploaded'),
      r2ObjectKey: Value(r2ObjectKey),
      uploadedByteSize: Value(byteSize),
      lastError: const Value(null),
    ),
  );

  /// Settles a push that just landed — the record insert or the caption
  /// PATCH — carrying [sentWord], the word the push actually said.
  ///
  /// The row is deleted (terminal success) *unless* the word changed while
  /// the push was in flight, in which case the row becomes a `caption` debt
  /// instead: deleting it would strand an edit the enqueue path already saw
  /// a pending row for. One transaction, so the comparison and the
  /// settlement cannot straddle an edit.
  Future<void> settleOutboxPushed({
    required String photoId,
    required String? sentWord,
    required String nowUtcIso,
  }) {
    return transaction(() async {
      final photo = await (select(
        photos,
      )..where((t) => t.id.equals(photoId))).getSingleOrNull();
      if (photo != null && photo.word != sentWord) {
        await (update(
          photoOutbox,
        )..where((t) => t.photoId.equals(photoId))).write(
          PhotoOutboxCompanion(
            state: const Value('caption'),
            nextAttemptAtUtcIso: Value(nowUtcIso),
            lastError: const Value(null),
          ),
        );
        return;
      }
      await (delete(photoOutbox)..where((t) => t.photoId.equals(photoId))).go();
    });
  }

  /// Files one failed attempt: back to `queued`, the ticket forgotten, the
  /// next try pushed out to [nextAttemptAtUtcIso].
  Future<void> delayOutboxRetry({
    required String photoId,
    required int attempts,
    required String nextAttemptAtUtcIso,
    required String lastError,
  }) => (update(photoOutbox)..where((t) => t.photoId.equals(photoId))).write(
    PhotoOutboxCompanion(
      state: const Value('queued'),
      attempts: Value(attempts),
      nextAttemptAtUtcIso: Value(nextAttemptAtUtcIso),
      lastError: Value(lastError),
    ),
  );

  /// The server ruled, so the push is over. Kept rather than deleted:
  /// "record only real state" cuts both ways, and a photograph that silently
  /// never crossed should at least be queryable.
  Future<void> markOutboxRefused({
    required String photoId,
    required String lastError,
  }) => (update(photoOutbox)..where((t) => t.photoId.equals(photoId))).write(
    PhotoOutboxCompanion(
      state: const Value('refused'),
      lastError: Value(lastError),
    ),
  );
  // -------------------------------------------------------------- the trip

  /// The trip's own facts, or null while this phone has not started one.
  ///
  /// The roster and the codes hang off this stream, so it is driven by all
  /// three of the trip's tables and not by `trip_facts` alone. The itinerary
  /// can play the simpler trick (`watchItineraryDays`) because every write
  /// there rewrites the very table being watched; minting a code changes no
  /// fact about the trip, and a stream watching only the facts would leave a
  /// rotated code sitting on screen. The query selects the state that
  /// actually moves so that no layer of stream de-duplication can swallow
  /// the change.
  Stream<TripFact?> watchTripFacts() => customSelect(
    'select (select count(*) from trip_facts) as started, '
    "(select coalesce(name, '') from trip_facts) as name, "
    '(select count(*) from trip_members) as members, '
    '(select count(*) from trip_invite_codes) as codes, '
    '(select count(*) from trip_invite_codes '
    'where revoked_at_utc_iso is not null) as revoked',
    readsFrom: {tripFacts, tripMembers, tripInviteCodes},
  ).watch().asyncMap((_) => select(tripFacts).getSingleOrNull());

  /// The same facts, read once instead of watched — the trip's counterpart of
  /// [readPhotos], and what a caller wanting one answer should take.
  Future<TripFact?> readTripFacts() => select(tripFacts).getSingleOrNull();

  Future<List<TripMember>> readTripMembers() =>
      (select(tripMembers)..orderBy([
            (t) => OrderingTerm.asc(t.joinedOnDay),
            // One stable order for a party that must agree with every other
            // phone's: `trip_moments` sorts the ids again anyway, and this is
            // the same sort, so the roster reads the same everywhere.
            (t) => OrderingTerm.asc(t.id),
          ]))
          .get();

  Future<List<TripInviteCode>> readTripInviteCodes() => (select(
    tripInviteCodes,
  )..orderBy([(t) => OrderingTerm.asc(t.mintedAtUtcIso)])).get();

  /// Writes the trip and the person who started it, if there is not one, and
  /// hands back the trip's id either way.
  ///
  /// **The id is minted here**, in the same transaction that decides there is
  /// no trip yet, because those two facts must not be able to disagree: an id
  /// minted outside the transaction could be minted twice, and an id minted
  /// after it would be an id the trip briefly did not have. This is exactly
  /// the job `trips.id`'s `default gen_random_uuid()` does on the server, and
  /// moving it to the phone is the whole of
  /// docs/decisions/2026-08-25-the-trip-mints-its-own-id.md.
  ///
  /// Idempotent, because accepting a plan is what starts a trip and a plan
  /// can be accepted again (pasting a different one replaces the itinerary,
  /// and replacing your own itinerary is not starting a second trip). A
  /// second call draws bytes it then throws away and returns the id the trip
  /// already has — the row is the mint's record, not the draw.
  Future<TripId> startTripIfAbsent({
    required String starterId,
    required String starterDisplayName,
  }) {
    return transaction(() async {
      final existing = await select(tripFacts).getSingleOrNull();
      if (existing != null) return TripId(existing.tripId);
      final tripId = mint();
      await into(tripFacts).insert(
        TripFactsCompanion.insert(
          id: const Value(_theOneTrip),
          tripId: tripId.value,
          startedByMemberId: starterId,
        ),
      );
      await into(tripMembers).insert(
        TripMembersCompanion.insert(
          id: starterId,
          displayName: starterDisplayName,
        ),
        mode: InsertMode.insertOrIgnore,
      );
      return tripId;
    });
  }

  /// Writes the roster the server handed over, replacing this phone's copy.
  ///
  /// Wholesale, and safely so: the server only answers a member, so the
  /// roster it returns necessarily contains whoever asked
  /// (`is_trip_member` gates every read of it). A merge that tried to
  /// preserve a local row the server did not name would resurrect somebody
  /// who had left — and a party with a ghost in it deals a ping to nobody
  /// (`packages/trip_moments`: the party is an input).
  ///
  /// [startedByMemberId] rides along because it moves for the same reason and
  /// at the same moment: on the server the starter is `trips.created_by`, and
  /// a roster of account ids beside a starter who is still this phone's local
  /// stand-in would leave `removalPowerHolder` answering about a person who
  /// is not on the list.
  Future<void> replaceRoster({
    required List<TripMemberRecord> members,
    String? startedByMemberId,
    String? name,
  }) {
    return transaction(() async {
      await delete(tripMembers).go();
      await batch((b) {
        b.insertAll(tripMembers, [
          for (final member in members)
            TripMembersCompanion.insert(
              id: member.id,
              displayName: member.displayName,
              joinedOnDay: Value(member.joinedOnDay),
            ),
        ]);
      });
      if (startedByMemberId != null || name != null) {
        await (update(tripFacts)..where((t) => t.id.equals(_theOneTrip))).write(
          TripFactsCompanion(
            startedByMemberId: startedByMemberId == null
                ? const Value.absent()
                : Value(startedByMemberId),
            name: name == null ? const Value.absent() : Value(name),
          ),
        );
      }
    });
  }

  /// Renames the trip, or clears the name with null.
  Future<int> renameTrip(String? name) =>
      (update(tripFacts)..where((t) => t.id.equals(_theOneTrip))).write(
        TripFactsCompanion(name: Value(name)),
      );

  /// Records one minted code.
  Future<int> insertInviteCode(InviteCodeRecord invite) =>
      into(tripInviteCodes).insert(
        TripInviteCodesCompanion.insert(
          code: invite.code,
          mintedByMemberId: invite.mintedByMemberId,
          mintedAtUtcIso: invite.mintedAtUtcIso,
        ),
      );

  /// Shuts one code. Rotating is minting a new one and revoking the old;
  /// nothing here ever repoints a code at a different trip.
  Future<int> revokeInviteCode({
    required String code,
    required String atUtcIso,
  }) => (update(tripInviteCodes)..where((t) => t.code.equals(code))).write(
    TripInviteCodesCompanion(revokedAtUtcIso: Value(atUtcIso)),
  );

  // -- the paste box's pending import ---------------------------------------

  /// The pending import, or null when there is none.
  Future<String?> readPlanDraft() async {
    final row = await (select(
      planDrafts,
    )..where((t) => t.id.equals(_theOneDraft))).getSingleOrNull();
    return row?.planText;
  }

  /// Starts (or replaces) the pending import. The only caller is an import
  /// that landed: nothing else creates a draft, which is what keeps the
  /// example plan and a hand-typed one out of this table.
  Future<void> writePlanDraft(String text) => into(planDrafts)
      .insertOnConflictUpdate(
        PlanDraftsCompanion.insert(
          id: const Value(_theOneDraft),
          planText: text,
        ),
      );

  /// Keeps an existing draft in step with the box, and creates nothing.
  ///
  /// The distinction from [writePlanDraft] is the whole rule: while a draft
  /// stands it tracks what is on screen, so a restored draft can never be
  /// older than what the person last had in front of them — but a box that
  /// never held an import is not a draft and does not become one by being
  /// typed in.
  Future<void> updatePlanDraftIfPresent(String text) =>
      (update(planDrafts)..where((t) => t.id.equals(_theOneDraft))).write(
        PlanDraftsCompanion(planText: Value(text)),
      );

  /// Forgets the pending import: accepted, emptied, or gone with its trip.
  Future<void> clearPlanDraft() =>
      (delete(planDrafts)..where((t) => t.id.equals(_theOneDraft))).go();

  // ---------------------------------------------------------- device prefs

  Future<String?> readMapsApp() async {
    final row = await (select(
      appPreferences,
    )..where((t) => t.id.equals(_theOneTrip))).getSingleOrNull();
    return row?.mapsApp;
  }

  Future<void> writeMapsApp(String? app) async {
    await into(appPreferences).insertOnConflictUpdate(
      AppPreferencesCompanion.insert(id: const Value(_theOneTrip), mapsApp: Value(app)),
    );
  }

  Future<void> setStopAreas({
    required int dayNumber,
    required List<int> positions,
    String? area,
    String? areaSource,
    required String nowUtcIso,
  }) {
    return transaction(() async {
      for (final pos in positions) {
        await (update(itineraryStops)
              ..where((t) => t.dayNumber.equals(dayNumber) & t.position.equals(pos)))
            .write(ItineraryStopsCompanion(areaText: Value(area), areaSource: Value(areaSource)));
      }
      // stamp day clock if any change
      final day = await (select(itineraryDays)..where((t) => t.number.equals(dayNumber))).getSingleOrNull();
      if (day != null) {
        await (update(itineraryDays)..where((t) => t.number.equals(dayNumber)))
            .write(ItineraryDaysCompanion(revisedAtUtcIso: Value(nowUtcIso)));
      }
      final sync = await _syncStateRow();
      // shape unchanged — don't move plan clock
      await _writeSyncState(SyncStatesCompanion(planRevisedAtUtcIso: Value(sync.planRevisedAtUtcIso)));
    });
  }

  /// Deletes the whole trip from this phone: the plan, the pool's rows, the
  /// roster, the codes and the trip itself.
  ///
  /// **The photographs themselves are not this method's to delete.** A photo
  /// row is an index and the frame is a file beside it; nothing in the app
  /// reconciles the two in either direction yet (`docs/roadmap.md`, "Things
  /// that will bite"), and deleting files is not something to do for the
  /// first time inside a transaction.
  Future<void> deleteTripWholesale() {
    return transaction(() async {
      await delete(itineraryStops).go();
      await delete(itinerarySetAsides).go();
      await delete(itineraryDays).go();
      // The debt to push a photo dies with the trip it was owed to.
      await delete(photoOutbox).go();
      await delete(photos).go();
      await delete(tripInviteCodes).go();
      await delete(tripMembers).go();
      await delete(tripFacts).go();
      // The cursors go with the trip they were cursors into. Leaving them
      // would tell the next trip's first sync that it had already said
      // things it never said.
      await delete(syncStates).go();
      // A pending import belongs to the box the deleted trip came out of.
      await delete(planDrafts).go();
    });
  }
}

/// The one trip's row key. See [TripFacts].
const _theOneTrip = 1;

/// The one row of [PlanDrafts]: a phone has one paste box.
const _theOneDraft = 1;

/// The write-side shape [AppDatabase.insertInviteCode] accepts.
typedef InviteCodeRecord = ({
  String code,
  String mintedByMemberId,
  String mintedAtUtcIso,
});

/// The write-side shape [AppDatabase.insertPhoto] accepts.
///
/// [filePath] and [contentType] are nullable because the *schema* is — a
/// pulled row's bytes are elsewhere — but everything this phone captures
/// fills both.
typedef PhotoRecord = ({
  String id,
  int dayNumber,
  String contributorId,
  String takenAtUtcIso,
  String origin,
  String? word,
  String? filePath,
  String? contentType,
});

/// One pending push and the photograph it is about, as
/// [AppDatabase.readOutboxWork] hands them over together.
typedef OutboxItem = ({PhotoOutboxData outbox, Photo photo});

/// The write-side shape [AppDatabase.replaceRoster] accepts.
typedef TripMemberRecord = ({String id, String displayName, int joinedOnDay});

/// The write-side shapes [AppDatabase.replaceItinerary] accepts.
typedef ItineraryDayRecord = ({int number, String? dateIso, String? place});

/// The same day, carrying the merge clock it arrived with. Only the sync
/// speaks this shape: a local save hands over [ItineraryDayRecord] and lets
/// the store decide which days it is entitled to stamp.
typedef SyncedDayRecord = ({
  int number,
  String? dateIso,
  String? place,
  String revisedAtUtcIso,
});
typedef ItineraryStopRecord = ({
  int dayNumber,
  int position,
  String text,
  String? timeIso,
  String? kind,
  String? areaText,
  String? areaSource,
});
typedef ItinerarySetAsideRecord = ({
  int position,
  int sourceLineNumber,
  String text,
  String explanation,
});

/// Mints one trip id, here on the phone and with nothing to ask.
///
/// **The counterpart of `trips.id`'s `default gen_random_uuid()`**, moved to
/// the phone so a trip can be started with no connection
/// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md). It lives beside
/// the store that writes the row for the same reason the server's default
/// lives on the column: an id is minted exactly where it becomes durable, and
/// nothing above this band gets to hold an id that no row remembers.
///
/// `cairn_model` owns the *shape* and refuses to invent the randomness — the
/// same division `InviteCode.draw` makes — so the draw is here and the
/// formatting is `TripId.mint`. [Random.secure] rather than [Random] because
/// two phones must never mint the same trip: 122 random bits make a collision
/// vanishingly unlikely, and a predictable generator would throw that away.
TripId mintTripId() {
  final random = Random.secure();
  return TripId.mint([for (var i = 0; i < 16; i++) random.nextInt(256)]);
}

/// Opens the on-device database. Native SQLite arrives through
/// `package:sqlite3` 3.x's build hooks (the successor to the end-of-life
/// `sqlite3_flutter_libs`); there is no web target and no wasm detour here —
/// that was the learning demo's compromise, not the app's.
AppDatabase openAppDatabase() => AppDatabase(driftDatabase(name: 'cairn'));
