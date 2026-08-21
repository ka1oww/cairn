import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

void main() {
  const mum = MemberId('mum');
  const ava = MemberId('ava');
  const stranger = MemberId('stranger');

  final kyoto =
      TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9));

  Trip build(
          {List<Member>? members, List<TripDay>? days, MemberId? startedBy}) =>
      Trip(
        id: const TripId('trip-japan-june'),
        name: 'Japan, June',
        startedBy: startedBy ?? mum,
        clock: kyoto,
        members: members ??
            [
              Member(id: mum, displayName: 'Mum'),
              Member(id: ava, displayName: 'Ava', joinedOnDay: 3),
            ],
        days: days ??
            TripDay.sequence(
              startDate: CalendarDate(2026, 6, 14),
              length: 8,
              clock: kyoto,
            ),
      );

  group('the span', () {
    final trip = build();

    test('runs from day 1 to the last day', () {
      expect(trip.length, 8);
      expect(trip.startDate, CalendarDate(2026, 6, 14));
      expect(trip.endDate, CalendarDate(2026, 6, 21));
      expect(trip.startsAt, DateTime.utc(2026, 6, 13, 15));
      expect(trip.endsAt, DateTime.utc(2026, 6, 21, 15));
    });

    test('addressing a day the trip does not have is a range error', () {
      expect(() => trip.day(0), throwsRangeError);
      expect(() => trip.day(9), throwsRangeError);
      expect(trip.day(8).number, 8);
    });
  });

  group('a trip that could not exist is refused', () {
    test('with no days', () {
      expect(() => build(days: []), throwsA(isA<ArgumentError>()));
    });

    test('with days out of order', () {
      expect(
        () => build(days: [
          TripDay(number: 2, date: CalendarDate(2026, 6, 15), clock: kyoto),
          TripDay(number: 1, date: CalendarDate(2026, 6, 14), clock: kyoto),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('with a day that begins before the one before it', () {
      // Same numbering, but the second day's clock puts it earlier in absolute
      // time than the first. Nothing downstream could order these.
      expect(
        () => build(days: [
          TripDay(number: 1, date: CalendarDate(2026, 6, 14), clock: kyoto),
          TripDay(
            number: 2,
            date: CalendarDate(2026, 6, 14),
            clock: TripClock.fixedOffset(const Duration(hours: 12)),
          ),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('with the same person on it twice', () {
      expect(
        () => build(members: [
          Member(id: mum, displayName: 'Mum'),
          Member(id: mum, displayName: 'Mum again'),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('with a starter who is not on it', () {
      expect(() => build(startedBy: stranger), throwsA(isA<ArgumentError>()));
    });

    test('with someone joining on a day the trip never reaches', () {
      expect(
        () => build(members: [
          Member(id: mum, displayName: 'Mum'),
          Member(id: ava, displayName: 'Ava', joinedOnDay: 9),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('removal is the only asymmetry', () {
    final trip = build();

    test('the person who started the trip can remove someone', () {
      expect(trip.canRemove(remover: mum, target: ava), isTrue);
    });

    test('nobody else can', () {
      expect(trip.canRemove(remover: ava, target: mum), isFalse);
    });

    test('and not themselves', () {
      // Leaving is a different thing, available to everyone, and what happens
      // to a trip whose starter leaves is not settled anywhere.
      expect(trip.canRemove(remover: mum, target: mum), isFalse);
    });

    test('and not somebody who is not on the trip', () {
      expect(trip.canRemove(remover: mum, target: stranger), isFalse);
    });
  });

  test('members are reachable by id', () {
    final trip = build();
    expect(trip.memberOrNull(ava)?.displayName, 'Ava');
    expect(trip.memberOrNull(stranger), isNull);
    expect(trip.isMember(mum), isTrue);
  });

  test('the day list cannot be mutated through the trip', () {
    final trip = build();
    expect(
      () => trip.days.add(
          TripDay(number: 9, date: CalendarDate(2026, 6, 22), clock: kyoto)),
      throwsUnsupportedError,
    );
    expect(
      () => trip.members.add(Member(id: stranger, displayName: 'Nope')),
      throwsUnsupportedError,
    );
  });

  test('two trips built the same way are equal', () {
    expect(build(), build());
    expect(build().hashCode, build().hashCode);
  });

  group('TripDay.sequence', () {
    test('numbers days from 1 and walks the calendar', () {
      final days = TripDay.sequence(
        startDate: CalendarDate(2026, 12, 30),
        length: 4,
        clock: kyoto,
      );
      expect(days.map((d) => d.number), [1, 2, 3, 4]);
      expect(days.map((d) => d.date.iso),
          ['2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02']);
    });

    test('carries places and stops through', () {
      final days = TripDay.sequence(
        startDate: CalendarDate(2026, 6, 14),
        length: 2,
        clock: kyoto,
        placesByDay: {2: 'Kyoto'},
        stopsByDay: {
          2: [
            Stop(text: 'Nishiki Market'),
            Stop(text: '★ train to Osaka', time: const ClockTime(18, 40)),
          ],
        },
      );
      expect(days[0].place, isNull);
      expect(days[1].place, 'Kyoto');
      expect(days[1].stops.map((s) => s.isStarred), [false, true]);
    });

    test('rejects an override for a day the trip does not have', () {
      expect(
        () => TripDay.sequence(
          startDate: CalendarDate(2026, 6, 14),
          length: 2,
          clock: kyoto,
          clockOverridesByDay: {5: kyoto},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
