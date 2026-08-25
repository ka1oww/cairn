// The gate, as this phone answers it: today's page stays shut to you until
// you have put something into it, and every day that is over is already open.
//
// The rule itself belongs to `cairn_model` and is pinned there
// (`packages/cairn_model/test/gate_test.dart`, which is where the deliberate
// "shut forever" test used to live). What this file pins is the app's half:
// that the one derivation in `lib/app_state/day_gate.dart` reads the plan, the
// pool and today correctly, and that the surface which actually draws
// photographs obeys it.
//
// The Pool is that surface, and today it is the only one — the day page's
// photo timeline and the Trail's filled node are not built, so there is
// nothing else for a gate to withhold. Both read the same provider when they
// land; a second copy of the rule is the thing to refuse in review.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app. And every tab but the one you are standing on is
// offstage, so each test walks in through the tab bar.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn_model/cairn_model.dart';

import 'package:cairn/app_state/day_gate.dart';
import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/pool_view.dart';
import 'package:cairn/app_state/trip_providers.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// Three dated days: 14, 15 and 17 June 2027. Standing on the 15th, day 1 is
/// behind us, day 2 is the day being lived and day 3 is still ahead.
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Thu 17 June 2027 - Osaka
- Dotonbori
''';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

/// Somebody else on the trip. Nothing in the app can produce one of these yet
/// — every photo this phone takes is credited to [localMemberId] — which is
/// exactly why the gate has to be tested with one: an eight-person pool is
/// what it exists for.
final someoneElse = MemberId('jonas');

PooledPhoto photo(
  String id, {
  required int onDay,
  required int hour,
  MemberId? by,
  String? path,
}) =>
    PooledPhoto(
      ref: PhotoRef(
        id: PhotoId(id),
        dayNumber: onDay,
        contributor: by ?? someoneElse,
        takenAt: DateTime.utc(2027, 6, 13 + onDay, hour),
        origin: PhotoOrigin.pinged,
      ),
      localPath: path,
    );

PooledPhoto mine(String id, {required int onDay, required int hour}) =>
    photo(id, onDay: onDay, hour: hour, by: MemberId(localMemberId));

File writeTinyPng() {
  final file = File(
    '${Directory.systemTemp.createTempSync('cairn_gate').path}/tile.png',
  );
  file.writeAsBytesSync(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
    'hQGAhKmMIQAAAABJRU5ErkJggg==',
  ));
  addTearDown(() => file.parent.deleteSync(recursive: true));
  return file;
}

/// A plan shaped like [tripPaste], for the derivation tests that need no app.
const plan = TripPlan(days: [
  PlanDay(number: 1, date: null, stops: []),
  PlanDay(number: 2, date: null, stops: []),
  PlanDay(number: 3, date: null, stops: []),
]);

TripPlan datedPlan() => TripPlan(days: [
      PlanDay(number: 1, date: day(14), place: 'Tokyo', stops: const []),
      PlanDay(number: 2, date: day(15), place: 'Kyoto', stops: const []),
      PlanDay(number: 3, date: day(17), place: 'Osaka', stops: const []),
    ]);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      )));
  tearDown(() => db.close());

  Future<void> arriveInPool(
    WidgetTester tester, {
    required DateTime today,
    List<PooledPhoto> pool = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bootstrapApp(
      database: db,
      today: today,
      photos: InMemoryPhotoPool(pool),
    ));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('paste-input')), tripPaste);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('tab-pool')));
    await tester.pumpAndSettle();
  }

  String textOf(Key key) => (find
          .descendant(
            of: find.byKey(key),
            matching: find.byType(Text),
            matchRoot: true,
          )
          .evaluate()
          .first
          .widget as Text)
      .data!;

  // ------------------------------------------------------ today, in the app

  testWidgets('today is shut to you until you have put something into it',
      (tester) async {
    final file = writeTinyPng();
    await arriveInPool(tester, today: day(15), pool: [
      photo('theirs', onDay: 2, hour: 9, path: file.path),
    ]);

    // Shut: the picture is not drawn, and the tile says why rather than
    // looking like a photo that failed to load.
    expect(find.byKey(const Key('pool-photo-theirs-withheld')), findsOneWidget);
    expect(find.byKey(const Key('pool-photo-theirs-image')), findsNothing);
    expect(find.byKey(const Key('pool-photo-theirs-awaiting')), findsNothing);
    expect(textOf(const Key('pool-day-2-shut')), 'Shut until you add yours.');

    // And the shape of the day is still on show: it is there, it is named,
    // it is dated, and the count over the pool still counts it.
    expect(find.byKey(const Key('pool-day-2')), findsOneWidget);
    expect(textOf(const Key('pool-day-2-title')), 'Tuesday, Kyoto');
    expect(textOf(const Key('pool-day-2-detail')), 'today');
    expect(textOf(const Key('pool-count')), '1 photo');
  });

  testWidgets('adding yours opens today', (tester) async {
    final file = writeTinyPng();
    await arriveInPool(tester, today: day(15), pool: [
      photo('theirs', onDay: 2, hour: 9, path: file.path),
      mine('ours', onDay: 2, hour: 11),
    ]);

    expect(find.byKey(const Key('pool-day-2-shut')), findsNothing);
    expect(find.byKey(const Key('pool-photo-theirs-image')), findsOneWidget);
    expect(find.byKey(const Key('pool-photo-theirs-withheld')), findsNothing);
    // Ours has no bytes on disk, so it is the waiting state and not the
    // withheld one — the two are different things and stay different keys.
    expect(find.byKey(const Key('pool-photo-ours-awaiting')), findsOneWidget);
  });

  testWidgets('a day that is over is open, answered or not', (tester) async {
    // The settled rule, and the one the removed "shut forever" test denied:
    // day 1 went by without this phone answering it, and on the 15th it is
    // ours to look at anyway.
    final file = writeTinyPng();
    await arriveInPool(tester, today: day(15), pool: [
      photo('yesterday', onDay: 1, hour: 10, path: file.path),
    ]);

    expect(find.byKey(const Key('pool-day-1-shut')), findsNothing);
    expect(find.byKey(const Key('pool-photo-yesterday-image')), findsOneWidget);
  });

  testWidgets('the day you are living is the only shut one', (tester) async {
    final file = writeTinyPng();
    await arriveInPool(tester, today: day(15), pool: [
      photo('before', onDay: 1, hour: 10, path: file.path),
      photo('now', onDay: 2, hour: 9, path: file.path),
    ]);

    expect(find.byKey(const Key('pool-day-1-shut')), findsNothing);
    expect(find.byKey(const Key('pool-day-2-shut')), findsOneWidget);
  });

  // ------------------------------------------------------- the derivation

  group('where a day of the plan stands', () {
    test('behind today, today, and ahead of today', () {
      final dated = datedPlan();
      expect(standingOfPlanDay(planDayOf(dated, 1), day(15)),
          DayStanding.walked);
      expect(standingOfPlanDay(planDayOf(dated, 2), day(15)),
          DayStanding.inProgress);
      expect(standingOfPlanDay(planDayOf(dated, 3), day(15)),
          DayStanding.notYet);
    });

    test('a day with no date is not the day you are living, so it is open',
        () {
      // Today has a date; a day with none cannot be it, and the gate is about
      // today alone. A day the plan no longer claims lands here too.
      expect(standingOfPlanDay(planDayOf(plan, 2), day(15)),
          DayStanding.walked);
      expect(standingOfPlanDay(null, day(15)), DayStanding.walked);
    });
  });

  group('the gate this phone answers', () {
    final me = MemberId(localMemberId);

    test('today is shut, and contributing is the only thing that opens it',
        () {
      final dated = datedPlan();
      GateState gate(List<PooledPhoto> photos) => gateForPlanDay(
            number: 2,
            planDay: planDayOf(dated, 2),
            today: day(15),
            photos: photos,
            viewer: me,
          );

      expect(gate(const []), GateState.shutAwaitingContribution);
      expect(gate([photo('a', onDay: 2, hour: 9)]),
          GateState.shutAwaitingContribution,
          reason: 'somebody else answering is not you answering');
      expect(gate([mine('b', onDay: 2, hour: 9)]),
          GateState.openedByContribution);
    });

    test('a photo of another day does not open today', () {
      final dated = datedPlan();
      expect(
        gateForPlanDay(
          number: 2,
          planDay: planDayOf(dated, 2),
          today: day(15),
          photos: [mine('yesterday', onDay: 1, hour: 9)],
          viewer: me,
        ),
        GateState.shutAwaitingContribution,
      );
    });

    test('a day that is over needs nothing of you', () {
      final dated = datedPlan();
      expect(
        gateForPlanDay(
          number: 1,
          planDay: planDayOf(dated, 1),
          today: day(15),
          photos: const [],
          viewer: me,
        ),
        GateState.openBecauseTheDayIsOver,
      );
    });

    test('a day still ahead is shut, and not for want of a contribution', () {
      final dated = datedPlan();
      expect(
        gateForPlanDay(
          number: 3,
          planDay: planDayOf(dated, 3),
          today: day(15),
          photos: const [],
          viewer: me,
        ),
        GateState.shutUntilTheDayArrives,
      );
    });
  });

  group('a shut gate is a gate and not a curtain', () {
    test('the screen is not handed the path to a withheld photograph', () {
      final view = poolViewFor(
        datedPlan(),
        [photo('theirs', onDay: 2, hour: 9, path: '/tmp/somewhere.png')],
        day(15),
        viewer: MemberId(localMemberId),
      )!;

      final today = view.days.single;
      expect(today.isOpen, isFalse);
      expect(today.photos.single.imagePath, isNull,
          reason: 'the bytes are on this phone, and still not offered');
      // The day itself is not hidden: a shut gate shows the shape of the day.
      expect(today.number, 2);
      expect(today.detail, 'today');
      expect(view.countLabel, '1 photo');
    });

    test('an open day still offers the path', () {
      final view = poolViewFor(
        datedPlan(),
        [photo('yesterday', onDay: 1, hour: 9, path: '/tmp/somewhere.png')],
        day(15),
        viewer: MemberId(localMemberId),
      )!;

      expect(view.days.single.isOpen, isTrue);
      expect(view.days.single.photos.single.imagePath, '/tmp/somewhere.png');
    });
  });
}
