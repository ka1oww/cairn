// THE SEAM (docs/architecture.md): the only layer that knows storage backends
// exist — and this file is the one place that knows *both* of them at once.
// "Everything awkward about being offline-first lives here, deliberately, so
// it lives nowhere else" is the map's own line about this band, and a sync
// loop is the most awkward thing there is.
//
// Nothing above this file changes because of it. No provider, no screen and
// no feature imports anything here: the app's surfaces read the Drift store
// through the repositories they always read, and this class quietly makes
// that store agree with seven other phones.
//
// ---------------------------------------------------------------------------
// THE MERGE RULE, and where its other copy lives
// ---------------------------------------------------------------------------
//
// **Last write wins, per day.** The day is the atom: a day's date, its place
// and its whole list of stops move together, because a person reorders and
// retimes a day as one act and merging inside it would produce a day nobody
// wrote. Two people editing two different days both keep their work; two
// people editing the *same* day, the later clock wins whole.
//
// The rule is written in exactly two places, like the gate and the invite
// grammar: here, and in `sync_trip_itinerary`
// (`supabase/migrations/0010_trip_itinerary.sql`). It has to be both, because
// the server must refuse a stale push it is *told* about, and the phone must
// know which of its own days survived the push it just made. Neither copy is
// redundant and a third one would be the thing to refuse in review.
//
// The cost is the writing phone's clock, and it is a real cost: a phone whose
// clock is an hour fast wins edits it should lose. That is the price of
// last-write-wins and the captain accepted it for this slice — no CRDTs, no
// conflict UI.
//
// **Deletion is why the plan carries a shape revision.** A day that was
// removed leaves no row to carry an instant, so "I dropped day 4" and "I have
// never heard of day 4" look identical in a push. `SyncStates.planRevisedAt`
// is the phone's answer: it moves when the *set* of day numbers moves, and
// the server deletes only days at or below it. A phone six days behind cannot
// silently delete a day somebody added yesterday.
import 'dart:async';

import 'package:cairn_model/cairn_model.dart';

import '../storage/drift/app_database.dart';
import '../storage/remote/shared_facts.dart';

/// Where a reconcile got to. Every value is an ordinary answer; none is an
/// error a person should ever be shown.
enum SyncStanding {
  /// No backend is configured, or nobody is signed in. The app's whole life
  /// so far (`supabase/README.md`: no project exists yet, and Sign in with
  /// Apple is not built), and the reason this class is inert by default
  /// rather than noisy.
  dormant,

  /// This phone has not started a trip, so there is nothing shared to be.
  noTrip,

  /// The trip has never reached a server and the phone cannot yet say what
  /// its clock is, so the shared row cannot be created.
  ///
  /// A real gap, named rather than papered over: `trips` requires an IANA
  /// zone and a start and end date, and this slice of the app holds a device
  /// UTC offset and a plan whose dates may all still be open. Deriving
  /// `Etc/GMT-8` from an offset would be a lie the first time somebody
  /// crossed a border, and inventing dates would be worse. The blank closes
  /// when sign-in asks for country and city (`supabase/README.md`).
  awaitingTripRow,

  /// The server could not be reached. **The local copy is untouched and
  /// authoritative**, which is the whole offline story: a person on a train
  /// sees their plan, edits it, and the edit is pushed when they surface.
  offline,

  /// The server understood and said no — not a member, or a row that already
  /// exists. Retrying changes nothing, so nothing here does.
  refused,

  /// The plan and the roster now agree with the server's.
  synced,
}

/// What one reconcile did.
class SyncOutcome {
  final SyncStanding standing;

  /// How many days the shared plan holds after the merge.
  final int days;

  /// How many people the roster holds after it.
  final int members;

  /// Why, when the standing is not [SyncStanding.synced]. Never shown to a
  /// person; it exists so a log or a test can say what happened.
  final String? detail;

  const SyncOutcome(
    this.standing, {
    this.days = 0,
    this.members = 0,
    this.detail,
  });

  bool get didReach => standing == SyncStanding.synced;
}

/// What the shared `trips` row needs and this phone does not have.
///
/// Handed to a [TripRowSource] so that whatever eventually knows the trip's
/// country and city can answer without this file learning about sign-in.
class PendingTripRow {
  final TripId tripId;
  final String? name;
  final MemberId startedBy;

  /// The plan's first and last *resolved* dates, or null when every day's
  /// date is still open. A source is free to answer anyway, or to decline.
  final String? firstDateIso;
  final String? lastDateIso;

  const PendingTripRow({
    required this.tripId,
    this.name,
    required this.startedBy,
    this.firstDateIso,
    this.lastDateIso,
  });
}

