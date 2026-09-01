// The captain's ruling — "sure let them rename it" — walked end to end, from
// the gesture a person actually makes to the fact the trip's other phones
// would read.
//
// Everything else about the rename is already pinned one layer at a time:
// `membership_test.dart` taps the sheet's Rename and reads the new word back
// off the screen, `shared_facts_sync_test.dart` drives `TripSync` over a fake
// server from `db.renameTrip`, `postgrest_adapter_test.dart` pins the wire
// shape of `sync_trip_name`, and `supabase/tests/rls_probe.py` is the
// authority on who the *server* lets rename. What none of them joins up is
// the seam between the first and the second: a rename typed into the trip
// sheet reaching the shared trip row, and somebody else's rename arriving
// back on this screen. That join is what this file is for.
//
// closeStreamsSynchronously is load-bearing here for the reason
// paste_confirm_flow_test.dart's header gives; read that before writing any
// test that pumps the app.
import 'dart:typed_data';

import 'package:cairn_model/cairn_model.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/device_time_zone.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/itinerary_sync.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn/storage/remote/shared_facts.dart';

const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Thu 17 June 2027 - Osaka
- Dotonbori
''';

/// A reading of now inside the plan above, so the trip is underway rather
/// than archived when the sync asks where it stands.
DateTime duringTheTrip() => DateTime.utc(2027, 6, 15, 12);

/// The shared trip row, as the only thing standing in for Supabase here.
///
/// It merges nothing — `rls_probe.py` owns the server's half of last-write-
/// wins, and a second copy of that rule in a Dart fake is the thing to refuse
/// in review. It records what the phone offered and holds whatever the test
/// says the trip is called.
class FakeServer implements SharedFacts {
  RemoteTrip? trip;
  final namePushes = <RemoteTripName>[];

  @override
  Future<SharedFactsSession?> session() async =>
      SharedFactsSession(accessToken: 'token', userId: trip?.startedBy ?? MemberId('me'));

  @override
  Future<RemoteTrip?> readTrip(TripId tripId) async => trip;

  @override
  Future<void> createTrip(RemoteTripDraft draft) async {
    trip = RemoteTrip(
      id: draft.id,
      name: draft.name,
      nameRevisedAt: draft.nameRevisedAt,
      startedBy: draft.createdBy,
      members: [
        RemoteMember(
          id: draft.createdBy,
          displayName: 'You',
          joinedAt: DateTime.utc(2027, 6, 1),
        ),
      ],
    );
  }

  @override
  Future<RemoteTripName> syncTripName({
    required TripId tripId,
    required String name,
    required DateTime revisedAt,
  }) async {
    final answer = RemoteTripName(name: name, revisedAt: revisedAt);
    namePushes.add(answer);
    final current = trip!;
    trip = RemoteTrip(
      id: current.id,
      name: name,
      nameRevisedAt: revisedAt,
      startedBy: current.startedBy,
      members: current.members,
    );
    return answer;
  }

  /// Somebody else's phone renaming the trip, with their clock on it.
  void renamedByAnotherMember(String name, DateTime at) {
    final current = trip!;
    trip = RemoteTrip(
      id: current.id,
      name: name,
      nameRevisedAt: at,
      startedBy: current.startedBy,
      members: current.members,
    );
  }

  @override
  Future<RemoteItinerary> syncItinerary({
    required TripId tripId,
    required DateTime planRevisedAt,
    required List<RemoteDay> days,
    required DateTime pocketRevisedAt,
    required List<RemoteSetAside> setAside,
  }) async => RemoteItinerary(
    planRevisedAt: planRevisedAt,
    pocketRevisedAt: pocketRevisedAt,
    days: days,
    setAside: setAside,
  );

  // TripSync never speaks to the photo half of the seam.
  @override
  Future<RemoteUploadTicket> photoUploadTicket({
    required TripId tripId,
    required String photoId,
    required String contentType,
    required int byteSize,
  }) => throw UnimplementedError();

  @override
  Future<void> putPhotoBytes(RemoteUploadTicket ticket, Uint8List bytes) =>
      throw UnimplementedError();

  @override
  Future<void> recordPhoto(RemotePhoto photo) => throw UnimplementedError();

  @override
  Future<void> writePhotoCaption({
    required TripId tripId,
    required String photoId,
    required String? caption,
  }) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  late FakeServer server;

  setUp(() {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    server = FakeServer();
  });
  tearDown(() => db.close());

  TripSync syncOverTheSamePhone() => TripSync(
    database: db,
    facts: server,
    now: duringTheTrip,
    tripRow: tripRowFor(const FixedTimeZone('Asia/Tokyo')),
  );

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

  /// Paste, accept and open the trip's sheet off the Trail's title — the
  /// route a person takes to the Rename button.
  Future<void> openSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: DateTime.utc(2027, 6, 15),
        now: DateTime.utc(2027, 6, 15),
        utcOffset: Duration.zero,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('paste-input')), tripPaste);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('tab-trail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-sheet-open')));
    await tester.pumpAndSettle();
  }

  Future<void> renameOnScreen(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const Key('trip-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('trip-name-input')), name);
    await tester.tap(find.byKey(const Key('trip-name-save')));
    await tester.pumpAndSettle();
  }

  testWidgets('a rename typed on the trip sheet reaches the shared trip, and '
      'another member\'s rename comes back to the screen', (tester) async {
    await openSheet(tester);

    // The trip exists on the server before anybody names it: the placeholder
    // is what an unnamed trip publishes, and it is not a name.
    await syncOverTheSamePhone().syncNow();
    expect(server.trip, isNotNull);
    expect(server.trip!.name, unnamedTripPlaceholder);
    expect(textOf(const Key('trip-name')), 'This trip');

    // The gesture: Rename, type, save. This is a member renaming a trip they
    // did not have to have started -- the phone's model has always been flat
    // and the server now agrees (0014_member_trip_rename.sql).
    await renameOnScreen(tester, 'Japan, June');
    expect(textOf(const Key('trip-name')), 'Japan, June');

    // ...and it leaves the phone, with the clock that authored it, which is
    // what every other phone on the trip would read.
    await syncOverTheSamePhone().syncNow();
    expect(server.namePushes.single.name, 'Japan, June');
    expect(server.trip!.name, 'Japan, June');
    final pushedAt = server.namePushes.single.revisedAt;

    // The other direction, which is the point of a shared name: somebody
    // else's phone renames the trip, with a newer clock, and this screen
    // says the new word without anybody touching it.
    server.renamedByAnotherMember(
      'Japan together',
      pushedAt.add(const Duration(minutes: 5)),
    );
    await syncOverTheSamePhone().syncNow();
    await tester.pumpAndSettle();

    expect(textOf(const Key('trip-name')), 'Japan together');
    // And a name this phone merely *received* is not pushed back at it.
    expect(server.namePushes, hasLength(1));
  });

  testWidgets('a stale rename from this phone loses, and the screen is '
      'corrected rather than left saying the wrong thing', (tester) async {
    await openSheet(tester);
    await syncOverTheSamePhone().syncNow();

    // Two phones type at once. The other one's word carries the later clock,
    // so it wins -- and the server hands the winner back on the very call
    // this phone made to offer its own.
    await renameOnScreen(tester, 'Typed here first');
    final theirs = DateTime.now().toUtc().add(const Duration(hours: 1));
    server.renamedByAnotherMember('Typed there, later', theirs);

    await syncOverTheSamePhone().syncNow();
    await tester.pumpAndSettle();

    expect(textOf(const Key('trip-name')), 'Typed there, later');
    expect(server.trip!.name, 'Typed there, later');
    // The losing phone never pushed over the winner.
    expect(server.namePushes, isEmpty);
  });
}
