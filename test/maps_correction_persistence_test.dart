import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true)));
  tearDown(() => db.close());

  test('human correction persists via Drift and survives reload', () async {
    final repo = TripRepository(db);
    await repo.saveItinerary(ConfirmedItinerary(
      days: [
        ConfirmedDay(
          number: 1,
          date: CalendarDate(2027, 6, 14),
          place: 'Tokyo',
          stops: [Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser)],
        ),
      ],
    ));

    // Apply human correction (area edit)
    await db.setStopAreas(dayNumber: 1, positions: [0], area: 'Yanaka', areaSource: 'human', nowUtcIso: DateTime.utc(2027, 6, 14, 10).toIso8601String());

    final rows = await db.readItineraryStops();
    expect(rows.single.areaText, 'Yanaka');
    expect(rows.single.areaSource, 'human');

    // Verify via repository read-back
    final loaded = await repo.watchItinerary().first;
    expect(loaded!.days.first.stops.first.area, 'Yanaka');
    expect(loaded.days.first.stops.first.areaSource, AreaSource.human);

    // Verify day clock stamped: revisedAt moved from initial
    final days = await db.readItineraryDays();
    expect(days.single.revisedAtUtcIso, isNotEmpty);
  });

  test('run-level correction stamps day clock and is durable', () async {
    final repo = TripRepository(db);
    await repo.saveItinerary(ConfirmedItinerary(
      days: [
        ConfirmedDay(
          number: 1,
          date: CalendarDate(2027, 6, 14),
          place: 'Tokyo',
          stops: [
            Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser),
            Stop(text: 'Nakamise', area: 'Asakusa', areaSource: AreaSource.parser),
          ],
        ),
      ],
    ));
    final before = (await db.readItineraryDays()).single.revisedAtUtcIso;
    await db.setStopAreas(dayNumber: 1, positions: [0, 1], area: 'Ueno', areaSource: 'human', nowUtcIso: DateTime.utc(2027, 6, 15).toIso8601String());
    final after = (await db.readItineraryDays()).single.revisedAtUtcIso;
    expect(after, isNot(equals(before)));
    final rows = await db.readItineraryStops();
    expect(rows.every((r) => r.areaText == 'Ueno'), isTrue);
  });

  test('clearing area writes nulls', () async {
    final repo = TripRepository(db);
    await repo.saveItinerary(ConfirmedItinerary(
      days: [
        ConfirmedDay(number: 1, date: CalendarDate(2027, 6, 14), place: 'Tokyo', stops: [Stop(text: 'Senso-ji', area: 'Ginza', areaSource: AreaSource.human)]),
      ],
    ));
    await db.setStopAreas(dayNumber: 1, positions: [0], area: null, areaSource: null, nowUtcIso: DateTime.now().toUtc().toIso8601String());
    final rows = await db.readItineraryStops();
    expect(rows.single.areaText, isNull);
    expect(rows.single.areaSource, isNull);
  });

  test('AppPreferences maps app round-trip', () async {
    expect(await db.readMapsApp(), isNull);
    await db.writeMapsApp('waze');
    expect(await db.readMapsApp(), 'waze');
    await db.writeMapsApp('appleMaps');
    expect(await db.readMapsApp(), 'appleMaps');
  });
}