/// Answers with the shared row to create, or null to say "not yet".
///
/// Null is the app's answer today, and [SyncStanding.awaitingTripRow] is what
/// the sync reports when it hears it.
typedef TripRowSource = Future<RemoteTripDraft?> Function(PendingTripRow);

/// Keeps this phone's copy of the trip's *shared facts* — the itinerary and
/// the roster — in step with the server's.
///
/// Only shared facts move. The trail's geometry, the stars, the gate and the
/// ping schedule are computed here from what lands, and never fetched
/// (AGENTS.md; `docs/decisions/2026-08-22-grill-round-one.md` §2).
class TripSync {
  TripSync({
    required this.database,
    required this.facts,
    this.now = DateTime.now,
    this.tripRow,
  });

  final AppDatabase database;
  final SharedFacts facts;

  /// This phone's reading of now — the instant a successful reconcile is
  /// stamped with. Never the merge clock: a *day's* clock is stamped where
  /// the day is written ([AppDatabase.replaceItinerary]).
  final DateTime Function() now;

  /// Who can say what the trip's clock is, or null while nothing can.
  final TripRowSource? tripRow;

  final _subscriptions = <StreamSubscription<void>>[];
  Timer? _poll;
  Future<SyncOutcome>? _inFlight;
  Future<SyncOutcome>? _queued;
  var _started = false;

  /// Starts reconciling: once now, again whenever anything local changes, and
  /// every [pollEvery] if one is given.
  ///
  /// The poll is what makes a *remote* change arrive at all. Supabase
  /// Realtime would be the other answer and is deliberately not used: it
  /// holds a websocket open for the whole trip, which is the one thing a
  /// phone in a foreign country on a battery cannot afford, and the shared
  /// facts change a handful of times a day.
  ///
  /// Defaults to no poll so that nothing which merely constructs the app
  /// leaves a timer running — a pending timer is how a widget test hangs.
  void start({Duration? pollEvery}) {
    if (_started) return;
    _started = true;
    _subscriptions.add(database.watchItineraryDays().listen((_) => syncSoon()));
    _subscriptions.add(database.watchTripFacts().listen((_) => syncSoon()));
    if (pollEvery != null) _poll = Timer.periodic(pollEvery, (_) => syncSoon());
  }

