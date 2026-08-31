import 'package:flutter_test/flutter_test.dart';
import 'package:cairn/logic/maps_handoff.dart';

void main() {
  group('classifyStopLine', () {
    test('meal label with place', () {
      final c = classifyStopLine('LUNCH: Ichiran');
      expect(c.mealLabel, 'Lunch');
      expect(c.query, 'Ichiran');
      expect(c.kind, StopLineKind.place);
      expect(c.places, ['Ichiran']);
    });

    test('meal label alone is inert', () {
      final c = classifyStopLine('LUNCH: TBD');
      expect(c.mealLabel, 'Lunch');
      expect(c.kind, StopLineKind.inert);
    });

    test('bare meal label is inert', () {
      expect(classifyStopLine('DINNER').kind, StopLineKind.inert);
    });

    test('TBD, URL, wifi are inert', () {
      expect(classifyStopLine('TBD').kind, StopLineKind.inert);
      expect(classifyStopLine('https://example.com').kind, StopLineKind.inert);
      expect(classifyStopLine('Hotel Wi-Fi: SakuraInn-5G · pass 8811').kind, StopLineKind.inert);
    });

    test('multi-place split on commas', () {
      final c = classifyStopLine('Ginza Six, Uniqlo, Dover Street Market, Loft, Mitsukoshi');
      expect(c.places.length, 5);
      expect(c.query, 'Ginza Six, Uniqlo, Dover Street Market, Loft, Mitsukoshi');
    });

    test('ja delimiter', () {
      final c = classifyStopLine('A、B、C');
      expect(c.places.length, 3);
    });

    test('and guard both sides must look name-like', () {
      expect(classifyStopLine('Fish and chips at Magpie').places.length, 1);
      expect(classifyStopLine('Ginza and Shibuya').places.length, 2);
    });

    test('numeric segment prevents split', () {
      expect(classifyStopLine('Room 101, 202').places.length, 1);
    });

    test('segment >6 words prevents split', () {
      expect(classifyStopLine('This is a very long place name indeed here, Short').places.length, 1);
    });

    test('traveller near-X lifted off query', () {
      final c = classifyStopLine('Itoya (near Ginza)');
      expect(c.query, 'Itoya');
      expect(extractTravellerArea('Itoya (near Ginza)'), 'Ginza');
    });

    test('extract @ X and area form', () {
      expect(extractTravellerArea('Cafe @ Shibuya'), 'Shibuya');
      expect(extractTravellerArea('Shop (Ginza area)'), 'Ginza');
    });
  });

  group('URL composer', () {
    test('google template', () {
      final c = classifyStopLine('Nintendo Tokyo (Parco)');
      final uri = mapsSearchUri(stop: c, area: 'Shibuya', app: MapsApp.googleMaps)!;
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/search/');
      expect(uri.queryParameters['query'], 'Nintendo Tokyo (Parco), Shibuya');
      expect(uri.queryParameters['api'], '1');
    });

    test('apple template', () {
      final c = classifyStopLine('Nintendo Tokyo');
      final uri = mapsSearchUri(stop: c, area: 'Shibuya', app: MapsApp.appleMaps)!;
      expect(uri.host, 'maps.apple.com');
      expect(uri.queryParameters['q'], 'Nintendo Tokyo, Shibuya');
    });

    test('waze template', () {
      final c = classifyStopLine('Nintendo Tokyo');
      final uri = mapsSearchUri(stop: c, area: 'Shibuya', app: MapsApp.waze)!;
      expect(uri.host, 'waze.com');
      expect(uri.path, '/ul');
      expect(uri.queryParameters['q'], 'Nintendo Tokyo, Shibuya');
    });

    test('null area ⇒ bare words', () {
      final c = classifyStopLine('Senso-ji');
      final uri = mapsSearchUri(stop: c, area: null)!;
      expect(uri.queryParameters.values.first, isNot(contains(',')));
    });

    test('inert ⇒ null', () {
      final c = classifyStopLine('Hotel Wi-Fi: foo');
      expect(mapsSearchUri(stop: c), isNull);
    });

    test('meal label stripped from uri', () {
      final c = classifyStopLine('DINNER: Gonpachi Nishi-Azabu');
      final uri = mapsSearchUri(stop: c, area: 'Roppongi')!;
      expect(uri.queryParameters['query'], isNot(contains('DINNER')));
      expect(uri.queryParameters['query'], 'Gonpachi Nishi-Azabu, Roppongi');
    });

    test('encoding CJK and emoji', () {
      final c = classifyStopLine('明治神宮');
      final uri = mapsSearchUri(stop: c, area: '原宿')!;
      expect(uri.toString(), contains('%'));
      // round-trip decode
      expect(Uri.decodeComponent(uri.query), contains('明治神宮'));
    });

    test('200 char cap', () {
      final long = 'A' * 300;
      final c = classifyStopLine(long);
      final uri = mapsSearchUri(stop: c)!;
      expect(uri.queryParameters['query']!.length, lessThanOrEqualTo(200));
    });

    test('areaSearchUri', () {
      final uri = areaSearchUri(area: 'Ginza', app: MapsApp.googleMaps);
      expect(uri.queryParameters['query'], 'Ginza');
    });

    test('placeSearchUri with area', () {
      final uri = placeSearchUri(place: 'Uniqlo', area: 'Ginza');
      expect(uri.queryParameters['query'], 'Uniqlo, Ginza');
    });
  });

  group('truncation rule', () {
    test('short multi-place not truncated', () {
      expect(shouldTruncateMultiPlace('Ginza Six, Uniqlo'), isFalse);
    });

    test('long multi-place truncated and badge only for multi-place', () {
      final long = 'Ginza Six, Uniqlo, Dover Street Market, Loft, Mitsukoshi, Extra Shop';
      expect(shouldTruncateMultiPlace(long), isTrue);
      final c = classifyStopLine(long);
      expect(c.places.length, greaterThan(1));
    });

    test('threshold = 48 default', () {
      expect(shouldTruncateMultiPlace('a' * 48), isFalse);
      expect(shouldTruncateMultiPlace('a' * 49), isTrue);
    });
  });
}
