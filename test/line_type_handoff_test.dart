import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/logic/parsed_areas.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as parser;

void main() {
  test(
    'every parser line type crosses the app boundary without collapsing',
    () {
      for (final kind in parser.StopKind.values) {
        expect(stopKindOf(kind).name, kind.name);
      }
    },
  );

  test('every line type survives its stored name', () {
    for (final kind in model.StopKind.values) {
      expect(stopKindFromStored(kind.name), kind);
    }
  });

  test('non-committed line types stay inert even if given search text', () {
    for (final kind in [
      model.StopKind.sectionLabel,
      model.StopKind.alternative,
      model.StopKind.placeInstruction,
      model.StopKind.multiPlace,
      model.StopKind.areaHeading,
      model.StopKind.note,
    ]) {
      final stop = DayStop(
        position: 1,
        text: 'kept exactly as written',
        kind: kind,
        searchText: 'must not be resolved',
      );
      expect(stop.opensMaps, isFalse, reason: kind.name);
    }
  });

  test('ordinary places and meal payloads remain resolvable', () {
    for (final kind in [model.StopKind.place, model.StopKind.mealLabel]) {
      final stop = DayStop(
        position: 1,
        text: 'Trevi Fountain',
        kind: kind,
        searchText: 'Trevi Fountain',
      );
      expect(stop.opensMaps, isTrue, reason: kind.name);
    }
  });

  test('extracted terms and candidates survive the local itinerary', () async {
    final database = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    addTearDown(database.close);
    final parsed = parser
        .parseItinerary(
          'Day 1\n'
          '- Terminal 21 (Shopping)\n'
          '- Fly to Prague\n'
          '- Flight to Milan, train to Como, evening in Como (Varenna)',
        )
        .days
        .single
        .stops;
    final repository = TripRepository(database);

    await repository.saveItinerary(
      ConfirmedItinerary(
        days: [
          ConfirmedDay(
            number: 1,
            stops: [
              for (final stop in parsed)
                model.Stop(
                  text: stop.text,
                  kind: stopKindOf(stop.kind),
                  placeText: stop.placeText,
                  placeCandidates: stop.placeCandidates,
                ),
            ],
          ),
        ],
      ),
    );

    final stored = (await repository.watchItinerary().first)!.days.single.stops;
    expect(stored[0].text, 'Terminal 21 (Shopping)');
    expect(stored[0].placeText, 'Terminal 21');
    expect(stored[0].placeCandidates, ['Terminal 21']);
    expect(stored[1].placeText, 'Prague');
    expect(stored[1].placeCandidates, ['Prague']);
    expect(stored[2].kind, model.StopKind.multiPlace);
    expect(stored[2].placeCandidates, ['Milan', 'Como', 'Varenna']);
  });
}
