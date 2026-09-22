import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/logic/parsed_areas.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:drift/drift.dart' hide isNull;
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

  test('a chosen candidate row resolves for its choice only', () {
    final chosen = DayStop(
      position: 1,
      text: 'Flight to Milan, train to Como',
      kind: model.StopKind.multiPlace,
      placeCandidates: const ['Milan', 'Como'],
      chosenPlace: 'Como',
      searchText: 'Como',
    );
    expect(chosen.opensMaps, isTrue);

    final unchosen = DayStop(
      position: 1,
      text: 'Flight to Milan, train to Como',
      kind: model.StopKind.multiPlace,
      placeCandidates: const ['Milan', 'Como'],
    );
    expect(unchosen.searchText, isNull);
    expect(unchosen.opensMaps, isFalse);
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
    // The parser preserves ambiguity but picks nothing.
    expect(stored[2].chosenPlace, isNull);
  });

  test('a picked candidate survives the local itinerary', () async {
    final database = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    addTearDown(database.close);
    final repository = TripRepository(database);

    await repository.saveItinerary(
      ConfirmedItinerary(
        days: [
          ConfirmedDay(
            number: 1,
            stops: [
              model.Stop(
                text: 'Flight to Milan, train to Como',
                kind: model.StopKind.multiPlace,
                placeText: 'Milan; Como',
                placeCandidates: const ['Milan', 'Como'],
                chosenPlace: 'Como',
              ),
            ],
          ),
        ],
      ),
    );

    final stored = (await repository.watchItinerary().first)!.days.single.stops;
    expect(stored.single.chosenPlace, 'Como');
    // Alongside, not inside: the parser's fields stand as they were.
    expect(stored.single.kind, model.StopKind.multiPlace);
    expect(stored.single.placeText, 'Milan; Como');
    expect(stored.single.placeCandidates, ['Milan', 'Como']);
  });
}
