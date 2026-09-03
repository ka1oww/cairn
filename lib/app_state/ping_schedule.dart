// APP STATE band (docs/architecture.md): the ping scheduler, and the
// notification edge it writes to.
//
// This file feeds `packages/trip_moments` its inputs and turns the answer
// into a list of notifications to register in one offline pass. **No server
// is consulted, ever** — that is not an optimisation, it is the property the
// whole package exists to hold: every phone derives the same deal from the
// trip, the party and the date, so nothing has to be told anything.
//
// The derivation is a compatibility contract (docs/architecture.md,
// invariant 4). Nothing here may reinterpret it — this layer supplies inputs
// and reads answers.
import 'package:cairn_model/cairn_model.dart' show TripId;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'day_view.dart';
import 'trip_providers.dart';

// ---------------------------------------------------------------------------
// The party, and the one input that is still not real.
//
// **The trip id is no longer among them.** It used to be the constant
// `localTripId`, standing in for a uuid Postgres had not minted yet; the phone
// mints a real one now, when the trip is started and with no connection
// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md), and it is the same
// string the trip will carry after it first syncs. That matters more here than
// anywhere else: the derivation seeds itself from the trip id, so an id that
// changed at first sync would silently re-deal every remaining day of the
// trip. There is nothing to fall back to, and this file no longer offers one.
// ---------------------------------------------------------------------------

/// Who this phone is when nothing has signed in.
///
/// A trip started in flight mode is credited to this, and so is every photo
/// taken before the phone ever reaches a server. It is not a uuid on purpose:
/// the shared schema wants an `auth.users` id and this is visibly not one, so
/// a push that carries it is refused loudly rather than writing a stranger's
/// row (`repositories/itinerary_sync.dart`).
const localMemberId = 'me';

/// Who this phone is, as every surface asks it.
///
/// Overridden in `bootstrap.dart` with the signed-in account's id when there
/// is a session, and left at [localMemberId] when there is not. It is a
/// provider rather than a constant because that is the one change the roster
/// needs: `itinerary_sync.dart` replaces the roster with the server's
/// wholesale, and the server names people by their account id, so a phone
/// still calling itself `me` would be asking the gate, the ping schedule and
/// every "may I" about somebody who is not on the trip.
final localMemberIdProvider = Provider<String>((ref) => localMemberId);

/// What to call the person holding this phone until a sign-in says.
///
/// Not a placeholder name: the display name comes from the Google or Apple
/// sign-in (docs/decisions/2026-08-22-design-calls.md §3) and there is no
/// sign-in yet, so the roster says "You" rather than inventing somebody.
const localMemberName = 'You';

/// The party the day is dealt across: the trip's roster, exactly as stored.
///
/// **The party is an input, not an afterthought.** Each phone derives the
/// whole day's assignment for everyone, which is what makes the schedule
/// collision-free with no server in it; a derivation that knew only its own
/// id could only hash that id, and independent hashes collide and cluster
/// (`packages/trip_moments/README.md`).
///
/// Null while no trip has been started — the roster is empty, and a party of
/// nobody is not a party to deal to. It is deliberately not a fallback party
/// of one: an app with no trip has no pings, and inventing a member to
/// schedule for would be scheduling a ping for a person who is not there.
final tripPartyProvider = Provider<tm.Party?>((ref) {
  final trip = ref.watch(tripMembershipProvider).value;
  if (trip == null || trip.members.isEmpty) return null;
  return tm.Party([for (final member in trip.members) member.id.value]);
});

/// The clock the trip is read in.
///
/// **The same acknowledged approximation as `todayProvider`.** A trip has one
/// clock and it follows the itinerary's leg
/// (docs/decisions/2026-08-22-last-calls.md §4), but no trip row is stored,
/// so this reads the device's offset. It is the second of the two places that
/// change when the trip clock lands, and tests pin it.
final tripUtcOffsetProvider = Provider<Duration>(
  (ref) => DateTime.now().timeZoneOffset,
);

/// Now, in UTC — a clock to *ask*, never an instant to remember.
///
/// **It hands back a function on purpose, and that is the whole of it.** A
/// `Provider<DateTime>` reads the wall clock once and caches that reading for
/// as long as anything listens: `trip_shell.dart` watches the ping
/// registration, which watches this, so the instant used to be taken at
/// launch and never taken again. Every verdict downstream — is the window
/// open, has the trip ended, is this code still live — was then decided
/// against a clock that had stopped when the app started. It read as a
/// deliberate choice ("every surface that reads it is rebuilt by the thing
/// that would have made it interesting") and it was simply false: rebuilding
/// a widget does not recompute a cached provider.
///
/// So the cached thing is the *clock* and not the time. Watching it never
/// rebuilds anybody — the closure's identity does not change, so there is no
/// once-a-second storm over the whole app — and every caller that asks gets
/// the wall clock as it is at the asking. What a caller may not do is
/// remember the answer and add elapsed time on top of it: this is the one
/// place wall time becomes "now", and a second one would let two surfaces
/// disagree about one window.
///
/// What it does not do is *push*. A provider that derived a verdict from an
/// earlier ask keeps that verdict until something invalidates it, so the
/// asking is arranged in exactly one place: the app root (`app.dart`)
/// invalidates this on the way back to the foreground and every
/// [clockRefresh] while it is there, and every time-derived verdict in the
/// app moves together. A surface that grows a refresh of its own instead is
/// the thing to refuse in review — with one deliberate exception, the capture
/// screen's second hand, which counts a two-minute window down and needs a
/// finer grain than the whole app should pay for.
final nowProvider = Provider<Clock>(
  (ref) => Clock(() => DateTime.now().toUtc()),
);

