import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

List<Stop> stopsOf(Iterable<String> lines) {
  final input = ['Day 1:', ...lines].join('\n');
  final result = parseItinerary(input);
  expect(result.days, hasLength(1));
  expect(result.unplacedLines, isEmpty,
      reason: 'typed lines stay in the day instead of being discarded');
  return result.days.single.stops;
}

void main() {
  group('real-itinerary line types', () {
    test('Activities and Food are preserved section labels, not places', () {
      final stops = stopsOf([
        'Activities',
        'Trevi Fountain',
        'Food',
        'Porwa Northern Thai Cuisine (Thai)',
      ]);

      expect(stops.map((stop) => stop.text), [
        'Activities',
        'Trevi Fountain',
        'Food',
        'Porwa Northern Thai Cuisine (Thai)',
      ]);
      expect(stops[0].kind, StopKind.sectionLabel);
      expect(stops[0].placeText, isNull);
      expect(stops[2].kind, StopKind.sectionLabel);
      expect(stops[2].placeText, isNull);
    });

    test('conditional Rome branches remain visible alternatives', () {
      final lines = [
        'If we love Pompeii and weather permits remain there for a few additional hours.',
        'If it is time to move on perhaps Castle Ovo in Naples? Or the National Archeological Museum?',
      ];
      final stops = stopsOf(lines);

      expect(stops.map((stop) => stop.text), lines);
      expect(
          stops.map((stop) => stop.kind), everyElement(StopKind.alternative));
      expect(placesOnLine(stops[0]), ['Pompeii']);
      expect(placesOnLine(stops[1]), [
        'Castle Ovo in Naples',
        'National Archeological Museum',
      ]);
    });

    test('loose verbs expose the place fact separately from the instruction',
        () {
      final stops = stopsOf([
        'Check in at Hotel near Roma Termini at 2:00pm.',
        'Fly to Prague',
        'Return to Roma Termini from Napoli Centrale at 17:35 arriving 18:46.',
      ]);

      expect(stops.map((stop) => stop.kind),
          everyElement(StopKind.placeInstruction));
      expect(stops.map((stop) => stop.placeText), [
        'Hotel near Roma Termini',
        'Prague',
        'Roma Termini',
      ]);
      expect(stops.map((stop) => stop.text), [
        'Check in at Hotel near Roma Termini at 2:00pm.',
        'Fly to Prague',
        'Return to Roma Termini from Napoli Centrale at 17:35 arriving 18:46.',
      ]);
    });

    test('commentary stays visible and is not promoted into a place', () {
      final lines = [
        'Short day due to significant time change',
        'most likely going to cut some out',
        'Alternatively, keep the outbound trip with Italo Treno and book a return trip with Trenitalia? Their Frecciafamily fare is a bit more expensive but appears to allow easy time changes with many trip options.',
      ];
      final stops = stopsOf(lines);

      expect(stops.map((stop) => stop.text), lines);
      expect(stops.map((stop) => stop.kind), everyElement(StopKind.note));
      expect(stops.map((stop) => stop.placeText), everyElement(isNull));
    });

    test('parenthetical category noise stays in text, not the place query', () {
      final stops = stopsOf([
        'maidreamin Thailand Flagship Store (Cosplay cafe)',
        'Terminal 21 (Shopping)',
      ]);

      expect(
          stops[0].text, 'maidreamin Thailand Flagship Store (Cosplay cafe)');
      expect(stops[0].kind, StopKind.place);
      expect(stops[0].placeText, 'maidreamin Thailand Flagship Store');
      expect(stops[1].text, 'Terminal 21 (Shopping)');
      expect(stops[1].kind, StopKind.place);
      expect(stops[1].placeText, 'Terminal 21');
    });

    test('a venue with uncertain snack timing stays visible as an option', () {
      final stop = stopsOf(
        ['Plearn Cafe Bang Pu on the way back for snacks?'],
      ).single;

      expect(stop.text, 'Plearn Cafe Bang Pu on the way back for snacks?');
      expect(stop.kind, StopKind.alternative);
      expect(stop.placeText, 'Plearn Cafe Bang Pu');
    });

    test('station timing is an instruction with an extracted destination', () {
      final stop = stopsOf(
        ['7:40 Italo Treno to Napoli Centrale arriving 8:54'],
      ).single;

      expect(stop.text, '7:40 Italo Treno to Napoli Centrale arriving 8:54');
      expect(stop.kind, StopKind.placeInstruction);
      expect(stop.placeText, 'Napoli Centrale');
    });

    test('multi-purpose lines expose several candidate place expressions', () {
      final stops = stopsOf([
        'Flight to Milan, train to Como, evening in Como (Varenna)',
        'Day trip to Sitges. Take the train to Sitges, explore the old town and beaches, then return to Barcelona.',
      ]);

      expect(stops.map((stop) => stop.kind), everyElement(StopKind.multiPlace));
      expect(placesOnLine(stops[0]), ['Milan', 'Como', 'Varenna']);
      expect(placesOnLine(stops[1]), ['Sitges', 'Barcelona']);
      expect(stops.map((stop) => stop.text), [
        'Flight to Milan, train to Como, evening in Como (Varenna)',
        'Day trip to Sitges. Take the train to Sitges, explore the old town and beaches, then return to Barcelona.',
      ]);
    });

    test('a plain confident stop remains an ordinary place', () {
      final stop = stopsOf(['Trevi Fountain']).single;

      expect(stop.kind, StopKind.place);
      expect(stop.placeText, 'Trevi Fountain');
      expect(placesOnLine(stop), ['Trevi Fountain']);
    });

    test('spelling noise and Thai script are preserved without crashing', () {
      final lines = [
        'Almafi',
        'Almalfi',
        'Baboli gardens',
        'Piazza Navone',
        'สนามยิงธนู Recurve Archery Club (Archery)',
      ];
      final stops = stopsOf(lines);

      expect(stops.map((stop) => stop.text), lines);
      expect(stops, hasLength(lines.length));
      expect(stops.map((stop) => stop.kind), everyElement(StopKind.place));
    });
  });
}