  /// Stops listening and waits for whatever is already running.
  ///
  /// The wait matters: a reconcile writes to Drift, and a database closed out
  /// from under one fails in a way that looks like a bug in the sync.
  Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _started = false;
    await _queued?.catchError((_) => const SyncOutcome(SyncStanding.dormant));
    await _inFlight?.catchError((_) => const SyncOutcome(SyncStanding.dormant));
  }

  /// Asks for a reconcile without waiting for it.
  ///
  /// A save writes three tables in one transaction and the streams fire more
  /// than once for it; a sync per emission would push the same plan three
  /// times and race itself.
  void syncSoon() => unawaited(syncNow());

  /// One reconcile, start to finish.
  ///
  /// Serialized, and **collapsed**: while one is running, every further call
  /// joins a single queued follow-up rather than starting one apiece. A burst
  /// of local writes therefore costs at most two round trips — the one in
  /// flight, which may have read the store before the last write landed, and
  /// one more that is guaranteed to have seen everything.
  Future<SyncOutcome> syncNow() {
    if (_inFlight == null) return _run();
    return _queued ??= _inFlight!.then<void>((_) {}, onError: (_) {}).then((_) {
      _queued = null;
      return _run();
    });
  }

  Future<SyncOutcome> _run() {
    final started = _reconcile().whenComplete(() => _inFlight = null);
    _inFlight = started;
    return started;
  }

  Future<SyncOutcome> _reconcile() async {
    final SharedFactsSession? auth;
    try {
      auth = await facts.session();
    } on SharedFactsUnavailable catch (e) {
      return SyncOutcome(SyncStanding.dormant, detail: e.reason);
    }
    if (auth == null) {
      return const SyncOutcome(SyncStanding.dormant, detail: 'no session');
    }

    final trip = await database.readTripFacts();
    if (trip == null) {
      return const SyncOutcome(SyncStanding.noTrip);
    }
    final tripId = TripId(trip.tripId);

    try {
      final shared = await facts.readTrip(tripId);
      if (shared == null) {
        final made = await _createSharedTrip(trip, tripId);
        if (made != null) return made;
      } else {
        await _applyRoster(shared, trip);
      }
      return await _reconcileItinerary(tripId, shared);
    } on SharedFactsUnavailable catch (e) {
      // The local copy stays exactly as it is. Nothing is half-applied:
      // every write below happens after the round trip that decided it.
      return SyncOutcome(SyncStanding.offline, detail: e.reason);
    } on SharedFactsRefused catch (e) {
      return SyncOutcome(SyncStanding.refused, detail: e.reason);
    }
  }

  /// Creates the shared `trips` row, or reports that it cannot yet.
  ///
  /// Returns null when the row now exists and the caller should carry on.
  Future<SyncOutcome?> _createSharedTrip(TripFact trip, TripId tripId) async {
    final source = tripRow;
    if (source == null) {
      return const SyncOutcome(
        SyncStanding.awaitingTripRow,
        detail: 'nothing can say what the trip clock is',
      );
    }
    final dates =
        (await database.readItineraryDays())
            .map((day) => day.dateIso)
            .whereType<String>()
            .toList()
          ..sort();
    final draft = await source(
      PendingTripRow(
        tripId: tripId,
        name: trip.name,
        startedBy: MemberId(trip.startedByMemberId),
        firstDateIso: dates.isEmpty ? null : dates.first,
        lastDateIso: dates.isEmpty ? null : dates.last,
      ),
    );
    if (draft == null) {
      return const SyncOutcome(
        SyncStanding.awaitingTripRow,
        detail: 'the trip clock is not known yet',
      );
    }
    await facts.createTrip(draft);
    await database.markSynced(tripRowSyncedAtUtcIso: _stamp());
    return null;
  }

  /// Writes the party the server named over this phone's copy.
  ///
  /// The roster propagates on every reconcile and not only at join, which is
  /// the whole of the second half of this task: a phone that joined a party
  /// of three must learn about the fourth without being handed anything.
  Future<void> _applyRoster(RemoteTrip shared, TripFact local) async {
    final dayDates = [
      for (final day in await database.readItineraryDays())
        (day.number, day.dateIso),
    ];
    final incoming = [
      for (final member in shared.members)
        (
          id: member.id.value,
          displayName: member.displayName,
          joinedOnDay: joinedOnDay(joinedAt: member.joinedAt, days: dayDates),
        ),
    ];
    final stored = [
      for (final member in await database.readTripMembers())
        (
          id: member.id,
          displayName: member.displayName,
          joinedOnDay: member.joinedOnDay,
        ),
    ];

    // **A reconcile that changed nothing must write nothing.** The roster's
    // stream is one of the two this class listens to, so a write here asks
    // for the sync that produced it — and a sync that always writes is a sync
    // that never stops. Every apply below is guarded the same way.
    final settled =
        _sameRoster(stored, incoming) &&
        local.startedByMemberId == shared.startedBy.value &&
        local.name == shared.name;
    if (!settled) {
      await database.replaceRoster(
        members: incoming,
        startedByMemberId: shared.startedBy.value,
        name: shared.name,
      );
    }
    await database.markSynced(rosterSyncedAtUtcIso: _stamp());
  }

  static bool _sameRoster(List<TripMemberRecord> a, List<TripMemberRecord> b) {
    if (a.length != b.length) return false;
    String key(TripMemberRecord m) =>
        '${m.id}\u0000${m.displayName}\u0000${m.joinedOnDay}';
    final left = a.map(key).toList()..sort();
    final right = b.map(key).toList()..sort();
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  Future<SyncOutcome> _reconcileItinerary(
    TripId tripId,
    RemoteTrip? shared,
  ) async {
    final state = await database.readSyncState();
    final localDays = await database.readItineraryDays();
    final localStops = await database.readItineraryStops();
    final localAsides = await database.readItinerarySetAsides();

    final merged = await facts.syncItinerary(
      tripId: tripId,
      planRevisedAt: DateTime.parse(state.planRevisedAtUtcIso),
      days: [
        for (final day in localDays)
          RemoteDay(
            number: day.number,
            dateIso: day.dateIso,
            place: day.place,
            revisedAt: DateTime.parse(day.revisedAtUtcIso),
            stops: [
              for (final stop in localStops)
                if (stop.dayNumber == day.number)
                  RemoteStop(
                    position: stop.position,
                    text: stop.stopText,
                    timeIso: stop.timeIso,
                  ),
            ],
          ),
      ],
      pocketRevisedAt: DateTime.parse(state.pocketRevisedAtUtcIso),
      setAside: [
        for (final line in localAsides)
          RemoteSetAside(
            position: line.position,
            sourceLineNumber: line.sourceLineNumber,
            text: line.lineText,
            explanation: line.explanation,
          ),
      ],
    );

    // Applied wholesale and *without* re-stamping: what came back is already
    // the merge of this phone's push and everyone else's, decided by the rule
    // at the top of this file. Stamping it here would make every pull look
    // like a local edit, and two phones would push each other's plans back
    // and forth for as long as they both had signal.
    final incomingDays = [
      for (final day in merged.days)
        (
          number: day.number,
          dateIso: day.dateIso,
          place: day.place,
          revisedAtUtcIso: day.revisedAt.toUtc().toIso8601String(),
        ),
    ];
    final incomingStops = [
      for (final day in merged.days)
        for (final stop in day.stops)
          (
            dayNumber: day.number,
            position: stop.position,
            text: stop.text,
            timeIso: stop.timeIso,
          ),
    ];
    final incomingAsides = [
      for (final line in merged.setAside)
        (
          position: line.position,
          sourceLineNumber: line.sourceLineNumber,
          text: line.text,
          explanation: line.explanation,
        ),
    ];
    final planAt = merged.planRevisedAt.toUtc().toIso8601String();
    final pocketAt = merged.pocketRevisedAt.toUtc().toIso8601String();

    // Guarded for the reason the roster is (see [_applyRoster]): the plan's
    // stream is what asks for a sync, so a reconcile that agreed with this
    // phone must leave the tables alone or it asks for the next one. In the
    // ordinary case — this phone pushed, and won everything it pushed — the
    // answer is exactly what went up, and nothing is written at all.
    final settled =
        _samePlan(
          localDays,
          localStops,
          localAsides,
          incomingDays,
          incomingStops,
          incomingAsides,
        ) &&
        state.planRevisedAtUtcIso == planAt &&
        state.pocketRevisedAtUtcIso == pocketAt;
    if (settled) {
      await database.markSynced(itinerarySyncedAtUtcIso: _stamp());
    } else {
      await database.applyRemoteItinerary(
        days: incomingDays,
        stops: incomingStops,
        setAsides: incomingAsides,
        planRevisedAtUtcIso: planAt,
        pocketRevisedAtUtcIso: pocketAt,
        syncedAtUtcIso: _stamp(),
      );
    }
    return SyncOutcome(
      SyncStanding.synced,
      days: merged.days.length,
      members: shared?.members.length ?? 0,
    );
  }

  static bool _samePlan(
    List<ItineraryDay> days,
    List<ItineraryStop> stops,
    List<ItinerarySetAside> asides,
    List<SyncedDayRecord> incomingDays,
    List<ItineraryStopRecord> incomingStops,
    List<ItinerarySetAsideRecord> incomingAsides,
  ) {
    String here() => [
      for (final day in days)
        '${day.number}|${day.dateIso}|${day.place}|${day.revisedAtUtcIso}',
      '--',
      for (final stop in stops)
        '${stop.dayNumber}|${stop.position}|${stop.stopText}|${stop.timeIso}',
      '--',
      for (final line in asides)
        '${line.position}|${line.sourceLineNumber}|${line.lineText}'
            '|${line.explanation}',
    ].join('\n');
    String there() => [
      for (final day in incomingDays)
        '${day.number}|${day.dateIso}|${day.place}|${day.revisedAtUtcIso}',
      '--',
      for (final stop in incomingStops)
        '${stop.dayNumber}|${stop.position}|${stop.text}|${stop.timeIso}',
      '--',
      for (final line in incomingAsides)
        '${line.position}|${line.sourceLineNumber}|${line.text}'
            '|${line.explanation}',
    ].join('\n');
    return here() == there();
  }

  String _stamp() => now().toUtc().toIso8601String();

  /// Which day of the trip somebody joined on, worked out from the plan.
  ///
  /// **Counted here rather than carried over the wire**, and that is the
  /// point: `trip_roster` hands over the instant and nothing else, because
  /// which day an instant falls on is a function of the itinerary and the
  /// trip's clock — both of which are the phone's. Sending a day number would
  /// be the server computing a trail, which is the line this project does not
  /// cross.
  ///
  /// The reading is UTC, and so approximate at the edges of a day. It is
  /// allowed to be: `joinedOnDay` decides which day of the trail somebody's
  /// name appears from, and the gate opens every sealed day to everyone on
  /// the trip regardless (`cairn_model.GateState.decide`), so being a day out
  /// on a border case withholds nothing from anybody.
  static int joinedOnDay({
    required DateTime joinedAt,
    required List<(int, String?)> days,
  }) {
    final dated = [
      for (final (number, iso) in days)
        if (iso != null) (number, iso),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (dated.isEmpty) return 1;
    final on = joinedAt.toUtc().toIso8601String().substring(0, 10);
    var answer = dated.first.$1;
    for (final (number, iso) in dated) {
      if (iso.compareTo(on) <= 0) answer = number;
    }
    return answer;
  }
}
