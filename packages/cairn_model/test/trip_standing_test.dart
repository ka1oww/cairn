// A trip's ending, which is three states and two instants. The shape is
// docs/decisions/2026-08-26-the-ending.md: the last day seals, seventy-two
// hours take nothing but late photographs, and then the trip is the archive.
//
// Both boundaries are pinned to the microsecond on purpose. They are the two
// moments the whole feature is, and "somewhere around three days later" is
// the kind of answer that turns into two answers.
import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

void main() {
  // A Tokyo trip: eight days from 14 June, so the last day is 21 June and it
  // seals at midnight on the trip's own clock — 15:00 UTC on the 21st.
  final tokyo =
      TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9));
  final trip = Trip(
    id: TripId('trip-japan-june'),
    name: 'Japan, June',
    startedBy: MemberId('mum'),
    clock: tokyo,
    members: [
      Member(id: MemberId('mum'), displayName: 'Mum'),
      Member(id: MemberId('ava'), displayName: 'Ava', joinedOnDay: 3),
    ],
    days: TripDay.sequence(
      startDate: CalendarDate(2026, 6, 14),
      length: 8,
      clock: tokyo,
    ),
  );
  final ends = DateTime.utc(2026, 6, 21, 15);
  final closes = DateTime.utc(2026, 6, 24, 15);

  group('the three states', () {
    test('a trip being lived is underway', () {
      expect(
        tripStandingAt(now: DateTime.utc(2026, 6, 16), endsAt: ends),
        TripStanding.underway,
      );
      expect(trip.standingAt(DateTime.utc(2026, 6, 16)), TripStanding.underway);
    });

    test('a trip whose last day has sealed is in its grace', () {
      expect(
        tripStandingAt(now: DateTime.utc(2026, 6, 22, 9), endsAt: ends),
        TripStanding.grace,
      );
    });

    test('a trip past its close is archived', () {
      expect(
        tripStandingAt(now: DateTime.utc(2026, 7, 1), endsAt: ends),
        TripStanding.archived,
      );
    });

    test('a trip whose dates are still open has not ended', () {
      // Not "never ends". It takes a standing the moment the plan has one,
      // which is the same answer an invite gives a null close.
      expect(
        tripStandingAt(now: DateTime.utc(2030), endsAt: null),
        TripStanding.underway,
      );
    });
  });

  group('the boundaries, to the microsecond', () {
    test('underway right up to the seal, and in grace at it', () {
      expect(
        tripStandingAt(
          now: ends.subtract(const Duration(microseconds: 1)),
          endsAt: ends,
        ),
        TripStanding.underway,
      );
      expect(tripStandingAt(now: ends, endsAt: ends), TripStanding.grace);
    });

    test('in grace right up to +72h, and archived at it', () {
      expect(closes, ends.add(graceAfterATrip));
      expect(closes.difference(ends), const Duration(hours: 72));
      expect(
        tripStandingAt(
          now: closes.subtract(const Duration(microseconds: 1)),
          endsAt: ends,
        ),
        TripStanding.grace,
      );
      expect(tripStandingAt(now: closes, endsAt: ends), TripStanding.archived);
    });

    test('the close is the trip\'s own, and the invite takes the same one', () {
      expect(trip.endsAt, ends);
      expect(trip.closesAt, closes);
      expect(trip.standingAt(closes), TripStanding.archived);
      final invite = TripInvite(
        code: InviteCode('otter', 'maple', 42),
        mintedBy: MemberId('mum'),
        mintedAt: DateTime.utc(2026, 6, 1),
      );
      // One rule, one instant: the code dies exactly where the trip closes.
      expect(
        invite.standingAt(closes, tripClosesAt: trip.closesAt),
        InviteStanding.expired,
      );
      expect(
        invite.standingAt(
          closes.subtract(const Duration(microseconds: 1)),
          tripClosesAt: trip.closesAt,
        ),
        InviteStanding.live,
      );
    });

    test('an instant handed in unzoned is read in UTC, not compared raw', () {
      // A `DateTime` that is not UTC names the same instant with different
      // fields, and comparing the fields rather than the instants is how a
      // trip closes on the wrong evening for whoever set their phone to
      // home time. Both of these are the same moment as `ends`, so both are
      // the grace's first microsecond.
      expect(
        tripStandingAt(now: ends.toLocal(), endsAt: ends),
        TripStanding.grace,
      );
      expect(
        tripStandingAt(now: ends, endsAt: ends.toLocal()),
        TripStanding.grace,
      );
      // And one microsecond earlier is still the trip, read either way.
      final justBefore = ends.subtract(const Duration(microseconds: 1));
      expect(
        tripStandingAt(now: justBefore.toLocal(), endsAt: ends),
        TripStanding.underway,
      );
    });
  });

  group('a trip that crossed a border closes on its own evening', () {
    test('the seal follows the last day\'s clock, not UTC midnight', () {
      // The same eight days flown the other way: the last leg is read in
      // Los Angeles, so the day seals at 07:00 UTC on the 22nd — sixteen
      // hours later than the Tokyo trip, and a whole calendar day away from
      // UTC midnight on the 21st. The clock a day is fixed on is where it
      // *started* (`TripDay`), which is why this is the last day's own.
      final la = TripClock.zone(
        'America/Los_Angeles',
        utcOffset: const Duration(hours: -7),
      );
      final flown = Trip(
        id: TripId('trip-west'),
        name: 'The long way round',
        startedBy: MemberId('mum'),
        clock: la,
        members: [Member(id: MemberId('mum'), displayName: 'Mum')],
        days: TripDay.sequence(
          startDate: CalendarDate(2026, 6, 14),
          length: 8,
          clock: la,
        ),
      );
      expect(flown.endsAt, DateTime.utc(2026, 6, 22, 7));
      expect(flown.closesAt, DateTime.utc(2026, 6, 25, 7));

      // The instant the Tokyo trip is already archived, this one is not —
      // and the gap is exactly the two clocks' difference.
      expect(trip.standingAt(closes), TripStanding.archived);
      expect(flown.standingAt(closes), TripStanding.grace);
      expect(
        flown.closesAt.difference(trip.closesAt),
        const Duration(hours: 16),
      );
    });
  });

  group('what each state permits', () {
    final party = [
      Member(id: MemberId('mum'), displayName: 'Mum'),
      Member(id: MemberId('ava'), displayName: 'Ava', joinedOnDay: 3),
    ];
    final mum = MemberId('mum');
    final ava = MemberId('ava');

    test('the grace takes photographs and admits the people bringing them', () {
      expect(TripStanding.grace.takesPhotos, isTrue);
      expect(TripStanding.grace.admitsJoiners, isTrue);
      // And it is still over: nothing about it reads as the trip going on.
      expect(TripStanding.grace.isOver, isTrue);
      expect(TripStanding.grace.isReadOnly, isFalse);
    });

    test('the archive takes nothing and admits nobody', () {
      expect(TripStanding.archived.takesPhotos, isFalse);
      expect(TripStanding.archived.admitsJoiners, isFalse);
      expect(TripStanding.archived.isReadOnly, isTrue);
    });

    test('an underway trip is not over', () {
      expect(TripStanding.underway.isOver, isFalse);
      expect(TripStanding.underway.takesPhotos, isTrue);
      expect(TripStanding.underway.admitsJoiners, isTrue);
      expect(TripStanding.underway.isReadOnly, isFalse);
    });

    test('every power that changes the trip is refused once it is archived',
        () {
      for (final standing in [TripStanding.underway, TripStanding.grace]) {
        expect(
          canRenameTrip(member: mum, members: party, standing: standing),
          isTrue,
          reason: '$standing renames',
        );
        expect(
          canMintInvite(member: mum, members: party, standing: standing),
          isTrue,
        );
        expect(
          canRevokeInvite(
            member: mum,
            startedBy: mum,
            mintedBy: mum,
            standing: standing,
          ),
          isTrue,
        );
        expect(
          canRemoveMember(
            remover: mum,
            target: ava,
            startedBy: mum,
            members: party,
            standing: standing,
          ),
          isTrue,
        );
      }
      const shut = TripStanding.archived;
      expect(
          canRenameTrip(member: mum, members: party, standing: shut), isFalse);
      expect(
          canMintInvite(member: mum, members: party, standing: shut), isFalse);
      expect(
        canRevokeInvite(
          member: mum,
          startedBy: mum,
          mintedBy: mum,
          standing: shut,
        ),
        isFalse,
      );
      expect(
        canRemoveMember(
          remover: mum,
          target: ava,
          startedBy: mum,
          members: party,
          standing: shut,
        ),
        isFalse,
      );
    });

    test('deleting is the deliberate exception, and its own guard still holds',
        () {
      // An archived trip its starter can still be rid of...
      expect(
        canDeleteTrip(
          member: mum,
          startedBy: mum,
          members: party,
          holdsOtherMembersPhotos: false,
        ),
        isTrue,
      );
      expect(trip.canDelete(mum, holdsOtherMembersPhotos: false), isTrue);
      // ...but never once it holds anybody else's photographs, which is what
      // an archive actually has to protect.
      expect(trip.canDelete(mum, holdsOtherMembersPhotos: true), isFalse);
    });

    test('the trip answers all of it through its own clock', () {
      final duringTheGrace = DateTime.utc(2026, 6, 22, 9);
      expect(trip.canRename(mum, now: duringTheGrace), isTrue);
      expect(trip.canMintInvite(mum, now: duringTheGrace), isTrue);
      expect(trip.canRename(mum, now: closes), isFalse);
      expect(trip.canMintInvite(mum, now: closes), isFalse);
      expect(trip.canRemove(remover: mum, target: ava, now: closes), isFalse);
    });
  });
}