/// How often the app root asks the clock again while the app is in front.
///
/// Coarse on purpose: an invalidation recomputes every time-derived verdict
/// in the app at once, and in ordinary use none of them changes more than
/// once an hour. What it really sets is how long a surface may be wrong for,
/// which is why it is a fraction of the two-minute window and not a round
/// minute — the day page has to stop offering a moment that has passed and
/// start offering one that arrived while the app was already open, and a
/// minute's lag would eat half of the window it is announcing.
const clockRefresh = Duration(seconds: 10);

/// What [nowProvider] hands out: ask it and it reads the wall clock.
///
/// **Two clocks handed out at the same instant are the same clock, and that
/// is what decides who hears an invalidation.** Riverpod tells a provider's
/// dependents nothing when the rebuilt value equals the one it replaced, so a
/// clock that compared equal to its predecessor would make the app root's
/// asking a no-op — the whole point of which is to move every verdict drawn
/// from it. Comparing on [askedAt] gets both cases right at once: a clock a
/// test pinned to an instant really has not moved and rightly wakes nobody,
/// and a running one has, so everything worked out from it is worked out
/// again. It is a plain field read at construction and never recomputed, so
/// [hashCode] holds still for the life of the object.
class Clock {
  Clock._(this.askedAt, this._read);

  factory Clock(DateTime Function() read) => Clock._(read(), read);

  /// What it read at the moment it was handed out.
  final DateTime askedAt;

  final DateTime Function() _read;

  /// Now, as the wall clock has it at the asking.
  DateTime call() => _read();

  @override
  bool operator ==(Object other) => other is Clock && other.askedAt == askedAt;

  @override
  int get hashCode => askedAt.hashCode;
}

/// How much real time has gone by since a measurement was started.
typedef ElapsedSince = Duration Function();

/// Starts one such measurement, at the instant it is called.
typedef StartElapsed = ElapsedSince Function();

/// A clock a test drives: [from] is the instant it starts at, and [moving] is
/// a measurement already running, which is how it advances from there.
///
/// This is the composition, written once, and nothing downstream repeats it.
/// A test that pins only [from] gets a clock that has stopped, which is what
/// most of them want; one that walks a window hands in [moving] as well and
/// the two are added here rather than at the surface reading them.
///
/// Pure, and safe to call again on every rebuild — the measurement is
/// *started* by whoever holds the [StartElapsed], once, and starting it here
/// instead would reset it every time the root asked the clock again. [from]
/// is required because there is no honest clock without it: added to a base
/// that already moves, [moving] would count the same interval twice and run
/// the window down at double speed.
Clock pinnedClock({required DateTime from, ElapsedSince? moving}) =>
    Clock(moving == null ? () => from : () => from.add(moving()));

// ---------------------------------------------------------------------------
// The schedule.
// ---------------------------------------------------------------------------

/// Every ping this phone has coming, over the whole plan, in time order.
///
/// Only *dated* days can be scheduled: a ping is an instant, and a day the
/// person accepted with its date still open has no instant to be. Nothing
/// here guesses one, for the same reason the parser and the day page do not.
final pingScheduleProvider = Provider<List<tm.Ping>>((ref) {
  // No trip is no party and no party is no pings, and the trip is read here
  // for its id: the store minted one before it wrote the row, so a trip that
  // exists has one. There is deliberately no fallback — an invented id would
  // deal a schedule this trip does not have.
  final trip = ref.watch(tripMembershipProvider).value;
  final party = ref.watch(tripPartyProvider);
  if (trip == null || party == null) return const [];
  return pingsForPlan(
    plan: ref.watch(savedItineraryProvider).value,
    party: party,
    utcOffset: ref.watch(tripUtcOffsetProvider),
    memberId: ref.watch(localMemberIdProvider),
    tripId: trip.tripId,
  );
});

/// This phone's ping today, or null — today is not a day of the plan, its
/// date is still open, or the day was too short to hold a slot for everyone.
///
/// "Too short for everyone" is a real answer now that the party is the real
/// roster: eight people on a day that opens at 21:00 do not all get a slot,
/// and fewer slots on a short day is correct rather than a shortfall to pad
/// (docs/decisions/2026-08-22-last-calls.md §8).
final todaysPingProvider = Provider<tm.Ping?>((ref) {
  final today = ref.watch(todayProvider);
  for (final ping in ref.watch(pingScheduleProvider)) {
    final local = ping.at.add(ref.watch(tripUtcOffsetProvider));
    if (local.year == today.year &&
        local.month == today.month &&
        local.day == today.day) {
      return ping;
    }
  }
  return null;
});

