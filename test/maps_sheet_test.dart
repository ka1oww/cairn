// The tap-to-Maps surfaces on the day page: what a short tap sends, what the
// long press offers, and that a line which is not a place has no gesture at
// all.
//
// Every URL is captured by a `RecordingLinkOpener` — nothing here reaches a
// browser or a maps app, and the composition itself is pinned in
// `maps_handoff_test.dart`. See `paste_confirm_flow_test.dart`'s header for
// why the database is opened with `closeStreamsSynchronously`.
import 'package:cairn/app_state/link_opener_edge.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late RecordingLinkOpener opener;

  setUp(() {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    opener = RecordingLinkOpener();
  });
  tearDown(() => db.close());

  // Day 4 of the walkthrough: an Asakusa run, a stop with no area between two
  // runs, a two-place row short enough to read as written, and a five-shop row
  // that is not.
  Future<void> seed([List<Stop>? stops]) => TripRepository(db).saveItinerary(
    ConfirmedItinerary(
      days: [
        ConfirmedDay(
          number: 1,
          date: CalendarDate(2027, 6, 14),
          place: 'Tokyo',
          stops:
              stops ??
              [
                Stop(
                  text: 'Senso-ji',
                  area: 'Asakusa',
                  areaSource: AreaSource.parser,
                ),
                Stop(text: 'Standing sushi bar (the cheap good one)'),
                Stop(
                  text: 'Ueno Park and the museums',
                  area: 'Ueno',
                  areaSource: AreaSource.parser,
                ),
                Stop(
                  text:
                      'Ginza Six, Uniqlo, Dover Street Market, Loft, '
                      'Mitsukoshi',
                  area: 'Ginza',
                  areaSource: AreaSource.parser,
                ),
              ],
        ),
      ],
    ),
  );

  Future<void> openTheDay(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: DateTime.utc(2027, 6, 14),
        linkOpener: opener,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a stop under an area searches for both', (tester) async {
    await seed();
    await openTheDay(tester);

    await tester.tap(find.byKey(const Key('stop-tap-1')));
    await tester.pump();

    expect(opener.lastUri!.queryParameters['query'], 'Senso-ji, Asakusa');
    expect(opener.lastUri!.host, 'www.google.com');
  });

  testWidgets('a stop with no area sends its words alone', (tester) async {
    await seed();
    await openTheDay(tester);

    await tester.tap(find.byKey(const Key('stop-tap-2')));
    await tester.pump();

    expect(
      opener.lastUri!.queryParameters['query'],
      'Standing sushi bar (the cheap good one)',
    );
  });

  testWidgets('a short multi-place row is drawn and sent as written', (
    tester,
  ) async {
    await seed();
    await openTheDay(tester);

    expect(find.byKey(const Key('places-badge-3')), findsNothing);
    await tester.tap(find.byKey(const Key('stop-tap-3')));
    await tester.pump();

    expect(
      opener.lastUri!.queryParameters['query'],
      'Ueno Park and the museums, Ueno',
    );
  });

  testWidgets('a long multi-place row is badged, and opens the area', (
    tester,
  ) async {
    await seed();
    await openTheDay(tester);

    expect(find.byKey(const Key('places-badge-4')), findsOneWidget);
    expect(find.text('5 places'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stop-tap-4')));
    await tester.pump();

    expect(opener.lastUri!.queryParameters['query'], 'Ginza');
  });

  testWidgets('the long press lists every place, then the area', (
    tester,
  ) async {
    await seed();
    await openTheDay(tester);

    await tester.longPress(find.byKey(const Key('stop-tap-4')));
    await tester.pumpAndSettle();

    expect(find.text('Ginza Six'), findsOneWidget);
    expect(find.text('Uniqlo'), findsOneWidget);
    expect(find.text('Just show me Ginza'), findsOneWidget);

    await tester.tap(find.text('Uniqlo'));
    await tester.pumpAndSettle();

    expect(opener.lastUri!.queryParameters['query'], 'Uniqlo, Ginza');
  });

  testWidgets('an area-less stop is offered its neighbours, as hints', (
    tester,
  ) async {
    await seed();
    await openTheDay(tester);

    await tester.longPress(find.byKey(const Key('stop-tap-2')));
    await tester.pumpAndSettle();

    expect(find.text('No area is written for this stop.'), findsOneWidget);
    expect(find.text('Search it as written'), findsOneWidget);
    expect(find.text('nearest to Asakusa'), findsOneWidget);
    expect(find.text('nearest to Ueno'), findsOneWidget);
    expect(find.text('Give it an area'), findsOneWidget);

    await tester.tap(find.text('nearest to Ueno'));
    await tester.pumpAndSettle();

    expect(
      opener.lastUri!.queryParameters['query'],
      'Standing sushi bar (the cheap good one), Ueno',
    );
  });

  testWidgets('a line that is not a place has no gesture at all', (
    tester,
  ) async {
    await seed([
      Stop(text: 'Hotel Wi-Fi: SakuraInn-5G, pass 8811', kind: StopKind.note),
      Stop(text: 'Lunch: TBD', kind: StopKind.mealLabel),
      Stop(
        text: 'Dinner: Gonpachi Nishi-Azabu',
        kind: StopKind.mealLabel,
        area: 'Roppongi',
        areaSource: AreaSource.parser,
      ),
    ]);
    await openTheDay(tester);

    // Rendered, all three — nothing is hidden, and nothing is greyed out.
    expect(find.textContaining('SakuraInn-5G'), findsOneWidget);
    expect(find.byKey(const Key('stop-tap-1')), findsNothing);
    expect(find.byKey(const Key('stop-tap-2')), findsNothing);
    expect(find.byKey(const Key('stop-tap-3')), findsOneWidget);

    // The label shows and never reaches the maps app.
    expect(find.text('DINNER'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stop-tap-3')));
    await tester.pump();
    expect(
      opener.lastUri!.queryParameters['query'],
      'Gonpachi Nishi-Azabu, Roppongi',
    );
  });

  testWidgets('correcting a heading fixes the whole run, for good', (
    tester,
  ) async {
    await seed([
      Stop(
        text: 'Yanaka Ginza old shopping street',
        area: 'Cultural Mix',
        areaSource: AreaSource.parser,
      ),
      Stop(
        text: 'Nezu Shrine torii path',
        area: 'Cultural Mix',
        areaSource: AreaSource.parser,
      ),
      Stop(text: 'Ueno Park', area: 'Ueno', areaSource: AreaSource.parser),
    ]);
    await openTheDay(tester);

    await tester.tap(find.byKey(const Key('area-heading-1-Cultural Mix')));
    await tester.pumpAndSettle();
    expect(find.text('Where is this, really?'), findsOneWidget);
    expect(
      find.text('Every stop under this heading will search there.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('area-somewhere-else')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('area-field')), 'Yanaka');
    await tester.tap(find.byKey(const Key('area-save')));
    await tester.pumpAndSettle();

    // The heading redraws, and the run now sends the person's answer.
    expect(find.byKey(const Key('area-heading-1-Yanaka')), findsOneWidget);
    await tester.tap(find.byKey(const Key('stop-tap-2')));
    await tester.pump();
    expect(
      opener.lastUri!.queryParameters['query'],
      'Nezu Shrine torii path, Yanaka',
    );

    // And it is stored as a person's, which is what outranks the parser.
    final stored = await db.readItineraryStops();
    expect(stored.take(2).map((s) => s.areaText), ['Yanaka', 'Yanaka']);
    expect(stored.take(2).map((s) => s.areaSource), ['human', 'human']);
    expect(stored.last.areaText, 'Ueno');
  });

  testWidgets(
    'correcting a heading leaves a same-named, non-adjacent run alone',
    (tester) async {
      await seed([
        Stop(
          text: 'Shibuya Crossing',
          area: 'Shibuya',
          areaSource: AreaSource.parser,
        ),
        Stop(
          text: 'Meiji Shrine',
          area: 'Harajuku',
          areaSource: AreaSource.parser,
        ),
        Stop(
          text: 'Shibuya Sky at dusk',
          area: 'Shibuya',
          areaSource: AreaSource.parser,
        ),
      ]);
      await openTheDay(tester);

      // Both headings render — a repeated area name is not a duplicate key.
      expect(find.byKey(const Key('area-heading-1-Shibuya')), findsOneWidget);
      expect(find.byKey(const Key('area-heading-3-Shibuya')), findsOneWidget);

      await tester.tap(find.byKey(const Key('area-heading-1-Shibuya')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('area-somewhere-else')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('area-field')),
        'Shibuya Station Exit',
      );
      await tester.tap(find.byKey(const Key('area-save')));
      await tester.pumpAndSettle();

      // Only the morning run moved; the evening run stayed on 'Shibuya'.
      final stored = await db.readItineraryStops();
      expect(stored[0].areaText, 'Shibuya Station Exit');
      expect(stored[0].areaSource, 'human');
      expect(stored[1].areaText, 'Harajuku');
      expect(stored[2].areaText, 'Shibuya');
      expect(stored[2].areaSource, 'parser');
    },
  );

  testWidgets('the chosen maps app is the one that opens', (tester) async {
    await seed();
    await db.writeMapsApp('apple');
    await openTheDay(tester);

    await tester.tap(find.byKey(const Key('stop-tap-1')));
    await tester.pump();
    expect(opener.lastUri!.host, 'maps.apple.com');

    await db.writeMapsApp('waze');
    await tester.tap(find.byKey(const Key('stop-tap-1')));
    await tester.pump();
    expect(opener.lastUri!.host, 'waze.com');
  });
}
