import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

/// Areas lent to a name the plan writes more than once.
///
/// The engine reads a line in the context of its day, so a stop above the
/// first area its day resolves gets nothing. On the captain's Wanderlog
/// corpus that is where every unanswered row sits, and two cheaper repairs
/// were measured against the hand-labelled rows before this one was written:
/// the nearest preceding area in the day answered none of them (they are all
/// above it), and the day's most common area answered two and got four
/// wrong. Neither is in the code. What is in the code is the plan's own
/// repetition: where every resolved occurrence of a name agrees, that area
/// is lent to the occurrences that have none.
///
/// The three refusals below are the whole of the guard, and each is here
/// because removing it is invisible in a green suite.
ParsedDay _day(ParseResult r, int index) =>
    r.days.firstWhere((d) => d.index == index);

Stop _stopAt(ParseResult r, int line) => r.days
    .expand((d) => d.stops)
    .firstWhere((s) => s.sourceLine.lineNumber == line);

void main() {
  test('a name two days resolved alike lends its area to a bare occurrence',
      () {
    final r = parseItinerary('''
Day 1 - Nagano
- Zenkoji Temple
- Komehyo

Day 2 - Nagano
- Togakushi Shrine
- Komehyo

Sat 6 March 2027
- Komehyo
''');
    // The dated day names no place, so the running area resets to nothing and
    // the engine itself has no answer for line 10. This is the Wanderlog
    // shape exactly.
    final lent = _stopAt(r, 10);
    expect(lent.area?.text, 'nagano');
    expect(lent.area?.source, AreaSource.repeatedName,
        reason: 'a lent area must be distinguishable from a read one');

    // And it never overwrites: the occurrences that resolved on their own
    // keep the provenance they were read with.
    expect(_stopAt(r, 3).area?.source, AreaSource.runningHeading);
    expect(_stopAt(r, 7).area?.source, AreaSource.runningHeading);
  });

  test('one resolved occurrence is not corroboration', () {
    final r = parseItinerary('''
Day 1 - Nagano
- Zenkoji Temple
- Komehyo

Day 2 - Nagano
- Togakushi Shrine

Sat 6 March 2027
- Komehyo
''');
    // `Komehyo` resolves exactly once, on day 1. Lending off a single
    // occurrence is what put `Singapore Changi Airport, Fukuoka` and
    // `Narita International Airport, Fukuoka` in the search box: each airport
    // is written twice in a plan that flies through three of them, and the
    // one resolved occurrence sat under a heading naming the destination
    // city. A distinctive name written twice is usually a leg of a journey.
    expect(_stopAt(r, 9).area, isNull);
  });

  test('twins that disagree stay silent', () {
    final r = parseItinerary('''
Day 1 - Nagano
- Zenkoji Temple
- Komehyo

Day 2 - Nagano
- Togakushi Shrine
- Komehyo

Day 3 - Karuizawa
- Kumoba Pond
- Komehyo

Day 4 - Karuizawa
- Shiraito Falls
- Komehyo

Sat 10 March 2027
- Komehyo
''');
    // Four resolved occurrences, well past the corroboration bar, and they
    // name two different areas. This is the ambiguity the rule exists to
    // respect rather than resolve — one real Japan plan carries two
    // genuinely different Shiraito Waterfalls — so the bare occurrence is
    // left bare. Picking the more frequent of the two would be the thing to
    // refuse in review.
    expect(_stopAt(r, 18).area, isNull);
    expect(_day(r, 1).stops.last.area?.text, 'nagano');
    expect(_day(r, 3).stops.last.area?.text, 'karuizawa');
  });

  test('twins agree when they name one place in different words', () {
    final r = parseItinerary('''
Day 1 - Shibuya
- Shibuya Sky
- Komehyo

Day 2 - Ueno
- Ueno Park
- Komehyo (near Shibuya Station)

Sat 6 March 2027
- Komehyo
''');
    // The two resolved twins read `shibuya` off a heading and `Shibuya
    // Station` off the traveller's own aside. That is one place written two
    // ways, not two places, and comparing the areas as raw text called it
    // disagreement and refused the lend outright. The comparison is on the
    // canonical form, so it agrees. What travels is the plainer of the
    // spellings the plan itself wrote, never a spelling invented here: the
    // station adds nothing a search of `shibuya` does not already have.
    final lent = _stopAt(r, 10).area;
    expect(lent?.source, AreaSource.repeatedName);
    expect(lent?.text, 'shibuya');
  });

  test('a lent area must name a real place', () {
    // `Arrival day` is the traveller's own in-tail wording, which the engine
    // trusts on the line that wrote it because a statement is not a guess.
    // Lending it onward to a line that did not write it is how
    // `Ichiran Ramen, Arrival day` happens, so the lent area has to be known
    // to the plan's own vocabulary or to the gazetteer before it travels.
    final r = parseItinerary('''
Day 1 - Nagano
- Komehyo (Arrival day)
- Komehyo (Arrival day)

Sat 6 March 2027
- Komehyo
''');
    final lent = _stopAt(r, 6).area;
    expect(lent?.text, isNot('Arrival day'));
  });
}
