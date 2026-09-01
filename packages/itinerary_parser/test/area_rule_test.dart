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
}
