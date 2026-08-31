// The Maps handoff's pure half: what a tapped line searches for, and the
// keyless URL that search opens.
//
// Nothing here classifies a line — `itinerary_parser` does that at the paste
// and `cairn_model.Stop.kind` carries it — so what is pinned below is the
// composition, the meal-label split, the multi-place split and the length
// rule the day page draws its badge from.
import 'package:cairn/logic/maps_handoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the query', () {
    test('a stop with an area sends both, joined with a comma', () {
      expect(
        mapsQueryFor(searchText: 'Nintendo Tokyo (Parco)', area: 'Shibuya'),
        'Nintendo Tokyo (Parco), Shibuya',
      );
    });

    test('no area sends the words alone — never a guessed one', () {
      expect(mapsQueryFor(searchText: 'Senso-ji', area: null), 'Senso-ji');
      expect(mapsQueryFor(searchText: 'Senso-ji', area: '  '), 'Senso-ji');
    });

    test('nothing to search for is null, not an empty search', () {
      expect(mapsQueryFor(searchText: null, area: 'Ginza'), isNull);
      expect(mapsQueryFor(searchText: '   ', area: 'Ginza'), isNull);
    });

    test('a pathological line is capped rather than refused', () {
      final query = mapsQueryFor(searchText: 'A' * 300, area: 'Ginza')!;
      expect(query.length, maxQueryLength);
    });
  });

  group('the three apps', () {
    test('Google Maps', () {
      final uri = mapsSearchUri(MapsApp.google, 'Nintendo Tokyo, Shibuya');
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/search/');
      expect(uri.queryParameters['api'], '1');
      expect(uri.queryParameters['query'], 'Nintendo Tokyo, Shibuya');
    });

    test('Apple Maps', () {
      final uri = mapsSearchUri(MapsApp.apple, 'Nintendo Tokyo, Shibuya');
      expect(uri.host, 'maps.apple.com');
      expect(uri.queryParameters['q'], 'Nintendo Tokyo, Shibuya');
    });

    test('Waze', () {
      final uri = mapsSearchUri(MapsApp.waze, 'Nintendo Tokyo, Shibuya');
      expect(uri.host, 'waze.com');
      expect(uri.path, '/ul');
      expect(uri.queryParameters['q'], 'Nintendo Tokyo, Shibuya');
    });

    test('all three are keyless https links', () {
      for (final app in MapsApp.values) {
        final uri = mapsSearchUri(app, 'Senso-ji');
        expect(uri.scheme, 'https');
        expect(uri.query.toLowerCase(), isNot(contains('key=')));
      }
    });

    test('a query is encoded, and survives the round trip', () {
      final uri = mapsSearchUri(MapsApp.google, '明治神宮, 原宿');
      expect(uri.toString(), contains('%'));
      expect(uri.queryParameters['query'], '明治神宮, 原宿');
    });
  });

  group('the meal label', () {
    test('is split off, and only the rest is searched for', () {
      final meal = mealLabelSplit('Lunch: Ichiran');
      expect(meal.label, 'Lunch');
      expect(meal.rest, 'Ichiran');
      expect(
        mapsQueryFor(searchText: meal.rest, area: 'Roppongi'),
        'Ichiran, Roppongi',
      );
    });

    test('reads a dash as well as a colon, and keeps the words as written', () {
      expect(mealLabelSplit('DINNER - Gonpachi').label, 'DINNER');
      expect(mealLabelSplit('DINNER - Gonpachi').rest, 'Gonpachi');
    });

    test('a bare label has nothing after it', () {
      expect(mealLabelSplit('Dinner').rest, isNull);
    });

    test('a line that is not a meal label keeps all its words', () {
      final meal = mealLabelSplit('Senso-ji at opening');
      expect(meal.label, isNull);
      expect(meal.rest, 'Senso-ji at opening');
    });

    test('a place nobody has picked yet is a placeholder', () {
      expect(isPlaceholderText('TBD'), isTrue);
      expect(isPlaceholderText('  tba '), isTrue);
      expect(isPlaceholderText('Ichiran'), isFalse);
    });
  });

  group('the places on a line', () {
    test('an ordinary stop is one place', () {
      expect(placesOn('Senso-ji at opening'), ['Senso-ji at opening']);
    });

    test('a list of shops is every shop', () {
      expect(placesOn('Ginza Six, Uniqlo, Loft'), [
        'Ginza Six',
        'Uniqlo',
        'Loft',
      ]);
    });

    test('reads the delimiters people actually type', () {
      expect(placesOn('A、B、C').length, 3);
      expect(placesOn('Nezu Shrine / SCAI the Bathhouse').length, 2);
      expect(placesOn('Ueno Park and the museums').length, 2);
    });

    test('prose is not split into places that are not there', () {
      expect(placesOn('Room 101, 202'), ['Room 101, 202']);
      expect(
        placesOn('This is a very long place name indeed here, Short').length,
        1,
      );
    });
  });

  group('the badge', () {
    test('is only ever drawn on a row that names more than one place', () {
      final long = 'A single place with a very long name indeed, honestly yes';
      expect(long.length, greaterThan(multiPlaceTruncationThreshold));
      expect(showsPlaceCountBadge(long, placesOn(long)), isFalse);
    });

    test('length decides, so a short list is drawn as written', () {
      const row = 'Ginza Six, Uniqlo';
      expect(showsPlaceCountBadge(row, placesOn(row)), isFalse);
    });

    test('a long list is drawn short with its count', () {
      const row = 'Ginza Six, Uniqlo, Dover Street Market, Loft, Mitsukoshi';
      expect(row.length, greaterThan(multiPlaceTruncationThreshold));
      expect(showsPlaceCountBadge(row, placesOn(row)), isTrue);
      expect(placesOn(row).length, 5);
    });

    test('the threshold is the boundary, not a rounding', () {
      final at = '${'a' * 44}, bb';
      expect(at.length, multiPlaceTruncationThreshold);
      expect(showsPlaceCountBadge(at, placesOn(at)), isFalse);
      final over = '${'a' * 45}, bb';
      expect(showsPlaceCountBadge(over, placesOn(over)), isTrue);
    });
  });
}
