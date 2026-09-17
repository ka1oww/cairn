// The add-area fallback for stops the parser stays silent on: the confirm
// screen's "+ Add an area" offers the plan's own areas, nearest first, as
// one-tap answers over the same blank field as before. A tap answers the
// whole silent run as the person's, so it outranks the parser from then on
// and survives re-paste and sync like any other correction; leaving it
// unanswered still sends the bare words, exactly as today.
//
// Same real-stack harness as paste_confirm_flow_test.dart: pasted text parsed
// on the phone through the real screens. See that file's header for why the
// database is opened with `closeStreamsSynchronously`.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/link_opener_edge.dart';
import 'package:cairn/app_state/paste_flow.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart';

/// A silent stop between two stops whose areas the plan itself states
/// (in-tail wording the parser trusts without a gazetteer). The middle stop
/// carries no area: the parser stays silent rather than guessing.
const silentBetweenPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji in Asakusa
- Standing sushi bar
- Ueno Park in Ueno
''';

/// A plan that names no area anywhere: the fallback has nothing to offer,
// and the dialog stays the blank field it has always been.
const allSilentPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- Standing sushi bar
''';

/// The date every test in this file reads as today: the plan's own day, so
/// an accepted plan lands straight on its day page.
final _today = DateTime.utc(2027, 6, 14);

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

  Future<void> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(database: db, today: _today, linkOpener: opener),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> paste(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('paste-input')), text);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
  }

  /// The review's stop ids, in day order — the names the notifier answers to.
  List<String> reviewStopIds(WidgetTester tester) {
    final container = ProviderScope.containerOf(
      tester.element(find.text('Standing sushi bar')),
    );
    final state = container.read(pasteFlowProvider);
    assert(state is PasteReview);
    return (state as PasteReview).review.days
        .expand((day) => day.stops)
        .map((stop) => stop.id)
        .toList();
  }

  List<String> candidatesOf(WidgetTester tester, String stopId) {
    final container = ProviderScope.containerOf(
      tester.element(find.text('Standing sushi bar')),
    );
    return container.read(pasteFlowProvider.notifier).areaCandidates(stopId);
  }

  testWidgets('silent runs are offered the neighbouring areas first', (
    tester,
  ) async {
    await launch(tester);
    await paste(tester, silentBetweenPaste);

    // The middle stop is the silent one: no area row stands over it, so the
    // fallback button is drawn for its run.
    expect(find.text('+ Add an area'), findsOneWidget);

    final ids = reviewStopIds(tester);
    expect(ids, hasLength(3));
    // Adjacent first — the before side, then the after side — even though
    // neither orders the plan.
    expect(candidatesOf(tester, ids[1]), ['Asakusa', 'Ueno']);
    // The answered runs need no fallback, but the ordering rule holds for
    // them too: from the first stop only Ueno lies ahead, so it leads.
    expect(candidatesOf(tester, ids[0]), ['Ueno', 'Asakusa']);
    // Unknown stops get nothing, never a crash.
    expect(candidatesOf(tester, 'stop-that-was-never-minted'), isEmpty);
  });

  testWidgets('a plan that names no area offers nothing to tap', (
    tester,
  ) async {
    await launch(tester);
    await paste(tester, allSilentPaste);

    expect(find.text('+ Add an area'), findsOneWidget);
    final ids = reviewStopIds(tester);
    expect(candidatesOf(tester, ids[0]), isEmpty);

    await tester.tap(find.text('+ Add an area'));
    await tester.pumpAndSettle();

    expect(find.text('Add an area'), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    // The blank field with its Cancel and Add: no candidate tiles.
    // (Cancel is a TextButton, Add a FilledButton — one of each, nothing
    // else tappable in the dialog.)
    expect(
      find.descendant(of: dialog, matching: find.byType(TextButton)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(FilledButton)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('add-area-input')), findsOneWidget);
  });

  testWidgets('one tap answers the silent run as the person', (tester) async {
    await launch(tester);
    await paste(tester, silentBetweenPaste);

    await tester.tap(find.text('+ Add an area'));
    await tester.pumpAndSettle();

    // Nearest first on screen, not just in state.
    expect(find.byKey(const Key('add-area-choice-Asakusa')), findsOneWidget);
    expect(find.byKey(const Key('add-area-choice-Ueno')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('add-area-choice-Asakusa'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('add-area-choice-Ueno'))).dy,
      ),
    );

    await tester.tap(find.byKey(const Key('add-area-choice-Asakusa')));
    await tester.pumpAndSettle();

    // The silent run joined its neighbour's: one Asakusa row, and the
    // fallback button is gone. The row still whispers "suggested" — it
    // reads the run's head stop, whose Asakusa is the traveller's own
    // pasted words (which outrank even this answer) — so the human tier
    // is asserted on the answered stop itself, below.
    expect(find.text('Asakusa'), findsOneWidget);
    expect(find.text('+ Add an area'), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.text('Standing sushi bar')),
    );
    final answered =
        ((container.read(
          pasteFlowProvider,
        ) as PasteReview).review.days.first.stops).firstWhere(
          (stop) => stop.text == 'Standing sushi bar',
        );
    expect(answered.area, 'Asakusa');
    expect(answered.areaSource, AreaSource.human);
  });

  testWidgets('the answer rides accept onto the day page and into the store', (
    tester,
  ) async {
    await launch(tester);
    await paste(tester, silentBetweenPaste);

    await tester.tap(find.text('+ Add an area'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-area-choice-Asakusa')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    // The saved stop searches with its new area.
    await tester.tap(find.byKey(const Key('stop-tap-2')));
    await tester.pump();
    expect(
      opener.lastUri!.queryParameters['query'],
      'Standing sushi bar, Asakusa',
    );

    // And it is stored as a person's, which is what outranks the parser.
    final stored = await db.readItineraryStops();
    final answered = stored.firstWhere(
      (s) => s.stopText == 'Standing sushi bar',
    );
    expect(answered.areaText, 'Asakusa');
    expect(answered.areaSource, 'human');
  });

  testWidgets('the answer survives a re-paste that stays silent', (
    tester,
  ) async {
    await launch(tester);
    await paste(tester, silentBetweenPaste);

    await tester.tap(find.text('+ Add an area'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-area-choice-Asakusa')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    // The editor round trip over the unchanged plan text: the re-parse
    // stays silent on the stop, exactly as the first one did.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tab-trail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-sheet-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-edit-plan')));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day-card-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('paste-input')), findsNothing);

    final stored = await db.readItineraryStops();
    final answered = stored.firstWhere(
      (s) => s.stopText == 'Standing sushi bar',
    );
    expect(
      answered.areaText,
      'Asakusa',
      reason:
          'a later parse staying silent must not overwrite the person\'s '
          'answer with nothing',
    );
    expect(answered.areaSource, 'human');
  });
}
