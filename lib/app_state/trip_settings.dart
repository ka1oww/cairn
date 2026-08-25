// APP STATE band (docs/architecture.md): the trip's own brain — who is on it,
// what it is called, the three words that let somebody else on, and the two
// things that can be done to the trip itself.
//
// The shape is design surfaces 6e and 15c, and the rules are
// `docs/decisions/2026-08-22-starter-and-container.md` read through
// `cairn_model`'s `trip_powers.dart`. Nothing here re-decides them and
// nothing here invents a role:
//
//  - **Renaming is flat.** Any member renames the trip. Making somebody wait
//    for the starter to fix a typo is exactly the hierarchy the flat-roles
//    decision exists to avoid.
//  - **Minting is flat too**, and the trip is given its first code when it is
//    started, so the words are always there to say.
//  - **Deleting is the starter's, and only while the trip holds nobody else's
//    photos.** After that nobody can, the starter included: it would be the
//    irreversible destruction of eight people's memories by one tap.
//  - **The removal power is never drawn as a title.** It is not "admin", it
//    is not a badge, and it does exactly one thing. "Started it" is a fact
//    beside a name, not a rank — which is why it is a note on a row here and
//    not a role anywhere in the model.
//
// Deliberately absent: removing someone (there is nobody else on this phone's
// roster to remove, and a control that can never fire is chrome), leaving
// (the same, and a party of one leaving would leave the trip with nobody),
// changing the trip's clock (no trip clock is stored yet — it is the device's
// offset, so there is nothing here to change), and the link half of sharing
// (no deep link is registered, and a button that copies nothing is a lie).
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/membership_repository.dart';
import '../repositories/photo_repository.dart';
import 'date_labels.dart';
import 'paste_flow.dart';
import 'ping_schedule.dart';
import 'trip_providers.dart';

// ---------------------------------------------------------------------------
// View models — everything a screen may see, spoken in screen terms.
// ---------------------------------------------------------------------------

/// One person on the trip.
class TripPerson {
  /// The name credited under their photos.
  final String name;

  /// `started it`, or `joined day 3` — the design's one quiet note beside a
  /// name, and never a role. Null for everybody else.
  final String? note;

  const TripPerson({required this.name, this.note});
}

/// The trip's live code, as the sheet shows it.
class TripCode {
  /// `['otter', 'maple', '42']` — three lines in the design, because the
  /// stack is what makes it read like something you say rather than a serial
  /// number.
  final List<String> words;

  /// The same code on one line, for reading aloud and for a test to name.
  final String spoken;

  /// When it dies: `Dies with the trip, on 5 July.` — or, on a plan with no
  /// dates yet, that the trip has not said when it ends.
  final String expiry;

  const TripCode({
    required this.words,
    required this.spoken,
    required this.expiry,
  });
}

/// Whether the trip can be deleted, and the sentence that says why not.
class TripDeletion {
  final bool allowed;

  /// Always written, in both states: allowed, it says what deleting takes
  /// with it; refused, it says who cannot and why — the design writes the
  /// refusal out rather than greying a control and explaining nothing.
  final String line;

  const TripDeletion({required this.allowed, required this.line});
}

/// The whole sheet.
class TripSettingsView {
  /// What the trip is called, or null while nobody has named it.
  final String? name;

  /// The trip's own name, or the honest stand-in for one — never a name
  /// derived from the plan, because nothing here guesses what a trip is
  /// called any more than it guesses a date.
  final String headline;

  /// `14–21 June · 8 days`, or `8 days` on a plan with no dates.
  final String? span;

  /// Everyone on the trip, longest-standing first.
  final List<TripPerson> people;

  /// Written when you are the only person here. A roster of one is the
  /// honest state of this app today, not a loading one.
  final String? aloneNote;

  /// The live code, or null when every code has been revoked.
  final TripCode? code;

  /// What saying the code can and cannot do yet.
  final String codeNote;

  final bool canRename;
  final TripDeletion deletion;

  const TripSettingsView({
    this.name,
    required this.headline,
    this.span,
    required this.people,
    this.aloneNote,
    this.code,
    required this.codeNote,
    required this.canRename,
    required this.deletion,
  });
}

// ---------------------------------------------------------------------------
// Providers.
// ---------------------------------------------------------------------------

