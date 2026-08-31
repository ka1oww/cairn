import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/app_state/link_opener_edge.dart';
import 'package:cairn/logic/maps_handoff.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn_model/cairn_model.dart';

void main() {
  late AppDatabase db;
  late RecordingLinkOpener opener;

  setUp(() {
    db = AppDatabase(
      DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
    );
    opener = RecordingLinkOpener();
  });
  tearDown(() => db.close());

  Future<void> seedItinerary() async {
    final repo = TripRepository(db);
    await repo.saveItinerary(ConfirmedItinerary(
      days: [
        ConfirmedDay(
          number: 1,
          date: CalendarDate(2027, 6, 14),
          place: 'Tokyo',
          stops: [
            Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser),
            Stop(text: 'Standing sushi bar (the cheap good one)'),
            Stop(text: 'Ueno Park and the museums', area: 'Ueno', areaSource: AreaSource.parser),
            Stop(text: 'Ginza Six, Uniqlo, Dover Street Market, Loft, Mitsukoshi', area: 'Ginza', areaSource: AreaSource.parser),
          ],
        ),
      ],
    ));
  }

  Future<void> launch(WidgetTester tester) async {
    await seedItinerary();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bootstrapApp(
      database: db,
      today: DateTime.utc(2027, 6, 14),
      linkOpener: opener,
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('short tap sends search with area', (tester) async {
    await launch(tester);
    // Tap the first stop (Senso-ji) - tappable row index 1
    await tester.tap(find.byKey(const Key('stop-tap-1')));
    await tester.pump();
    expect(opener.lastUri, isNotNull);
    expect(opener.lastUri.toString(), contains('Senso-ji'));
    expect(opener.lastUri.toString(), contains('Asakusa'));
    expect(opener.lastUri.toString(), contains('google.com'));
  });

  testWidgets('area-less short tap sends bare words', (tester) async {
    await launch(tester);
    opener.uris.clear();
    await tester.tap(find.byKey(const Key('stop-tap-2')));
    await tester.pump();
    expect(opener.lastUri.toString(), contains('Standing'));
    expect(opener.lastUri.toString(), isNot(contains('Asakusa')));
    expect(opener.lastUri.toString(), isNot(contains('Ueno')));
  });

  testWidgets('multi-place short tap sends area alone', (tester) async {
    await launch(tester);
    opener.uris.clear();
    await tester.tap(find.byKey(const Key('stop-tap-4')));
    await tester.pump();
    // per composers: multi-place short tap => areaSearchUri
    expect(opener.lastUri.toString(), contains('Ginza'));
    expect(opener.lastUri.toString(), isNot(contains('Uniqlo')));
  });

  testWidgets('long-press multi-place sheet lists places and Just show me', (tester) async {
    await launch(tester);
    await tester.longPress(find.byKey(const Key('stop-tap-4')));
    await tester.pumpAndSettle();
    expect(find.text('Ginza Six'), findsOneWidget);
    expect(find.text('Uniqlo'), findsOneWidget);
    expect(find.textContaining('Just show me Ginza'), findsOneWidget);
  });

  testWidgets('long-press area-less sheet shows nearest to adjacent areas', (tester) async {
    await launch(tester);
    await tester.longPress(find.byKey(const Key('stop-tap-2')));
    await tester.pumpAndSettle();
    expect(find.text('Search it as written'), findsOneWidget);
    expect(find.text('nearest to Asakusa'), findsOneWidget);
    expect(find.text('nearest to Ueno'), findsOneWidget);
    // tapping nearest to Asakusa sends with that area
    await tester.tap(find.text('nearest to Asakusa'));
    await tester.pump();
    expect(opener.lastUri.toString(), contains('Asakusa'));
  });

  testWidgets('inert row has no tap handler', (tester) async {
    // Seed inert stop
    final repo = TripRepository(db);
    await repo.saveItinerary(ConfirmedItinerary(
      days: [
        ConfirmedDay(
          number: 1,
          date: CalendarDate(2027, 6, 14),
          place: 'Tokyo',
          stops: [
            Stop(text: 'Hotel Wi-Fi: SakuraInn-5G · pass 8811'),
            Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser),
          ],
        ),
      ],
    ));
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bootstrapApp(database: db, today: DateTime.utc(2027, 6, 14), linkOpener: opener));
    await tester.pump(); await tester.pump();
    expect(find.byKey(const Key('stop-tap-1')), findsNothing);
    expect(find.byKey(const Key('stop-tap-2')), findsOneWidget);
  });

  testWidgets('Maps app preference switches to Apple/Waze URLs', (tester) async {
    await db.writeMapsApp('appleMaps');
    await launch(tester);
    opener.uris.clear();
    await tester.tap(find.byKey(const Key('stop-tap-1')));
    await tester.pump();
    expect(opener.lastUri!.host, 'maps.apple.com');
    await db.writeMapsApp('waze');
    opener.uris.clear();
    await tester.tap(find.byKey(const Key('stop-tap-1')));
    await tester.pump();
    expect(opener.lastUri!.host, 'waze.com');
  });

  test('classification helpers for inert vs place', () {
    expect(classifyStopLine('Hotel Wi-Fi: foo').kind, StopLineKind.inert);
    final c = classifyStopLine('TeamLab Borderless');
    expect(c.kind, StopLineKind.place);
    expect(shouldTruncateMultiPlace('a' * 100), isTrue);
  });
}
