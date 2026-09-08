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

  test('a heading run that names no place seeds nothing', () {
    // `Local Gems` is a chat assistant's section title, and `local` reaches
    // the anchor vocabulary honestly: the plan writes it twice and
    // capitalises it once, which is the whole corroboration bar. What it
    // never does is name a place, and the tap rule already says so about a
    // stop line. The seed asks the same question of a heading, so the four
    // stops under this day carry no area rather than a search for `local`.
    const plan = 'Paris trip\n'
        'Day 3 - Museums\n'
        '- Musee Rodin (local favourite)\n'
        'Day 4 - Local Gems\n'
        '- Marche d\'Aligre\n'
        '- Musee de l\'Orangerie\n';

    final r = parseItinerary(plan);
    final day4 = r.days.last;
    expect(day4.place, 'Local Gems');
    for (final stop in day4.stops) {
      expect(stop.area, isNull,
          reason: '"${stop.text}" must not be sent to a search for `local`');
    }
  });

  test('a heading run that does name a place still seeds', () {
    // The other half of the bar. The refusal above is narrow on purpose: it
    // asks only whether the run is made of common words, so an ordinary
    // place still anchors its day exactly as before.
    const plan = 'Japan trip\n'
        'Day 1 - Asakusa\n'
        '- Senso-ji\n'
        'Day 2 - Asakusa\n'
        '- Komehyo\n';

    final r = parseItinerary(plan);
    expect(r.days.last.stops.single.area?.text, 'asakusa');
  });
}
