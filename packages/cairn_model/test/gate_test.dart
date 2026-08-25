import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

/// The gate: contribution opens the day you are living, and every day that is
/// over is already open.
///
/// The rule this file pins was settled on the round-one review board —
/// *"A day that is over belongs to the party. The gate applies to today
/// only."* (`docs/decisions/2026-08-22-grill-round-one.md` §1), with the
/// mid-trip joiner's half in `docs/decisions/2026-08-22-last-calls.md` §3.
/// The deliberate "shut forever" test that pinned the opposite — a past day
/// staying shut against someone who was there and never answered it — is gone
/// with the behaviour, replaced by `a day that is over belongs to the party`
/// below. It was removed rather than worked around, exactly as that decision
/// asked.
void main() {
  final mum = MemberId('mum');
  final jonas = MemberId('jonas');
  final tomas = MemberId('tomas');
  final ava = MemberId('ava');
  final stranger = MemberId('stranger');

  final kyoto =
      TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9));

  final trip = Trip(
    id: TripId('trip-japan-june'),
    name: 'Japan, June',
    startedBy: mum,
    clock: kyoto,
    members: [
      Member(id: mum, displayName: 'Mum'),
      Member(id: jonas, displayName: 'Jonas'),
      Member(id: tomas, displayName: 'Tomas'),
      // Ava joins on day 3, as in the design record's 3d.
      Member(id: ava, displayName: 'Ava', joinedOnDay: 3),
    ],
    days: TripDay.sequence(
      startDate: CalendarDate(2026, 6, 14),
      length: 5,
      clock: kyoto,
    ),
  );

  /// An instant [hour] hours into day [day], on that day's own clock.
  DateTime during(int day, {int hour = 12}) =>
      trip.day(day).startsAt.add(Duration(hours: hour));

  PhotoRef photoOn(int day, MemberId by, {required int hour}) => PhotoRef(
        id: PhotoId('$day-${by.value}-$hour'),
        dayNumber: day,
        contributor: by,
        takenAt: during(day, hour: hour),
        origin: PhotoOrigin.pinged,
      );

  group('the gate opens on contribution, on the day being lived', () {
    final day2 =
        DayPool.of(2, [photoOn(2, mum, hour: 8), photoOn(2, jonas, hour: 19)]);
    final duringDay2 = during(2, hour: 21);

    test('someone who answered sees the day', () {
      expect(trip.gateFor(viewer: mum, pool: day2, now: duringDay2),
          GateState.openedByContribution);
      expect(trip.gateFor(viewer: mum, pool: day2, now: duringDay2).isOpen,
          isTrue);
    });

    test('someone who did not is held shut', () {
      expect(trip.gateFor(viewer: tomas, pool: day2, now: duringDay2),
          GateState.shutAwaitingContribution);
      expect(trip.gateFor(viewer: tomas, pool: day2, now: duringDay2).isOpen,
          isFalse);
    });

    test('starting the trip is not a key', () {
      // Roles are flat. Mum started the trip and is still shut out of the day
      // she is standing in and has not answered.
      final day4 = DayPool.of(4, [photoOn(4, tomas, hour: 12)]);
      expect(trip.gateFor(viewer: mum, pool: day4, now: during(4, hour: 13)),
          GateState.shutAwaitingContribution);
    });

    test('other people answering does not open it for you', () {
      final day4 = DayPool.of(4, [
        photoOn(4, mum, hour: 9),
        photoOn(4, jonas, hour: 13),
        photoOn(4, tomas, hour: 20),
      ]);
      expect(trip.gateFor(viewer: ava, pool: day4, now: during(4, hour: 21)),
          GateState.shutAwaitingContribution);
    });

    test("the day is read on its own clock, not the reader's", () {
      // Day 2 on Kyoto's clock runs to 15:00 UTC on the 15th. At 10:00 UTC
      // that morning the calendar has turned in London and has not in Kyoto,
      // and it is Kyoto's answer that governs -- so the day is still the day
      // being lived, and still shut.
      expect(
        trip.gateFor(
          viewer: tomas,
          pool: DayPool.empty(2),
          now: DateTime.utc(2026, 6, 15, 10),
        ),
        GateState.shutAwaitingContribution,
      );
    });
  });

  group('a day that is over belongs to the party', () {
    test('the day you never answered opens once it is behind you', () {
      // This is the behaviour the removed "shut forever" test denied. Tomas
      // was on the trip for day 1 and let it go by; on day 2 it is his to
      // scroll like everyone else's.
      expect(
        trip.gateFor(viewer: tomas, pool: DayPool.empty(1), now: during(2)),
        GateState.openBecauseTheDayIsOver,
      );
      expect(
        trip
            .gateFor(viewer: tomas, pool: DayPool.empty(1), now: during(2))
            .isOpen,
        isTrue,
      );
    });

    test('every day behind you is open, not just the most recent one', () {
      for (final day in [1, 2, 3]) {
        expect(
          trip.gateFor(
            viewer: tomas,
            pool: DayPool.empty(day),
            now: during(4, hour: 6),
          ),
          GateState.openBecauseTheDayIsOver,
          reason: 'day $day is behind us by day 4',
        );
      }
    });

    test("it opens at the day's own midnight and not a moment before",
        () {
      final seals = trip.day(3).endsAt;
      expect(
        trip.gateFor(
          viewer: tomas,
          pool: DayPool.empty(3),
          now: seals.subtract(const Duration(milliseconds: 1)),
        ),
        GateState.shutAwaitingContribution,
        reason: 'the last millisecond of day 3 is still day 3',
      );
      expect(
        trip.gateFor(viewer: tomas, pool: DayPool.empty(3), now: seals),
        GateState.openBecauseTheDayIsOver,
        reason: 'the day seals at its own midnight and opens as it does',
      );
    });

    test('after the trip every day of it is open to everyone who was there',
        () {
      final afterwards = trip.endsAt.add(const Duration(days: 30));
      for (final day in [1, 2, 3, 4, 5]) {
        expect(
          trip.gateFor(
            viewer: tomas,
            pool: DayPool.empty(day),
            now: afterwards,
          ),
          GateState.openBecauseTheDayIsOver,
        );
      }
    });

    test('contribution still outranks the clock, so the reason never flips',
        () {
      final day2 = DayPool.of(2, [photoOn(2, mum, hour: 8)]);
      expect(trip.gateFor(viewer: mum, pool: day2, now: during(2, hour: 9)),
          GateState.openedByContribution);
      expect(trip.gateFor(viewer: mum, pool: day2, now: during(5)),
          GateState.openedByContribution,
          reason: 'a day you answered reads the same way a week later');
    });
  });

  group('a day that has not begun is shut, for its own reason', () {
    test("tomorrow is not yet anyone's", () {
      expect(
        trip.gateFor(viewer: mum, pool: DayPool.empty(4), now: during(3)),
        GateState.shutUntilTheDayArrives,
      );
      expect(
        trip.gateFor(viewer: mum, pool: DayPool.empty(4), now: during(3)).isOpen,
        isFalse,
      );
    });

    test('before the trip starts, every day of it is ahead', () {
      final beforehand = trip.startsAt.subtract(const Duration(days: 2));
      for (final day in [1, 2, 3, 4, 5]) {
        expect(
          trip.gateFor(viewer: mum, pool: DayPool.empty(day), now: beforehand),
          GateState.shutUntilTheDayArrives,
        );
      }
    });

    test('it is a different state from the day you owe a photo to', () {
      // Both are shut, and they are not the same shut: one says "put
      // something in and it opens", which is only true of the day being
      // lived.
      expect(
        trip.gateFor(viewer: mum, pool: DayPool.empty(3), now: during(3)),
        isNot(
          trip.gateFor(viewer: mum, pool: DayPool.empty(4), now: during(3)),
        ),
      );
    });
  });

  group('a mid-trip joiner', () {
    test('the days before she joined are open, because they are over', () {
      for (final day in [1, 2]) {
        expect(
          trip.gateFor(
            viewer: ava,
            pool: DayPool.empty(day),
            now: during(3, hour: 10),
          ),
          GateState.openBecauseTheDayIsOver,
          reason: 'Ava joined on day 3; day $day was over before she arrived',
        );
      }
    });

    test('the day she joined on is gated like anyone else', () {
      final now = during(3, hour: 17);
      expect(trip.gateFor(viewer: ava, pool: DayPool.empty(3), now: now),
          GateState.shutAwaitingContribution);
      final answered = DayPool.of(3, [photoOn(3, ava, hour: 17)]);
      expect(trip.gateFor(viewer: ava, pool: answered, now: now),
          GateState.openedByContribution);
    });

    test('joining late is no longer a key of its own', () {
      // Ava and Tomas answered neither of the first two days. She arrived on
      // day 3 and he was there the whole time, and on day 3 the two of them
      // see exactly the same past on exactly the same terms.
      final now = during(3, hour: 10);
      for (final day in [1, 2]) {
        expect(
          trip.gateFor(viewer: ava, pool: DayPool.empty(day), now: now),
          trip.gateFor(viewer: tomas, pool: DayPool.empty(day), now: now),
        );
      }
    });
  });

  group('deleting your own photo leaves the day open', () {
    final now = during(4, hour: 15);

    test('the gate stays open after the photo is gone', () {
      final answered = DayPool.of(4, [photoOn(4, jonas, hour: 11)]);
      expect(trip.gateFor(viewer: jonas, pool: answered, now: now),
          GateState.openedByContribution);

      final afterDelete =
          answered.deletePhoto(PhotoId('4-jonas-11'), by: jonas);

      expect(afterDelete.isEmpty, isTrue, reason: 'the photo really is gone');
      expect(
        trip.gateFor(viewer: jonas, pool: afterDelete, now: now),
        GateState.openedByContribution,
        reason: 'deleting a photo does not undo having contributed',
      );
      expect(trip.gateFor(viewer: tomas, pool: afterDelete, now: now),
          GateState.shutAwaitingContribution);
    });

    test('a day emptied by deletion is not a day nobody answered', () {
      final afterDelete = DayPool.of(4, [photoOn(4, jonas, hour: 11)])
          .deletePhoto(PhotoId('4-jonas-11'), by: jonas);
      expect(afterDelete.isEmpty, isTrue);
      expect(afterDelete.hasContributed(jonas), isTrue);
    });
  });

  group('a gate needs somebody to be gated', () {
    test('a non-member has no gate state at all', () {
      expect(
        () => trip.gateFor(
          viewer: stranger,
          pool: DayPool.empty(1),
          now: during(1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a pool for a day the trip does not have is a range error', () {
      expect(
        () => trip.gateFor(
          viewer: mum,
          pool: DayPool.empty(9),
          now: during(1),
        ),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('the rule itself', () {
    test('contribution outranks every standing', () {
      for (final standing in DayStanding.values) {
        expect(
          GateState.decide(standing: standing, hasContributed: true),
          GateState.openedByContribution,
        );
      }
    });

    test('without a contribution, only a walked day is open', () {
      expect(
        GateState.decide(
            standing: DayStanding.walked, hasContributed: false),
        GateState.openBecauseTheDayIsOver,
      );
      expect(
        GateState.decide(
            standing: DayStanding.inProgress, hasContributed: false),
        GateState.shutAwaitingContribution,
      );
      expect(
        GateState.decide(
            standing: DayStanding.notYet, hasContributed: false),
        GateState.shutUntilTheDayArrives,
      );
    });

    test('every state agrees with itself about being open', () {
      expect(GateState.openedByContribution.isOpen, isTrue);
      expect(GateState.openBecauseTheDayIsOver.isOpen, isTrue);
      expect(GateState.shutAwaitingContribution.isOpen, isFalse);
      expect(GateState.shutUntilTheDayArrives.isOpen, isFalse);
    });
  });
}