/// The pure derivation, kept out of the providers so it can be read and
/// tested in one sitting.
List<tm.Ping> pingsForPlan({
  required TripPlan? plan,
  required tm.Party party,
  required Duration utcOffset,
  required String memberId,
  required TripId tripId,
}) {
  if (plan == null) return const [];
  final pings = <tm.Ping>[];
  for (final day in plan.days) {
    final date = day.date;
    if (date == null) continue;
    final assignment = tm.dayAssignment(
      tripId: tripId.value,
      party: party,
      // Arrival and departure narrow the first and last days, and the
      // itinerary is the only thing that knows them. Nothing stores a flight
      // time yet, so every day here is a full waking day; when the trip's
      // arrival and departure are real facts they arrive as `opensAt` and
      // `closesAt` and nothing else in this file moves.
      day: tm.TripDay(date: date, utcOffset: utcOffset),
    );
    final mine = assignment.pingFor(memberId);
    if (mine != null) pings.add(mine);
  }
  pings.sort((a, b) => a.at.compareTo(b.at));
  return List.unmodifiable(pings);
}

// ---------------------------------------------------------------------------
// The notification edge.
// ---------------------------------------------------------------------------

/// One local notification, as the edge is asked to register it.
class ScheduledPing {
  /// The instant to fire at, in UTC.
  final DateTime at;

  /// Surface 13d's words. The ping says to look up, and says nothing about
  /// what to photograph — the camera turns around by itself because of who
  /// is holding the phone, not because anyone was instructed
  /// (docs/decisions/2026-08-22-the-moment.md).
  final String title;
  final String body;

  const ScheduledPing({
    required this.at,
    required this.title,
    required this.body,
  });
}

/// The platform's local-notification scheduler, behind a seam.
///
/// **Ordinary alert level, always.** Cairn does not hold the time-sensitive
/// entitlement and never asks for it; the ping does not pierce a Focus mode
/// or escape the notification summary
/// (docs/decisions/2026-08-22-notification-alert-level.md). An implementation
/// of this interface that requests one is the bug to refuse in review.
abstract interface class NotificationEdge {
  /// Replaces every ping this app has registered with exactly [pings].
  ///
  /// Replace rather than append, because the schedule is *derived*: the plan
  /// changing re-deals every remaining day, and an append would leave the old
  /// deal firing alongside the new one — two interruptions in a day, which
  /// is the one thing the whole mechanic promises never to do.
  Future<void> replaceScheduledPings(List<ScheduledPing> pings);
}

/// The edge that remembers instead of ringing.
///
/// **This is what the app binds today**, and it is the one genuinely unbuilt
/// piece of the ping: the derivation, the pass and the replace-not-append
/// rule are all real, and registering them with iOS is a class that
/// implements this interface. Nothing above this line changes when it lands.
class RecordingNotificationEdge implements NotificationEdge {
  List<ScheduledPing> registered = const [];

  @override
  Future<void> replaceScheduledPings(List<ScheduledPing> pings) async {
    registered = List.unmodifiable(pings);
  }
}

final notificationEdgeProvider = Provider<NotificationEdge>(
  (ref) => RecordingNotificationEdge(),
);

/// Registers every ping still to come, in one pass, and re-registers when the
/// plan changes.
///
/// Watching rather than calling: the schedule is derived from the itinerary,
/// so "when should this run" has exactly one honest answer — whenever the
/// deal itself changes. The side effect in [build] is the mirror being kept
/// in step, and the replace-not-append rule above is what makes running it
/// twice harmless.
///
/// **The clock is read and never watched, and that is the difference between
/// a pass and a habit.** It answers one question — which of the deal is
/// already behind us — and the answer does not need re-asking, because a
/// ping that has fired needs no unregistering. Watching it made this a side
/// effect on the app root's cadence instead: every ten seconds the trip's
/// whole notification set torn down and put back, with a window on each pass
/// where none of it was registered at all.
final pingRegistrationProvider =
    NotifierProvider<PingRegistration, List<tm.Ping>>(PingRegistration.new);

class PingRegistration extends Notifier<List<tm.Ping>> {
  @override
  List<tm.Ping> build() {
    final from = ref.read(nowProvider)();
    final due = [
      for (final ping in ref.watch(pingScheduleProvider))
        if (!ping.at.isBefore(from)) ping,
    ];
    ref.read(notificationEdgeProvider).replaceScheduledPings([
      for (final ping in due)
        ScheduledPing(
          at: ping.at,
          title: 'Cairn now',
          body: "Look up. Where've they all got to?",
        ),
    ]);
    return List.unmodifiable(due);
  }
}
