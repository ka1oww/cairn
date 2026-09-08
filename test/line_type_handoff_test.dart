import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/logic/parsed_areas.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn_model/cairn_model.dart' as model;
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
}
