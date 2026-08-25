// The trip's own surface, its three words, and the party the pings are dealt
// across — tested through the real stack: a plan pasted and accepted into
// Drift, which is what starts a trip, and everything read back off the
// Trail's title.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app.
//
// Two things shape these tests, as they shape pool_test.dart. Every tab stays
// alive in the tree but the ones you are not looking at are *offstage*, and
// finders skip offstage widgets — so every test walks in through the tab bar.
// And a phone can only ever write one member row into its own roster, so the
// party of eight the product is actually for is seeded at the read seam
// (`bootstrapApp(membership:)`), exactly as the Pool seeds a pool.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn_model/cairn_model.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/membership_repository.dart';
import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Three dated days: 14, 15 and 17 June 2027.
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Thu 17 June 2027 - Osaka
- Dotonbori
''';

/// A plan accepted with every date still open.
const dateOpenPaste = '''
Day 1 - Tokyo
- Senso-ji

Day 2 - Kyoto
- Fushimi Inari
''';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

/// A trip id of the shape the phone actually mints
/// (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md), stood up here by
/// hand because these tests seed the read side of the seam and never start a
/// trip through the store. The bytes are arbitrary; that it is a real uuid is
/// not — an id that would not survive a round trip through `trips.id` is not
/// the thing these tests are standing in for.
final aTrip = TripId.mint(List.filled(16, 0xa7));

/// One photo of [by]'s, on day 1.
PooledPhoto photoBy(String by) => PooledPhoto(
  ref: PhotoRef(
    id: PhotoId('p-$by'),
    dayNumber: 1,
    contributor: MemberId(by),
    takenAt: DateTime.utc(2027, 6, 14, 10),
    origin: PhotoOrigin.pinged,
  ),
  localPath: null,
);

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

  Future<void> launch(
    WidgetTester tester, {
    required DateTime today,
    List<PooledPhoto> pool = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: today,
        now: today,
        utcOffset: Duration.zero,
        photos: InMemoryPhotoPool(pool),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> accept(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('paste-input')), text);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  /// Paste, accept, and open the trip's sheet off the Trail's title.
  Future<void> openSheet(
    WidgetTester tester, {
    required DateTime today,
    String paste = tripPaste,
    List<PooledPhoto> pool = const [],
  }) async {
    await launch(tester, today: today, pool: pool);
    await accept(tester, paste);
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

  /// The three words as they are said, off the sheet's stacked card.
  String spokenCode() => textOf(const Key('trip-code')).replaceAll('\n', ' ');

  // ------------------------------------------------------------- the roster

  testWidgets('accepting a plan starts the trip, with you on it and words to '
      'say', (tester) async {
    await openSheet(tester, today: day(15));

    // One person, and the app says who they are rather than inventing a name.
    expect(textOf(const Key('trip-person-0-name')), 'You');
    // A fact beside a name, never a rank — there is no other role anywhere.
    expect(textOf(const Key('trip-person-0-note')), 'started it');
    expect(find.byKey(const Key('trip-person-1')), findsNothing);

    // The honest state of a roster on a phone that cannot be told about
    // anybody else: written, not an empty list and not a spinner.
    expect(
      textOf(const Key('trip-alone')),
      'Just you so far. Nobody else\'s phone can reach this trip yet.',
    );

    // The code exists from the moment the trip does — a code you have to
    // summon first is no use while somebody is holding your phone.
    expect(InviteCode.tryParse(spokenCode()), isNotNull);
  });

  testWidgets('the trip is unnamed until somebody names it', (tester) async {
    await openSheet(tester, today: day(15));

    // Nothing guesses a name out of the plan.
    expect(textOf(const Key('trip-name')), 'This trip');

    await tester.tap(find.byKey(const Key('trip-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('trip-name-input')),
      'Japan, June',
    );
    await tester.tap(find.byKey(const Key('trip-name-save')));
    await tester.pumpAndSettle();

    expect(textOf(const Key('trip-name')), 'Japan, June');

    // And the Trail grows the eyebrow the design draws above its headline,
    // now that there is a trip name to put there.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(textOf(const Key('trail-trip-name')), 'JAPAN, JUNE');
  });

  testWidgets('the span is the plan\'s own, not a guess', (tester) async {
    await openSheet(tester, today: day(15));
    expect(textOf(const Key('trip-span')), '14–17 June · 3 days');
  });

  // --------------------------------------------------------------- the code

  testWidgets('the code dies with the trip, grace and all', (tester) async {
    await openSheet(tester, today: day(15));

    // 17 June is the last day; it seals at midnight, and the fourteen-day
    // grace runs from there (cairn_model's tripClosesAt).
    expect(
      textOf(const Key('trip-code-expiry')),
      'Dies with the trip, after 1 July.',
    );
  });

  testWidgets('a plan with no dates cannot say when its code dies, and does '
      'not pretend to', (tester) async {
    await openSheet(tester, today: day(15), paste: dateOpenPaste);

    expect(
      textOf(const Key('trip-code-expiry')),
      'Dies when the trip closes. This plan has no dates yet.',
    );
  });

  testWidgets('what the words can and cannot do is written on the sheet', (
    tester,
  ) async {
    await openSheet(tester, today: day(15));

    // The Phase 2 gap, stated plainly rather than implied by a button that
    // quietly does nothing.
    expect(
      textOf(const Key('trip-code-note')),
      'Say it out loud — that is the whole trick. Cairn cannot carry anyone '
      'here from their phone yet, so for now the words are the invitation '
      'and nothing arrives.',
    );
  });

  testWidgets('new words retire the old ones', (tester) async {
    await openSheet(tester, today: day(15));
    final first = spokenCode();

    await tester.tap(find.byKey(const Key('trip-code-new')));
    await tester.pumpAndSettle();

    final second = spokenCode();
    expect(second, isNot(first));
    expect(InviteCode.tryParse(second), isNotNull);
  });

  // ------------------------------------------------------------- deleting it

  testWidgets('a trip holding only your own photos is yours to delete', (
    tester,
  ) async {
    await openSheet(tester, today: day(15), pool: [photoBy(localMemberId)]);

    expect(
      textOf(const Key('trip-delete-line')),
      'Takes the plan and every photo row with it. It cannot be undone.',
    );

    await tester.tap(find.byKey(const Key('trip-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-delete-confirm')));
    await tester.pumpAndSettle();

    // The trip is gone, so the app is back where a phone with no trip starts.
    expect(find.byKey(const Key('paste-input')), findsOneWidget);
  });

  testWidgets('once it holds somebody else\'s photos nobody can delete it', (
    tester,
  ) async {
    await openSheet(tester, today: day(15), pool: [photoBy('jonas')]);

    // Refused in writing, and the control is absent rather than greyed out.
    expect(
      textOf(const Key('trip-delete-line')),
      'It holds somebody else\'s photos now, so nobody can — whoever started '
      'it included.',
    );
    expect(find.byKey(const Key('trip-delete')), findsNothing);
  });

  // ------------------------------------------------- the party, and the deal

  group('the party the day is dealt across', () {
    /// Eight people, which is the size the product is for.
    List<Member> eight() => [
      for (final (i, name) in [
        'You',
        'Jonas',
        'Tomas',
        'Ava',
        'Mira',
        'Sam',
        'Ines',
        'Bo',
      ].indexed)
        Member(
          id: MemberId(i == 0 ? localMemberId : name.toLowerCase()),
          displayName: name,
          joinedOnDay: 1,
        ),
    ];

    ProviderContainer containerWith(TripMembership? trip) {
      final container = ProviderContainer(
        overrides: [
          membershipRepositoryProvider.overrideWithValue(
            InMemoryMembership(trip),
          ),
          savedItineraryProvider.overrideWith(
            (ref) => Stream.value(
              TripPlan(
                days: [
                  for (final n in [1, 2, 3])
                    PlanDay(number: n, date: day(13 + n), stops: const []),
                ],
              ),
            ),
          ),
          tripUtcOffsetProvider.overrideWithValue(Duration.zero),
          nowProvider.overrideWithValue(day(14)),
        ],
      );
      addTearDown(container.dispose);
      // Riverpod disposes a provider nobody is listening to, and a stream
      // provider disposed while still loading never completes its future.
      // The app always has a widget listening; a container test has to say
      // so itself.
      container.listen(tripMembershipProvider, (_, _) {});
      container.listen(savedItineraryProvider, (_, _) {});
      return container;
    }

    test('the roster is the party, and eight people get eight different '
        'minutes', () async {
      final container = containerWith(
        TripMembership(
          tripId: aTrip,
          startedBy: MemberId(localMemberId),
          members: eight(),
        ),
      );
      await container.read(tripMembershipProvider.future);
      await container.read(savedItineraryProvider.future);

      final party = container.read(tripPartyProvider);
      expect(party, isNotNull);
      expect(party!.memberIds, hasLength(8));

      // The whole promise of the offline deal: every phone derives the same
      // assignment for everyone, so no two people are called at once. It is
      // only worth asserting against a real party, which is why the roster
      // had to become real before this test could exist.
      for (final date in [day(14), day(15), day(16)]) {
        final minutes = <DateTime>{};
        for (final member in eight()) {
          final pings = pingsForPlan(
            plan: container.read(savedItineraryProvider).value,
            party: party,
            utcOffset: Duration.zero,
            memberId: member.id.value,
            tripId: aTrip,
          );
          for (final ping in pings) {
            if (ping.at.difference(date).inDays.abs() <= 1 &&
                ping.at.day == date.day) {
              minutes.add(ping.at);
            }
          }
        }
        expect(
          minutes,
          hasLength(8),
          reason: 'eight slots on ${date.day} June',
        );
      }
    });

    test('no trip is no party, and no party is no pings', () async {
      final container = containerWith(null);
      await container.read(tripMembershipProvider.future);
      await container.read(savedItineraryProvider.future);

      // Not a party of one standing in: an app with no trip has no pings,
      // and scheduling for an invented member would call a person who is
      // not there.
      expect(container.read(tripPartyProvider), isNull);
      expect(container.read(pingScheduleProvider), isEmpty);
    });

    test('a party of one is still a party', () async {
      final container = containerWith(
        TripMembership(
          tripId: aTrip,
          startedBy: MemberId(localMemberId),
          members: [
            Member(
              id: MemberId(localMemberId),
              displayName: 'You',
              joinedOnDay: 1,
            ),
          ],
        ),
      );
      await container.read(tripMembershipProvider.future);
      await container.read(savedItineraryProvider.future);

      expect(container.read(tripPartyProvider), isA<tm.Party>());
      expect(container.read(pingScheduleProvider), hasLength(3));
    });
  });
}
