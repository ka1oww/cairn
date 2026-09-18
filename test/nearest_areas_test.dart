// The one nearest-area ordering, shared by the day page's search hints and
// the confirm screen's add-area fallback.
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
}