/// The trip's sheet, or null while no trip has been started.
final tripSettingsProvider = Provider<AsyncValue<TripSettingsView?>>((ref) {
  final trip = ref.watch(tripMembershipProvider);
  final plan = ref.watch(savedItineraryProvider);
  final photos = ref.watch(tripPhotosProvider);

  if (trip case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  if (plan case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  if (photos case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  if (trip case AsyncData(value: final membership)) {
    if (plan case AsyncData(value: final savedPlan)) {
      if (photos case AsyncData(value: final pooled)) {
        return AsyncData(
          tripSettingsFor(
            trip: membership,
            plan: savedPlan,
            photos: pooled,
            you: model.MemberId(localMemberId),
            now: ref.watch(nowProvider),
            utcOffset: ref.watch(tripUtcOffsetProvider),
          ),
        );
      }
    }
  }
  return const AsyncLoading();
});

/// The things the trip's sheet does.
///
/// Every one of them asks `cairn_model` whether the person may, and does
/// nothing if the answer is no. The screen does not offer what is refused —
/// but the check lives here rather than only in the drawing, because a rule
/// enforced by a widget is a rule one new widget can lose.
final tripActionsProvider = Provider<TripActions>(TripActions.new);

class TripActions {
  TripActions(this._ref);

  final Ref _ref;

  model.MemberId get _you => model.MemberId(localMemberId);

  TripMembership? get _trip => _ref.read(tripMembershipProvider).value;

  /// Renames the trip. A blank name clears it back to unnamed rather than
  /// storing an empty string.
  Future<void> rename(String name) async {
    final trip = _trip;
    if (trip == null) return;
    if (!model.canRenameTrip(member: _you, members: trip.members)) return;
    await _ref.read(membershipStoreProvider).rename(name);
  }

  /// Rotates the code: mints a new one and revokes the old.
  ///
  /// Never repoints the old code at anything — a code already circulating for
  /// one trip must not become a key to another, which is refused at the
  /// database level on the server and is why rotation is two acts here.
  Future<void> newCode() async {
    final trip = _trip;
    if (trip == null) return;
    if (!model.canMintInvite(member: _you, members: trip.members)) return;
    final store = _ref.read(membershipStoreProvider);
    final now = _ref.read(nowProvider);
    final closesAt = tripCloseFor(
      _ref.read(savedItineraryProvider).value,
      _ref.read(tripUtcOffsetProvider),
    );
    await store.mintInvite(by: _you, now: now);
    for (final invite in trip.invites) {
      if (invite.standingAt(now, tripClosesAt: closesAt) !=
          model.InviteStanding.live) {
        continue;
      }
      if (!model.canRevokeInvite(
        member: _you,
        startedBy: trip.startedBy,
        mintedBy: invite.mintedBy,
      )) {
        continue;
      }
      await store.revokeInvite(invite.code, now);
    }
  }

  /// Deletes the trip: the plan, the pool's rows, the roster and the codes.
  ///
  /// Refused once the trip holds somebody else's photos, for everyone
  /// including the starter.
  Future<void> deleteTrip() async {
    final trip = _trip;
    if (trip == null) return;
    if (!model.canDeleteTrip(
      member: _you,
      startedBy: trip.startedBy,
      members: trip.members,
      holdsOtherMembersPhotos: _holdsOthersPhotos(
        _ref.read(tripPhotosProvider).value ?? const [],
        _you,
      ),
    )) {
      return;
    }
    await _ref.read(membershipStoreProvider).deleteTrip();
    // The plan went with it, so the flow that made the trip starts from
    // nothing rather than from the confirmation screen it was left on.
    _ref.read(pasteFlowProvider.notifier).forget();
  }
}

// ---------------------------------------------------------------------------
// The derivation, kept pure so it can be read in one sitting.
// ---------------------------------------------------------------------------

/// The instant [plan] closes to new photos — and with it the instant its
/// codes die — or null while the plan has no dates to end on.
///
/// The rule is the domain's (`cairn_model`'s `tripClosesAt`: trip end plus
/// the fourteen-day grace) and is deliberately not spelled out again here.
/// The book's rule is not this one and never will be: it does not expire.
DateTime? tripCloseFor(TripPlan? plan, Duration utcOffset) {
  if (plan == null) return null;
  DateTime? last;
  for (final day in plan.days) {
    final date = day.date;
    if (date == null) continue;
    if (last == null || date.isAfter(last)) last = date;
  }
  if (last == null) return null;
  // A day's date is a bare calendar date carried at UTC midnight; the day
  // itself ends at the next midnight on the trip's clock.
  final endsAt = last.add(const Duration(days: 1)).subtract(utcOffset);
  return model.tripClosesAt(endsAt);
}

/// The sheet for [trip], or null when no trip has been started.
TripSettingsView? tripSettingsFor({
  required TripMembership? trip,
  required TripPlan? plan,
  required List<PooledPhoto> photos,
  required model.MemberId you,
  required DateTime now,
  required Duration utcOffset,
}) {
  if (trip == null) return null;
  final closesAt = tripCloseFor(plan, utcOffset);
  final live = [
    for (final invite in trip.invites)
      if (invite.standingAt(now, tripClosesAt: closesAt) ==
          model.InviteStanding.live)
        invite,
  ];
  final holdsOthers = _holdsOthersPhotos(photos, you);

  return TripSettingsView(
    name: trip.name,
    headline: trip.name ?? 'This trip',
    span: _span(plan, utcOffset),
    people: [
      for (final member in trip.members)
        TripPerson(
          name: member.displayName,
          note: _noteFor(member, trip.startedBy),
        ),
    ],
    aloneNote: trip.members.length > 1
        ? null
        // The honest state of a roster on a phone that cannot yet be told
        // about anyone else. Not a spinner, and not an empty list either.
        : 'Just you so far. Nobody else\'s phone can reach this trip yet.',
    code: live.isEmpty ? null : _codeLine(live.last, closesAt, utcOffset),
    codeNote:
        'Say it out loud — that is the whole trick. Cairn cannot carry '
        'anyone here from their phone yet, so for now the words are the '
        'invitation and nothing arrives.',
    canRename: model.canRenameTrip(member: you, members: trip.members),
    deletion: _deletion(trip, you, holdsOthers),
  );
}

String? _noteFor(model.Member member, model.MemberId startedBy) {
  // "Started it" is a fact, not a rank: it says who began the trip and
  // implies no title. The removal power it carries is never drawn.
  if (member.id == startedBy) return 'started it';
  if (member.joinedOnDay > 1) return 'joined day ${member.joinedOnDay}';
  return null;
}

TripCode _codeLine(
  model.TripInvite invite,
  DateTime? closesAt,
  Duration utcOffset,
) {
  final code = invite.code;
  return TripCode(
    words: [code.firstWord, code.secondWord, '${code.number}'],
    spoken: code.spoken,
    expiry: closesAt == null
        // Truthful rather than reassuring: the code does die with the trip,
        // and this plan has not said when the trip ends.
        ? 'Dies when the trip closes. This plan has no dates yet.'
        // `closesAt` is the instant the trip shuts, which is midnight at the
        // end of the last day it is open — so the date named is the day
        // before it, or the line would read a day late.
        : 'Dies with the trip, after ${dayMonthLabel(closesAt.add(utcOffset).subtract(const Duration(days: 1)))}.',
  );
}

TripDeletion _deletion(
  TripMembership trip,
  model.MemberId you,
  bool holdsOthers,
) {
  final allowed = model.canDeleteTrip(
    member: you,
    startedBy: trip.startedBy,
    members: trip.members,
    holdsOtherMembersPhotos: holdsOthers,
  );
  if (allowed) {
    return const TripDeletion(
      allowed: true,
      line: 'Takes the plan and every photo row with it. It cannot be undone.',
    );
  }
  if (holdsOthers) {
    return const TripDeletion(
      allowed: false,
      line:
          'It holds somebody else\'s photos now, so nobody can — whoever '
          'started it included.',
    );
  }
  return const TripDeletion(
    allowed: false,
    line: 'Only whoever started the trip can delete it.',
  );
}

bool _holdsOthersPhotos(List<PooledPhoto> photos, model.MemberId you) {
  for (final photo in photos) {
    if (photo.ref.contributor != you) return true;
  }
  return false;
}

/// `14–21 June · 8 days`, `8 days`, or null when there is no plan.
String? _span(TripPlan? plan, Duration utcOffset) {
  if (plan == null || plan.days.isEmpty) return null;
  final days = '${plan.days.length} ${plan.days.length == 1 ? 'day' : 'days'}';
  final dated = [
    for (final day in plan.days)
      if (day.date != null) day.date!,
  ]..sort();
  if (dated.isEmpty) return days;
  final first = dated.first;
  final last = dated.last;
  if (first == last) return '${dayMonthLabel(first)} · $days';
  return '${first.day}–${dayMonthLabel(last)} · $days';
}
