import 'package:cairn_model/cairn_model.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/repositories/membership_repository.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';

final _tripId = TripId.mint(List.filled(16, 7));

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
      mint: () => _tripId,
    );
  });
  tearDown(() => db.close());

  Future<List<tm.Ping>> launchAndReadSchedule() async {
    final container = ProviderContainer(
      overrides: [
        membershipRepositoryProvider.overrideWithValue(MembershipStore(db)),
        tripRepositoryProvider.overrideWithValue(TripRepository(db)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(tripMembershipProvider, (_, _) {});
    container.listen(savedItineraryProvider, (_, _) {});
    await container.read(tripMembershipProvider.future);
    await container.read(savedItineraryProvider.future);
    return container.read(pingScheduleProvider);
  }

  Future<void> saveMilanWeekend() async {
    await db.startTripIfAbsent(
      starterId: localMemberId,
      starterDisplayName: localMemberName,
    );
    await db.setTripTimeZone('Europe/Rome');
    await TripRepository(db).saveItinerary(
      ConfirmedItinerary(
        days: [
          ConfirmedDay(
            number: 1,
            date: CalendarDate(2026, 10, 24),
            place: 'Milan',
          ),
          ConfirmedDay(
            number: 2,
            date: CalendarDate(2026, 10, 25),
            place: 'Milan',
          ),
        ],
      ),
    );
  }

  test(
    'a persisted Milan clock survives relaunch across DST exactly once',
    () async {
      await saveMilanWeekend();

      final firstLaunch = await launchAndReadSchedule();
      final relaunched = await launchAndReadSchedule();

      expect(firstLaunch, hasLength(2));
      expect(
        relaunched.map((ping) => ping.at),
        orderedEquals(firstLaunch.map((ping) => ping.at)),
      );
      expect(firstLaunch.map((ping) => ping.at).toSet(), hasLength(2));

      for (final ping in firstLaunch) {
        final local = tm.dateInTimeZone(ping.at, 'Europe/Rome');
        expect(local.day, isIn([24, 25]));
      }
    },
  );

  test('an unknown destination clock schedules nothing', () async {
    await db.startTripIfAbsent(
      starterId: localMemberId,
      starterDisplayName: localMemberName,
    );
    await TripRepository(db).saveItinerary(
      ConfirmedItinerary(
        days: [ConfirmedDay(number: 1, date: CalendarDate(2026, 10, 25))],
      ),
    );

    expect(await launchAndReadSchedule(), isEmpty);
  });
}
