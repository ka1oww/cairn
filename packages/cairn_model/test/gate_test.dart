import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

/// Contribution gates access, and the two things that open a day.
void main() {
  const mum = MemberId('mum');
  const jonas = MemberId('jonas');
  const tomas = MemberId('tomas');
  const ava = MemberId('ava');
  const stranger = MemberId('stranger');

  final kyoto =
      TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9));

  final trip = Trip(
    id: const TripId('trip-japan-june'),
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

  PhotoRef photoOn(int day, MemberId by, {required int hour}) => PhotoRef(
        id: PhotoId('$day-${by.value}-$hour'),
        dayNumber: day,
        contributor: by,
        // hour is on the trip's clock; UTC+9 means subtracting nine.
        takenAt: trip.day(day).startsAt.add(Duration(hours: hour)),
        origin: PhotoOrigin.pinged,
      );

  group('the gate opens on contribution', () {
    final day2 =
        DayPool.of(2, [photoOn(2, mum, hour: 8), photoOn(2, jonas, hour: 19)]);

    test('someone who answered sees the day', () {
      expect(trip.gateFor(viewer: mum, pool: day2),
          GateState.openedByContribution);
      expect(trip.gateFor(viewer: mum, pool: day2).isOpen, isTrue);
    });

    test('someone who did not is held shut', () {
      expect(trip.gateFor(viewer: tomas, pool: day2),
          GateState.shutAwaitingContribution);
      expect(trip.gateFor(viewer: tomas, pool: day2).isOpen, isFalse);
    });

    test('starting the trip is not a key', () {
      // Roles are flat. Mum started the trip and is still shut out of a day
      // she has not answered.
      final day4 = DayPool.of(4, [photoOn(4, tomas, hour: 12)]);
      expect(trip.gateFor(viewer: mum, pool: day4),
          GateState.shutAwaitingContribution);
    });

    test('other people answering does not open it for you', () {
      final day4 = DayPool.of(4, [
        photoOn(4, mum, hour: 9),
        photoOn(4, jonas, hour: 13),
        photoOn(4, tomas, hour: 20),
      ]);
      expect(trip.gateFor(viewer: ava, pool: day4),
          GateState.shutAwaitingContribution);
    });
  });

  group('a mid-trip joiner sees every past day freely', () {
    test('the days before she joined are open, unconditionally', () {
      for (final day in [1, 2]) {
        expect(
          trip.gateFor(viewer: ava, pool: DayPool.empty(day)),
          GateState.openBecauseJoinedLater,
          reason: 'Ava joined on day 3; day $day was over before she arrived',
        );
      }
    });

    test('the day she joined on is gated like anyone else', () {
      expect(trip.gateFor(viewer: ava, pool: DayPool.empty(3)),
          GateState.shutAwaitingContribution);
      final answered = DayPool.of(3, [photoOn(3, ava, hour: 17)]);
      expect(trip.gateFor(viewer: ava, pool: answered),
          GateState.openedByContribution);
    });

    test('and the same past day is still shut for someone who was there', () {
      expect(trip.gateFor(viewer: tomas, pool: DayPool.empty(1)),
          GateState.shutAwaitingContribution);
    });
  });

  group('deleting your own photo leaves the day open', () {
    test('the gate stays open after the photo is gone', () {
      final answered = DayPool.of(4, [photoOn(4, jonas, hour: 11)]);
      expect(trip.gateFor(viewer: jonas, pool: answered),
          GateState.openedByContribution);

      final afterDelete =
          answered.deletePhoto(const PhotoId('4-jonas-11'), by: jonas);

      expect(afterDelete.isEmpty, isTrue, reason: 'the photo really is gone');
      expect(
        trip.gateFor(viewer: jonas, pool: afterDelete),
        GateState.openedByContribution,
        reason: 'deleting a photo does not undo having contributed',
      );
      expect(trip.gateFor(viewer: tomas, pool: afterDelete),
          GateState.shutAwaitingContribution);
    });

    test('a day emptied by deletion is not a day nobody answered', () {
      final afterDelete = DayPool.of(4, [photoOn(4, jonas, hour: 11)])
          .deletePhoto(const PhotoId('4-jonas-11'), by: jonas);
      expect(afterDelete.isEmpty, isTrue);
      expect(afterDelete.hasContributed(jonas), isTrue);
    });
  });

  group('a gate needs somebody to be gated', () {
    test('a non-member has no gate state at all', () {
      expect(
        () => trip.gateFor(viewer: stranger, pool: DayPool.empty(1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a pool for a day the trip does not have is a range error', () {
      expect(
        () => trip.gateFor(viewer: mum, pool: DayPool.empty(9)),
        throwsA(isA<RangeError>()),
      );
    });
  });
}
