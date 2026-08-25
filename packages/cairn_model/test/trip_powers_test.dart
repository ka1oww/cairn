// Who may do what. The record settles this in two places
// (docs/decisions/2026-08-22-last-calls.md §1 and
// docs/decisions/2026-08-22-starter-and-container.md), and the shape of it is
// the thing worth pinning: one narrow power, everything else flat.
import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

void main() {
  final mum = MemberId('mum');
  final jonas = MemberId('jonas');
  final ava = MemberId('ava');
  final stranger = MemberId('stranger');

  final party = [
    Member(id: mum, displayName: 'Mum'),
    Member(id: jonas, displayName: 'Jonas'),
    Member(id: ava, displayName: 'Ava', joinedOnDay: 3),
  ];

  group('the removal power', () {
    test('is the starter\'s while the starter is here', () {
      expect(removalPowerHolder(startedBy: mum, members: party), mum);
      expect(
        canRemoveMember(
          remover: mum,
          target: ava,
          startedBy: mum,
          members: party,
        ),
        isTrue,
      );
    });

    test('is nobody else\'s', () {
      for (final other in [jonas, ava]) {
        expect(
          canRemoveMember(
            remover: other,
            target: mum,
            startedBy: mum,
            members: party,
          ),
          isFalse,
        );
      }
    });

    test('passes to the longest-standing member when the starter leaves', () {
      final without = [
        for (final m in party)
          if (m.id != mum) m
      ];
      expect(removalPowerHolder(startedBy: mum, members: without), jonas);
      expect(
        canRemoveMember(
          remover: jonas,
          target: ava,
          startedBy: mum,
          members: without,
        ),
        isTrue,
      );
    });

    test('is never nobody, right down to a party of one', () {
      expect(
        removalPowerHolder(startedBy: mum, members: [party.last]),
        ava,
      );
    });

    test('has nobody to hold it only when there is no trip', () {
      expect(
        () => removalPowerHolder(startedBy: mum, members: const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
        'cannot reach somebody who is not on the trip, in either '
        'direction', () {
      expect(
        canRemoveMember(
          remover: mum,
          target: stranger,
          startedBy: mum,
          members: party,
        ),
        isFalse,
      );
      expect(
        canRemoveMember(
          remover: stranger,
          target: ava,
          startedBy: stranger,
          members: party,
        ),
        isFalse,
      );
    });
  });

  group('everything else is flat', () {
    test('anyone on the trip renames it', () {
      for (final member in party) {
        expect(canRenameTrip(member: member.id, members: party), isTrue);
      }
      expect(canRenameTrip(member: stranger, members: party), isFalse);
    });

    test('anyone on the trip mints an invite code', () {
      for (final member in party) {
        expect(canMintInvite(member: member.id, members: party), isTrue);
      }
      expect(canMintInvite(member: stranger, members: party), isFalse);
    });

    test('a code is revoked by whoever minted it, or by the starter', () {
      expect(
        canRevokeInvite(member: ava, startedBy: mum, mintedBy: ava),
        isTrue,
      );
      expect(
        canRevokeInvite(member: mum, startedBy: mum, mintedBy: ava),
        isTrue,
      );
      expect(
        canRevokeInvite(member: jonas, startedBy: mum, mintedBy: ava),
        isFalse,
      );
    });
  });

  group('deleting is not renaming', () {
    test('the starter deletes a trip that holds only their own photos', () {
      expect(
        canDeleteTrip(
          member: mum,
          startedBy: mum,
          members: party,
          holdsOtherMembersPhotos: false,
        ),
        isTrue,
      );
    });

    test(
        'nobody deletes one that holds somebody else\'s — the starter '
        'included', () {
      for (final member in party) {
        expect(
          canDeleteTrip(
            member: member.id,
            startedBy: mum,
            members: party,
            holdsOtherMembersPhotos: true,
          ),
          isFalse,
        );
      }
    });

    test('and it does not pass on when the starter leaves, unlike removal', () {
      final without = [
        for (final m in party)
          if (m.id != mum) m
      ];
      expect(removalPowerHolder(startedBy: mum, members: without), jonas);
      expect(
        canDeleteTrip(
          member: jonas,
          startedBy: mum,
          members: without,
          holdsOtherMembersPhotos: false,
        ),
        isFalse,
      );
    });
  });

  test('a trip answers the same rules through its own members', () {
    final trip = Trip(
      id: TripId('trip-japan-june'),
      name: 'Japan, June',
      startedBy: mum,
      clock: TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9)),
      members: party,
      days: TripDay.sequence(
        startDate: CalendarDate(2026, 6, 14),
        length: 8,
        clock:
            TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9)),
      ),
    );
    final invite = TripInvite(
      code: InviteCode('otter', 'maple', 42),
      mintedBy: ava,
      mintedAt: DateTime.utc(2026, 6, 1),
    );

    expect(trip.removalPowerHolder, mum);
    expect(trip.canRename(ava), isTrue);
    expect(trip.canMintInvite(ava), isTrue);
    expect(trip.canRevoke(jonas, invite), isFalse);
    expect(trip.canRevoke(mum, invite), isTrue);
    expect(trip.canDelete(mum, holdsOtherMembersPhotos: false), isTrue);
    expect(trip.canDelete(mum, holdsOtherMembersPhotos: true), isFalse);
    // The trip's own close, and with it the death of that code.
    expect(trip.closesAt, trip.endsAt.add(graceAfterATrip));
    expect(
      invite.standingAt(trip.closesAt, tripClosesAt: trip.closesAt),
      InviteStanding.expired,
    );
  });
}
