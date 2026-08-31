// A person's area correction is durable, stamps the day it sits on, and
// outranks the parser from then on.
//
// The whole point of the stored `area_source` is that last rule: an area a
// person gave is not something a later parse, a re-paste or a sync may
// quietly replace.
import 'package:cairn/logic/repaste_merge.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

void main() {
  late AppDatabase db;
  late TripRepository repo;

  setUp(() {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    repo = TripRepository(db);
  });
  tearDown(() => db.close());

  Future<void> saveOneDay(List<Stop> stops) => repo.saveItinerary(
    ConfirmedItinerary(
      days: [
        ConfirmedDay(
          number: 1,
          date: CalendarDate(2027, 6, 14),
          place: 'Tokyo',
          stops: stops,
        ),
      ],
    ),
    at: DateTime.utc(2027, 6, 1),
  );

  test('an area and its source survive the round trip through Drift', () async {
    await saveOneDay([
      Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser),
      Stop(text: 'Hotel Wi-Fi: pass 8811', kind: StopKind.note),
    ]);

    final loaded = (await repo.watchItinerary().first)!;
    expect(loaded.days.single.stops.first.area, 'Asakusa');
    expect(loaded.days.single.stops.first.areaSource, AreaSource.parser);
    expect(loaded.days.single.stops.last.kind, StopKind.note);
    expect(loaded.days.single.stops.last.area, isNull);
  });

  test('a correction is stored as a person\'s, and stamps its day', () async {
    await saveOneDay([
      Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser),
    ]);
    final before = (await db.readItineraryDays()).single.revisedAtUtcIso;

    await repo.setStopAreas(
      dayNumber: 1,
      positions: [0],
      area: 'Yanaka',
      areaSource: AreaSource.human,
      at: DateTime.utc(2027, 6, 2),
    );

    final loaded = (await repo.watchItinerary().first)!;
    expect(loaded.days.single.stops.single.area, 'Yanaka');
    expect(loaded.days.single.stops.single.areaSource, AreaSource.human);
    // The day's own clock moved, which is what carries the correction to the
    // other phones; the plan's shape did not change, so its clock did not.
    final after = (await db.readItineraryDays()).single.revisedAtUtcIso;
    expect(after, isNot(before));
    expect(after, DateTime.utc(2027, 6, 2).toIso8601String());
  });

  test('a whole run is corrected in one write', () async {
    await saveOneDay([
      Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser),
      Stop(text: 'Nakamise', area: 'Asakusa', areaSource: AreaSource.parser),
      Stop(text: 'Ueno Park', area: 'Ueno', areaSource: AreaSource.parser),
    ]);

    await repo.setStopAreas(
      dayNumber: 1,
      positions: [0, 1],
      area: 'Yanaka',
      areaSource: AreaSource.human,
      at: DateTime.utc(2027, 6, 2),
    );

    final stops = (await repo.watchItinerary().first)!.days.single.stops;
    expect(stops.map((s) => s.area), ['Yanaka', 'Yanaka', 'Ueno']);
    expect(stops.last.areaSource, AreaSource.parser);
  });

  test('clearing an area is an answer, and stores as one', () async {
    await saveOneDay([
      Stop(text: 'Senso-ji', area: 'Ginza', areaSource: AreaSource.human),
    ]);

    await repo.setStopAreas(
      dayNumber: 1,
      positions: [0],
      area: null,
      areaSource: null,
      at: DateTime.utc(2027, 6, 2),
    );

    final stop = (await repo.watchItinerary().first)!.days.single.stops.single;
    expect(stop.area, isNull);
    expect(stop.areaSource, isNull);
  });

  test('a plan saved before v9 reads back as plain untouched places', () async {
    await saveOneDay([Stop(text: 'Senso-ji')]);
    // What the v9 migration leaves behind: the columns exist, the default
    // stands, and there is nothing to backfill from.
    await db.customStatement(
      "update itinerary_stops set kind = 'place', area_text = null, "
      'area_source = null',
    );
    final stop = (await repo.watchItinerary().first)!.days.single.stops.single;
    expect(stop.kind, StopKind.place);
    expect(stop.area, isNull);
  });

  test('the maps-app preference is this phone\'s, and is remembered', () async {
    expect(await db.readMapsApp(), isNull);
    await db.writeMapsApp('waze');
    expect(await db.readMapsApp(), 'waze');
    await db.writeMapsApp('apple');
    expect(await db.readMapsApp(), 'apple');
  });

  test('a correction outlives a re-paste of the plan text', () {
    final current = [
      ConfirmedDay(
        number: 1,
        date: CalendarDate(2027, 6, 14),
        place: 'Tokyo',
        stops: [
          Stop(text: 'Senso-ji', area: 'Yanaka', areaSource: AreaSource.human),
          Stop(
            text: 'Nakamise',
            area: 'Asakusa',
            areaSource: AreaSource.parser,
          ),
        ],
      ),
    ];
    final repasted = ip
        .parseItinerary('Mon 14 June 2027 - Tokyo\n- Senso-ji\n- Nakamise\n')
        .days;

    final merged = mergeRepaste(current: current, repasted: repasted);

    final stops = merged.days.single.day.stops;
    expect(stops.first.area, 'Yanaka');
    expect(stops.first.areaSource, AreaSource.human);
    // Nothing carries onto a stop nobody corrected.
    expect(stops.last.areaSource, isNot(AreaSource.human));
  });
}
