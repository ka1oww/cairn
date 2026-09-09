// The tier a parsed area's provenance lands in decides whether a person's
// correction survives a re-paste: `mergeRepaste` carries a human area onto a
// repasted stop unless the new text itself declares one (travellerOwn). An
// area the parser inferred from the line's own words against the plan's
// vocabulary (`selfEvidence`) is the parser's, so a correction outlives it; a
// bare parenthetical (`travellerProximity`) is the traveller speaking now,
// and wins. Pure unit tests, same design as repaste_merge_test.dart.
import 'package:cairn/logic/parsed_areas.dart';
import 'package:cairn/logic/repaste_merge.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn_model/cairn_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

ip.Stop pStop(String text, {ip.AreaSource? areaSource, String? area}) =>
    ip.Stop(
      text: text,
      sourceLine: ip.SourceLine(1, text),
      area: areaSource == null
          ? null
          : ip.AreaHint(text: area!, source: areaSource),
    );

final jun14 = CalendarDate(2027, 6, 14);

void main() {
  test('vocabulary-inferred self-evidence folds into the parser tier', () {
    expect(areaSourceOf(ip.AreaSource.selfEvidence), AreaSource.parser);
  });

  test('a bare parenthetical stays in the traveller tier', () {
    expect(
      areaSourceOf(ip.AreaSource.travellerProximity),
      AreaSource.travellerOwn,
    );
  });

  test('a human correction survives a re-paste over a self-evidence area', () {
    final current = [
      ConfirmedDay(
        number: 1,
        date: jun14,
        place: 'Nagano',
        stops: [
          Stop(
            text: 'SKY CAFE HAKUBA',
            area: 'Nagano',
            areaSource: AreaSource.human,
          ),
        ],
      ),
    ];
    final repasted = [
      ip.ParsedDay(
        index: 1,
        date: DateTime(2027, 6, 14),
        place: 'Nagano',
        confidence: ip.Confidence.high,
        stops: [
          pStop(
            'SKY CAFE HAKUBA',
            areaSource: ip.AreaSource.selfEvidence,
            area: 'hakuba',
          ),
        ],
      ),
    ];

    final result = mergeRepaste(current: current, repasted: repasted);

    final stop = result.days.single.day.stops.single;
    expect(stop.area, 'Nagano');
    expect(stop.areaSource, AreaSource.human);
  });

  test('the re-paste\'s own parenthetical outranks an older correction', () {
    final current = [
      ConfirmedDay(
        number: 1,
        date: jun14,
        place: 'Tokyo',
        stops: [
          Stop(
            text: 'Ogawa coffee laboratory (Shimokitazawa)',
            area: 'Setagaya',
            areaSource: AreaSource.human,
          ),
        ],
      ),
    ];
    final repasted = [
      ip.ParsedDay(
        index: 1,
        date: DateTime(2027, 6, 14),
        place: 'Tokyo',
        confidence: ip.Confidence.high,
        stops: [
          pStop(
            'Ogawa coffee laboratory (Shimokitazawa)',
            areaSource: ip.AreaSource.travellerProximity,
            area: 'shimokitazawa',
          ),
        ],
      ),
    ];

    final result = mergeRepaste(current: current, repasted: repasted);

    final stop = result.days.single.day.stops.single;
    expect(stop.area, 'shimokitazawa');
    expect(stop.areaSource, AreaSource.travellerOwn);
  });
}
