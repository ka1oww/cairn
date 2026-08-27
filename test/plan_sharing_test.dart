// The second half of defect D3: the app saying, out loud, whether the plan
// has actually reached the trip's own copy.
//
// The first half — the sync being silently off on every ordinary build — is
// covered where the sync is, in `shared_facts_sync_test.dart`. This file is
// about the thing that was missing even when the sync worked: a person
// holding the phone had no way at all to find out. Every screen looked
// identical whether the plan had gone up or was sitting privately on one
// device, and would have gone on looking identical the first time a tunnel or
// a refusal got in the way.
//
// Two layers, tested at the level each belongs to. The sentence is a pure
// function of the standing and the plan (`planSharingFor`), so it is asserted
// directly and every branch is reachable in one line. That it *renders* is a
// widget test through the real stack, because a sentence nothing draws is the
// defect all over again.
//
// closeStreamsSynchronously is load-bearing here for the reason
// paste_confirm_flow_test.dart's header explains; read that before writing
// any test that pumps the app.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/app_state/trip_settings.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/itinerary_sync.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// Three dated days: a plan that can be published.
const datedPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari
''';

/// A plan accepted with every date still open — the one remaining reason a
/// plan honestly cannot go up.
const undatedPaste = '''
Day 1 - Tokyo
- Senso-ji

