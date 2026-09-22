// The one nearest-area ordering, and the one add-area candidate ordering,
// shared by the day page's search hints and both add-area dialogs (the
// confirm screen's and the day page's).
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/logic/nearest_areas.dart';

void main() {
  test('the before side leads, then the after side', () {
    expect(nearestAreas(['Asakusa', null, 'Ueno'], 1), ['Asakusa', 'Ueno']);
  });

  test('only one side named answers with that side alone', () {
    expect(nearestAreas([null, null, 'Ueno'], 0), ['Ueno']);
    expect(nearestAreas(['Asakusa', null, null], 2), ['Asakusa']);
  });

  test('the same place either side is offered once', () {
    expect(nearestAreas(['Ueno', null, 'Ueno'], 1), ['Ueno']);
  });

  test('the nearest is found past intervening silence', () {
    expect(nearestAreas(['Asakusa', null, null, null, 'Ueno'], 2), [
      'Asakusa',
      'Ueno',
    ]);
  });

  test('a day naming no area at all offers nothing', () {
    expect(nearestAreas([null, null], 0), isEmpty);
  });

  test('an index off either end is nothing, never a crash', () {
    expect(nearestAreas(['Asakusa'], -1), isEmpty);
    expect(nearestAreas(['Asakusa'], 1), isEmpty);
    expect(nearestAreas(const [], 0), isEmpty);
  });

  group('addAreaCandidates', () {
    test('nearest leads, then every other area the plan names, in plan '
        'order, each once', () {
      expect(
        addAreaCandidates(
          nearest: ['Asakusa', 'Ueno'],
          planAreas: ['Asakusa', null, 'Ueno', 'Ginza', 'Shibuya'],
        ),
        ['Asakusa', 'Ueno', 'Ginza', 'Shibuya'],
      );
    });

    test('a silent plan offers only its nearest', () {
      expect(addAreaCandidates(nearest: ['Yanaka'], planAreas: [null, null]), [
        'Yanaka',
      ]);
    });

    test('nowhere named at all is empty — the blank field, not a crash', () {
      expect(addAreaCandidates(nearest: const [], planAreas: [null]), isEmpty);
      expect(
        addAreaCandidates(nearest: const [], planAreas: const []),
        isEmpty,
      );
    });
  });
}
