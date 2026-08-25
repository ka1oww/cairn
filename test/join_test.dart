// The second door: saying three words back to the app, and what it answers.
//
// The point of these tests is the answers, including the honest one. A code
// that reads perfectly but belongs to a trip on somebody else's phone cannot
// be redeemed — nothing carries a membership between phones yet — and the
// screen has to say that rather than spin or pretend. Each state below is one
// sentence a person could act on.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn_model/cairn_model.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari
''';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

void main() {
  late AppDatabase db;

  setUp(
    () => db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    ),
  );
  tearDown(() => db.close());

  Future<void> launch(WidgetTester tester, {DateTime? now}) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: day(15),
        now: now ?? day(15),
        utcOffset: Duration.zero,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> accept(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('paste-input')), tripPaste);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tab-trail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-sheet-open')));
    await tester.pumpAndSettle();
  }

  String textOf(Key key) =>
      (find
                  .descendant(
                    of: find.byKey(key),
                    matching: find.byType(Text),
                    matchRoot: true,
                  )
                  .evaluate()
                  .first
                  .widget
              as Text)
          .data!;

  String spokenCode() => textOf(const Key('trip-code')).replaceAll('\n', ' ');

  /// Out of the sheet, back to the paste box, and through the second door.
  Future<void> goToTheDoor(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('start-over')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('join-door')));
    await tester.pumpAndSettle();
  }

  Future<String> say(WidgetTester tester, String words) async {
    await tester.enterText(find.byKey(const Key('join-input')), words);
    await tester.pump();
    await tester.tap(find.byKey(const Key('join-button')));
    await tester.pumpAndSettle();
    return textOf(const Key('join-answer'));
  }

  testWidgets('the paste box is one of two doors', (tester) async {
    await launch(tester);

    // Surface 6a: most people arrive holding a code somebody told them, not
    // a plan to paste.
    await tester.tap(find.byKey(const Key('join-door')));
    await tester.pumpAndSettle();

    expect(textOf(const Key('join-headline')), 'What did they tell you?');
    expect(
      textOf(const Key('join-hint')),
      'Any order, any spelling that is close.',
    );
    // Nothing is judged until the words are said back.
    expect(find.byKey(const Key('join-answer')), findsNothing);
  });

  testWidgets('words that are not a code are refused in writing', (
    tester,
  ) async {
    await launch(tester);
    await tester.tap(find.byKey(const Key('join-door')));
    await tester.pumpAndSettle();

    expect(
      await say(tester, 'let me in please'),
      'That is not three words of a Cairn code. Any order, any spelling '
      'that is close — but it has to be the words you were told.',
    );
  });

  testWidgets('a code for a trip that is not on this phone says so, and '
      'changes nothing', (tester) async {
    await launch(tester);
    await tester.tap(find.byKey(const Key('join-door')));
    await tester.pumpAndSettle();

    // The honest Phase 2 state: the words read fine, and this phone has no
    // way to reach the trip they belong to. It does not guess whether that
    // trip exists, because nothing here can know.
    final code = '${InviteCode.words.first} ${InviteCode.words[1]} 42';
    expect(
      await say(tester, code),
      'Read as $code. That trip is on somebody else\'s phone, and Cairn '
      'cannot reach it yet — trips do not travel between phones. Nothing '
      'here has changed.',
    );

    // And no trip appeared out of it.
    expect(find.byKey(const Key('paste-input')), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('paste-input')), findsOneWidget);
  });

  testWidgets('this trip\'s own words are recognised, in any order and any '
      'spelling that is close', (tester) async {
    await launch(tester);
    await accept(tester);
    await openSheet(tester);
    final code = InviteCode.tryParse(spokenCode())!;
    await goToTheDoor(tester);

    const answer = 'Those are this trip\'s own words. You are already on it.';
    expect(await say(tester, code.spoken), answer);

    // Any order — three words said across a table do not arrive sorted.
    expect(
      await say(tester, '${code.secondWord} ${code.number} ${code.firstWord}'),
      answer,
    );

    // Any spelling that is close: the vocabulary is built so that a word one
    // edit away can only have been one word (cairn_model's InviteCode).
    final misheard =
        code.firstWord.substring(0, code.firstWord.length - 1) +
        (code.firstWord.endsWith('z') ? 'x' : 'z');
    expect(
      await say(tester, '$misheard ${code.secondWord} ${code.number}'),
      answer,
    );
  });

  testWidgets('a code said after the trip closed says the trip closed', (
    tester,
  ) async {
    // The plan ends on 15 June; the trip shuts fourteen days after that
    // (cairn_model's tripClosesAt), so by 6 July the words are dead.
    await launch(tester, now: DateTime.utc(2027, 7, 6));
    await accept(tester);

    // Read from the store rather than the sheet: an expired code is not
    // shown as live, which is the point.
    final code = (await db.readTripInviteCodes()).single.code;

    await openSheet(tester);
    await goToTheDoor(tester);

    expect(
      await say(tester, code),
      'That trip has closed. Its code died with it — the book it left behind '
      'does not.',
    );
  });

  testWidgets('retired words say they are retired, not that they are wrong', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    await openSheet(tester);
    final retired = spokenCode();

    await tester.tap(find.byKey(const Key('trip-code-new')));
    await tester.pumpAndSettle();
    expect(spokenCode(), isNot(retired));

    await goToTheDoor(tester);

    // A revoked code is a fact about the trip, which is why the store keeps
    // it: without the row this would be indistinguishable from words nobody
    // ever minted, and the person would be told to check their spelling
    // instead of to ask again.
    expect(
      await say(tester, retired),
      'Those words have been retired. Ask whoever invited you for the trip\'s '
      'code again.',
    );
  });
}
