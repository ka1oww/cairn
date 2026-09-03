// APP STATE band (docs/architecture.md): the second door.
//
// Design surface 6a puts two doors on first launch — "Join a trip" beside
// "Start one" — and 6d is the door itself: three words you were told across a
// table, in any order and any spelling that is close. That forgiveness is the
// domain's (`cairn_model`'s `InviteCode.tryParse`), not this file's, and the
// vocabulary is chosen so that a word within one edit of what was said can
// only have been one word.
//
// **What this can and cannot do is the whole point of the file.** Redeeming a
// code means being added to somebody else's trip, and a trip lives on the
// phone it was started on. Nothing carries it across yet — not because there
// is nowhere to carry it to: the backend is hosted, all ten migrations are
// applied, `0005_trip_invites.sql` holds the same three-word grammar this
// file reads, and the itinerary already reaches it (`supabase/README.md`).
// What is missing is the call: nothing on this phone ever asks the server to
// redeem a code. So this flow answers honestly about a code it can
// actually see — this phone's own trip, its retired codes, a trip that has
// closed — and, for a well-formed code belonging to a trip somewhere else,
// says plainly that Cairn cannot reach it rather than spinning, or pretending
// to join, or inventing a party. That last answer is the Phase 2 seam: when
// membership syncs, it is the one case in this file that changes.
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/membership_repository.dart';
import 'ping_schedule.dart';
import 'trip_lifecycle.dart';
import 'trip_providers.dart';

/// What happened when the words were said back to the app.
enum JoinOutcome {
  /// Not three words of the code vocabulary, close enough to read.
  notACode,

  /// This trip's own live code, on the phone that started it.
  alreadyHere,

  /// A code of this trip's that somebody has since retired.
  retired,

  /// A code of this trip's, said after the trip closed.
  ///
  /// Not after it *ended*: a code goes on admitting people through the grace
  /// window, deliberately, because the photographs are still coming and
  /// whoever is holding them has to be able to get in
  /// (`cairn_model`'s `TripStanding.admitsJoiners`).
  tripClosed,

  /// A code that reads properly and belongs to a trip that is not on this
  /// phone. The honest state, and the one Phase 2 replaces.
  elsewhere,
}

/// An answer, and the sentence the screen shows for it.
class JoinAnswer {
  final JoinOutcome outcome;
  final String line;

  const JoinAnswer(this.outcome, this.line);
}

/// The join screen's state: what has been typed, and the last answer.
class JoinState {
  final String typed;

  /// Null until the words have been said back — the screen does not judge
  /// half-typed words.
  final JoinAnswer? answer;

  const JoinState({this.typed = '', this.answer});
}

final joinFlowProvider = NotifierProvider<JoinFlow, JoinState>(JoinFlow.new);

class JoinFlow extends Notifier<JoinState> {
  @override
  JoinState build() => const JoinState();

  /// Typing clears the last answer: an answer about older words, sitting
  /// under newer ones, is a lie about the newer ones.
  void type(String text) => state = JoinState(typed: text);

  void submit() {
    state = JoinState(
      typed: state.typed,
      answer: joinAnswerFor(
        typed: state.typed,
        trip: ref.read(tripMembershipProvider).value,
        closesAt: ref.read(tripClosesAtProvider),
        now: ref.read(nowProvider)(),
        you: model.MemberId(ref.read(localMemberIdProvider)),
      ),
    );
  }
}

/// The whole decision, kept pure.
JoinAnswer joinAnswerFor({
  required String typed,
  required TripMembership? trip,
  required DateTime? closesAt,
  required DateTime now,
  required model.MemberId you,
}) {
  final code = model.InviteCode.tryParse(typed);
  if (code == null) {
    return const JoinAnswer(
      JoinOutcome.notACode,
      'That is not three words of a Cairn code. Any order, any spelling '
      'that is close — but it has to be the words you were told.',
    );
  }

  final matches = [
    for (final invite in trip?.invites ?? const <model.TripInvite>[])
      if (invite.code == code) invite.standingAt(now, tripClosesAt: closesAt),
  ];

  if (matches.contains(model.InviteStanding.live)) {
    final here = trip!.members.any((member) => member.id == you);
    if (here) {
      return const JoinAnswer(
        JoinOutcome.alreadyHere,
        'Those are this trip\'s own words. You are already on it.',
      );
    }
    // Reachable only if the roster ever loses the person holding the phone.
    // Saying "you are on it" then would be the wrong kind of certain.
    return const JoinAnswer(
      JoinOutcome.elsewhere,
      'Those words belong to this trip, but you are not on its roster.',
    );
  }
  if (matches.contains(model.InviteStanding.expired)) {
    return const JoinAnswer(
      JoinOutcome.tripClosed,
      'That trip has closed. Its code died with it — the book it left '
      'behind does not.',
    );
  }
  if (matches.contains(model.InviteStanding.revoked)) {
    return const JoinAnswer(
      JoinOutcome.retired,
      'Those words have been retired. Ask whoever invited you for the '
      'trip\'s code again.',
    );
  }

  // The honest Phase 2 state. It says what is true — the words read fine,
  // and this phone cannot reach the trip they belong to — and it does not
  // guess whether that trip exists, because nothing here can know.
  return JoinAnswer(
    JoinOutcome.elsewhere,
    'Read as ${code.spoken}. That trip is on somebody else\'s phone, and '
    'Cairn cannot reach it yet — trips do not travel between phones. '
    'Nothing here has changed.',
  );
}