Day 2 - Kyoto
- Fushimi Inari
''';

TripPlan planOf(List<DateTime?> dates) => TripPlan(
  days: [
    for (final (index, date) in dates.indexed)
      PlanDay(number: index + 1, date: date, stops: const []),
  ],
);

void main() {
  // ------------------------------------------------------------ the sentence

  group('what the trip says about where its plan is', () {
    test('says nothing at all until something has reconciled', () {
      // Neither "it is up" nor "it is not" is knowable yet, and Cairn does
      // not fill a blank with a guess or a spinner.
      expect(planSharingFor(null, planOf([DateTime.utc(2027, 6, 14)])), isNull);
      expect(
        planSharingFor(SyncStanding.noTrip, null),
        isNull,
        reason: 'no trip means no surface asking',
      );
    });

    test('says nothing on a closed trip, which is never reconciled', () {
      // The sync returns before any round trip on an archive
      // (docs/decisions/2026-08-26-the-ending.md), so this phone genuinely
      // does not know where the plan got to. The sheet's ending line already
      // says what an archive is.
      expect(
        planSharingFor(SyncStanding.archived, planOf([DateTime.utc(2027, 6, 14)])),
        isNull,
      );
    });

    test('says so plainly when the plan is up', () {
      final sharing = planSharingFor(
        SyncStanding.synced,
        planOf([DateTime.utc(2027, 6, 14)]),
      )!;
      expect(sharing.reached, isTrue);
      expect(sharing.line, 'The plan is up. It is not only on this phone any more.');
      expect(
        sharing.mark,
        isNull,
        reason: 'the Trail says something only when there is something to say',
      );
    });

    test('an undated plan is told what to do about it', () {
      final sharing = planSharingFor(
        SyncStanding.awaitingTripRow,
        planOf([null, null]),
      )!;
      expect(sharing.reached, isFalse);
      expect(sharing.mark, 'Only on this phone.');
      expect(
        sharing.line,
        'The plan is only on this phone, and it stays here until the trip has '
        'dates. Put one on the first day and the rest follow.',
      );
      // Nothing technical reaches a person: the log's own words for this
      // standing are "the trip clock is not known yet", which is exactly the
      // sentence this app does not say.
      expect(sharing.line, isNot(contains('clock')));
    });

    test('a plan dated up to an open last day says which day it wants', () {
      final sharing = planSharingFor(
        SyncStanding.awaitingTripRow,
        planOf([DateTime.utc(2027, 6, 14), null]),
      )!;
      expect(
        sharing.line,
        'The plan is only on this phone, and it stays here until the last day '
        'has a date.',
      );
    });

    test('a fully dated plan that still cannot go up blames no date', () {
      // Unreachable on an iPhone, where the zone always answers. Written
      // because the alternative to a sentence is an empty line in a state
      // nobody predicted.
      final sharing = planSharingFor(
        SyncStanding.awaitingTripRow,
        planOf([DateTime.utc(2027, 6, 14), DateTime.utc(2027, 6, 15)]),
      )!;
      expect(sharing.line, contains('what hours this trip keeps'));
    });

    test('a tunnel says the plan is safe and will go up by itself', () {
      final sharing = planSharingFor(
        SyncStanding.offline,
        planOf([DateTime.utc(2027, 6, 14)]),
      )!;
      expect(sharing.reached, isFalse);
      expect(sharing.line, contains('the next time you have signal'));
    });

    test('a refusal says nothing has been lost', () {
      final sharing = planSharingFor(
        SyncStanding.refused,
        planOf([DateTime.utc(2027, 6, 14)]),
      )!;
      expect(sharing.reached, isFalse);
      expect(sharing.line, contains('nothing here has been lost'));
    });

    test('a phone with nowhere to put it says that too', () {
      final sharing = planSharingFor(
        SyncStanding.dormant,
        planOf([DateTime.utc(2027, 6, 14)]),
      )!;
      expect(sharing.reached, isFalse);
      expect(sharing.mark, 'Only on this phone.');
    });

    test('every standing that is not up carries the Trail\'s short line', () {
      // The mark is what makes the fact *visible* rather than findable, so a
      // standing that grows a sentence and forgets the mark is a regression.
      for (final standing in [
        SyncStanding.awaitingTripRow,
        SyncStanding.offline,
        SyncStanding.refused,
        SyncStanding.dormant,
      ]) {
        final sharing = planSharingFor(standing, planOf([null]))!;
        expect(sharing.reached, isFalse, reason: '$standing');
        expect(sharing.mark, isNotNull, reason: '$standing');
      }
    });
  });

  // ------------------------------------------------------------ the surfaces

  group('the trip says it on screen', () {
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

    /// Paste [paste], accept it, and stand on the Trail with the sync having
    /// said [standing] — which is what `bootstrapApp(sharing:)` is for.
    Future<void> walkToTheTrail(
      WidgetTester tester, {
      required SyncStanding standing,
      String paste = datedPaste,
    }) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        bootstrapApp(
          database: db,
          today: DateTime.utc(2027, 6, 14),
          now: DateTime.utc(2027, 6, 14),
          utcOffset: Duration.zero,
          sharing: Stream.value(SyncOutcome(standing)),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('paste-input')), paste);
      await tester.tap(find.byKey(const Key('read-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('accept-button')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('tab-trail')));
      await tester.pumpAndSettle();
    }

    Future<void> openSheet(WidgetTester tester) async {
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

    testWidgets('a plan that has not gone up is visible without looking for '
        'it', (tester) async {
      await walkToTheTrail(
        tester,
        standing: SyncStanding.awaitingTripRow,
        paste: undatedPaste,
      );

      // On the Trail, where a person is actually standing.
      expect(textOf(const Key('trail-sharing')), 'Only on this phone.');

      // And in full, one tap away, with what to do about it.
      await openSheet(tester);
      expect(
        textOf(const Key('trip-sharing')),
        'The plan is only on this phone, and it stays here until the trip has '
        'dates. Put one on the first day and the rest follow.',
      );
    });

    testWidgets('a plan that has gone up says so, and marks nothing',
        (tester) async {
      await walkToTheTrail(tester, standing: SyncStanding.synced);

      expect(find.byKey(const Key('trail-sharing')), findsNothing);
      await openSheet(tester);
      expect(
        textOf(const Key('trip-sharing')),
        'The plan is up. It is not only on this phone any more.',
      );
    });

    testWidgets('a tunnel is said in Cairn\'s words and not a machine\'s',
        (tester) async {
      await walkToTheTrail(tester, standing: SyncStanding.offline);

      expect(textOf(const Key('trail-sharing')), 'Only on this phone.');
      await openSheet(tester);
      final line = textOf(const Key('trip-sharing'));
      expect(line, contains('goes up on its own'));
      for (final leak in ['sync', 'server', 'error', 'HTTP', 'null']) {
        expect(line.toLowerCase(), isNot(contains(leak.toLowerCase())));
      }
    });

    testWidgets('a suite where nothing reconciles claims neither way',
        (tester) async {
      // The default: `bootstrapApp` passes no sharing stream, nothing is
      // ever said, and both surfaces stay silent rather than asserting that
      // the plan did or did not go up.
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        bootstrapApp(
          database: db,
          today: DateTime.utc(2027, 6, 14),
          now: DateTime.utc(2027, 6, 14),
          utcOffset: Duration.zero,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('paste-input')), datedPaste);
      await tester.tap(find.byKey(const Key('read-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('accept-button')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('tab-trail')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('trail-sharing')), findsNothing);
      await openSheet(tester);
      expect(find.byKey(const Key('trip-sharing')), findsNothing);
    });
  });
}
