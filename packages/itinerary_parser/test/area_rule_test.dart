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

  test('a self-declared area is trusted before the line that declares it', () {
    // The stop-line self-evidence rule needs a position that reads as a
    // locality, and `Hakuba Happo Bus Terminal` gives it none: `hakuba`
    // opens a longer venue name. What rescues it is the plan's own later
    // line `SKY CAFE HAKUBA`, where `hakuba` follows a venue word and so is
    // read as the locality it is. That evidence used to arrive too late --
    // the trusted set was filled in reading order and reset every day -- so
    // the terminal went to Nagano, sixty miles away, and the cafe did not.
    const plan = 'Trip to Nagano\n'
        'Day 1 - Nagano\n'
        '- Hakuba Happo Bus Terminal\n'
        '- SKY CAFE HAKUBA\n'
        '- Zenkoji Temple\n';

    final gaz = SortedListAreaGazetteer(['hakuba', 'nagano']);
    final stops = parseItinerary(plan, gazetteer: gaz).days.single.stops;
    expect(stops[0].area?.text, 'hakuba');
    expect(stops[1].area?.text, 'hakuba');
    // The day's own heading still answers for a stop that declares nothing.
    expect(stops[2].area?.text, 'nagano');

    // And it is still evidence, not a guess: with no gazetteer to confirm
    // that `hakuba` names a place, neither line is touched and the day's own
    // heading stands.
    final blind = parseItinerary(plan).days.single.stops;
    expect(blind[0].area?.text, 'nagano');
  });

  test('a stop names its own area out of the plan\'s own vocabulary', () {
    // Self-evidence used to need a gazetteer, so a plan read phase-1 sent
    // `Hakuba Happo Bus Terminal` to the day's heading and nowhere near
    // Hakuba. The plan corroborates `hakuba` by itself, twice and as a
    // station name, which is the same bar the anchor vocabulary uses for
    // everything else it admits.
    const plan = 'Trip to Nagano\n'
        'Day 1 - Nagano\n'
        '- Hakuba Happo Bus Terminal\n'
        '- SKY CAFE HAKUBA\n'
        '- Walk to Hakuba Station\n'
        '- Bus from Hakuba Station\n'
        '- Zenkoji Temple\n';

    final stops = parseItinerary(plan).days.single.stops;
    expect(stops[0].area?.text, 'hakuba');
    expect(stops[1].area?.text, 'hakuba');
    expect(stops.last.area?.text, 'nagano',
        reason: 'a stop that declares nothing still takes the heading');
  });

  test('a name after a lodging word is the hotel, not a district', () {
    // `HOTEL COURTLAND` is written five times in one real plan and
    // capitalised every time, so the anchor vocabulary admits `courtland`
    // exactly as it admits a district. Lodging is the one venue word that
    // takes the establishment's own name after it, and reading that name as
    // an area sent five stops to a place that does not exist.
    const plan = 'Trip to Nagano\n'
        'Day 1 - Nagano\n'
        '- HOTEL COURTLAND\n'
        '- Walk to Nagano Station\n'
        'Day 2 - Nagano\n'
        '- HOTEL COURTLAND\n';

    for (final day in parseItinerary(plan).days) {
      expect(day.stops.first.area?.text, 'nagano');
    }
  });

  test('a one-word parenthetical the plan knows names the area', () {
    // The traveller writing the district after the venue, which is what a
    // parenthetical on a stop line usually is. It needed a gazetteer until
    // now, so a plan read phase-1 kept the running heading over the words
    // the line itself put there.
    const plan = 'Tokyo trip\n'
        'Day 1 - Shibuya\n'
        '- Start at Shibuya Station\n'
        '- Walk to Shimokitazawa Station\n'
        '- Ogawa coffee laboratory (Shimokitazawa)\n'
        '- Nintendo Tokyo\n';

    final stops = parseItinerary(plan).days.single.stops;
    expect(stops[2].area?.text, 'shimokitazawa');
    // And it speaks for its own line only: the running heading answers the
    // next stop again.
    expect(stops.last.area?.text, 'shibuya');
  });

  test('a longer parenthetical is a description, not an address', () {
    // `MOUMOU TEI (BEEF BOWL)` is written twice in one real plan and
    // capitalised both times, so `beef` and `bowl` reach the anchor
    // vocabulary exactly as a district does. A gazetteer can say that
    // `beef bowl` is not a place; the vocabulary cannot, so without one the
    // rule reaches a single corroborated word and no further.
    const plan = 'Nagoya trip\n'
        'Day 1 - Nagoya\n'
        '- Walk to Nagoya Station\n'
        '- DINNER : MOUMOU TEI (BEEF BOWL)\n'
        'Day 2 - Nagoya\n'
        '- DINNER : MOUMOU TEI (BEEF BOWL)\n';

    for (final day in parseItinerary(plan).days) {
      expect(day.stops.last.area?.text, 'nagoya');
    }
  });
}
