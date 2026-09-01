import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

void main() {
  final gazetteer = SortedListAreaGazetteer([
    'asakusa',
    'harajuku',
    'nerima',
    'shibuya',
  ]);

  test('a unique area in the stop line beats the running heading', () {
    final result = parseItinerary(
      'Trip to Asakusa\nDay 1 - Asakusa\n- OWL VILLAGE CAFE HARAJUKU',
      gazetteer: gazetteer,
    );

    final stop = result.days.single.stops.single;
    expect(stop.area?.text, 'harajuku');
    expect(stop.area?.source, AreaSource.travellerDeclared);
  });

  test('a gazetteer-known train destination can set the running area', () {
    final result = parseItinerary(
      'Trip to Shibuya\nDay 1 - Shibuya\n'
      'Route: SHIBUYA STN -> KOTAKE-MUKAIHARA STN\n'
      'NERIMA STN\n'
      'LUNCH: Eat at Studio Restaurant',
      gazetteer: gazetteer,
    );

    expect(result.days.single.stops[2].area?.text, 'NERIMA');
    expect(result.days.single.stops[2].area?.source, AreaSource.runningHeading);
  });

  test(
      'a vocab-only destination on a route continuation does not set the '
      'running area', () {
    const plan = 'Trip to Shibuya\nDay 1 - Shibuya\n'
        'Route: TOKYO STN -> UENO STN\n'
        '- 10:00 ASAKUSA STN\n'
        '- Ramen dinner\n'
        'Day 2 - Asakusa';

    final withGaz = parseItinerary(
      plan,
      gazetteer: SortedListAreaGazetteer(['shibuya']),
    );
    expect(withGaz.days.first.stops[2].area?.text, 'shibuya');

    final withoutGaz = parseItinerary(plan);
    expect(withoutGaz.days.first.stops[2].area?.text, 'shibuya');
  });

  test(
      'a hyphenated destination matches a gazetteer entry spelled without '
      'the hyphen', () {
    final result = parseItinerary(
      'Trip to Shibuya\nDay 1 - Shibuya\n'
      'Route: SHIBUYA STN -> IKEBUKURO STN\n'
      'KOTAKE-MUKAIHARA STN\n'
      '- Studio lunch',
      gazetteer: SortedListAreaGazetteer(['kotakemukaihara', 'shibuya']),
    );

    expect(result.days.single.stops[2].area?.text, 'KOTAKE-MUKAIHARA');
    expect(result.days.single.stops[2].area?.source, AreaSource.runningHeading);
  });
}
