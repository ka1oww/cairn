// The photo storage write path, tested through the real stack: the seam's
// keep/read/word surface over a real Drift database, plus the schema v2 → v3
// upgrade that adds the table to a phone that already holds an itinerary.
//
// This is the path everything photographic hangs off — the day page's
// timeline, the Pool, the Trail's filled node, and eventually the upload to
// R2 — so what is asserted here is the shape of a photo rather than any one
// screen's use of it.
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart';

void main() {
  late AppDatabase db;
  late PhotoStore photos;
  var minted = 0;

  setUp(() {
    minted = 0;
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    photos = PhotoStore(db, mintId: () => 'photo-${++minted}');
  });
  tearDown(() => db.close());

  DateTime at(int hour, [int minute = 0]) =>
      DateTime.utc(2027, 6, 14, hour, minute);

  Future<PooledPhoto> keep({
    int day = 1,
    String by = 'me',
    required DateTime taken,
    String? word,
    PhotoOrigin origin = PhotoOrigin.pinged,
  }) => photos.keep(
    dayNumber: day,
    contributor: MemberId(by),
    takenAt: taken,
    origin: origin,
    filePath: '/frames/${taken.microsecondsSinceEpoch}.png',
    word: word,
  );

  test('a kept photo round-trips through the seam unchanged', () async {
    final kept = await keep(day: 4, taken: at(14, 50), word: 'we CAUGHT it');

    final pool = await photos.watchTripPhotos().first;
    expect(pool, hasLength(1));
    final read = pool.single;
    expect(read.ref.id, kept.ref.id);
    expect(read.ref.dayNumber, 4);
    expect(read.ref.contributor, MemberId('me'));
    expect(read.ref.takenAt, at(14, 50));
    expect(read.ref.takenAt.isUtc, isTrue);
    expect(read.ref.origin, PhotoOrigin.pinged);
    expect(read.word, 'we CAUGHT it');
    expect(read.localPath, kept.localPath);
  });

  test('a photo the app took is credited as pinged, not derived', () async {
    await keep(taken: at(11, 40));
    final read = (await photos.watchTripPhotos().first).single;
    // The origin is what says how much the hour is worth: the app took this
    // one, so its instant is known rather than read off EXIF.
    expect(read.ref.origin, PhotoOrigin.pinged);
  });

  test(
    'the pool comes back in time order, so a late photo sits at its hour',
    () async {
      await keep(taken: at(8, 40));
      await keep(taken: at(23, 40)); // the late answer
      await keep(taken: at(13, 5));

      final pool = await photos.watchTripPhotos().first;
      expect(
        [for (final p in pool) p.ref.takenAt.hour],
        [8, 13, 23],
        reason: 'a photo taken late lands at its true hour, not at the end',
      );
    },
  );

  test('a blank line is no word at all, not an empty one', () async {
    await keep(taken: at(9), word: '   ');
    expect((await photos.watchTripPhotos().first).single.word, isNull);
  });

  test('a written line is stored exactly as typed, uncorrected', () async {
    await keep(taken: at(9), word: 'we CAUGHT it, ran the whole platform');
    expect(
      (await photos.watchTripPhotos().first).single.word,
      'we CAUGHT it, ran the whole platform',
      reason: 'caps stay caps and nothing is tidied — design round 10, 18b',
    );
  });

  test('the word stays writable, and a blank line clears it', () async {
    final kept = await keep(taken: at(9), word: 'first thought');

    await photos.writeWord(kept.ref.id, 'second thought');
    expect(
      (await photos.watchTripPhotos().first).single.word,
      'second thought',
    );

    await photos.writeWord(kept.ref.id, '');
    expect((await photos.watchTripPhotos().first).single.word, isNull);
  });

  test('photos accumulate; keeping one never replaces another', () async {
    await keep(day: 1, taken: at(9));
    await keep(day: 1, taken: at(10));
    await keep(day: 2, taken: at(11));
    expect(await photos.watchTripPhotos().first, hasLength(3));
  });

  test('a day reads only its own photos', () async {
    await keep(day: 1, taken: at(9));
    await keep(day: 2, taken: at(10));
    await keep(day: 2, taken: at(11));

    expect(await photos.watchPhotosForDay(2).first, hasLength(2));
    expect(await photos.watchPhotosForDay(3).first, isEmpty);
  });

  test('the pool stream re-emits when a photo is kept', () async {
    final seen = <int>[];
    final sub = photos.watchTripPhotos().listen(
      (pool) => seen.add(pool.length),
    );
    await pumpEventQueue();
    await keep(taken: at(9));
    await pumpEventQueue();
    await sub.cancel();
    expect(seen, [0, 1]);
  });

  test('a non-UTC instant is refused at the seam', () async {
    expect(
      () => photos.keep(
        dayNumber: 1,
        contributor: MemberId('me'),
        takenAt: DateTime(2027, 6, 14, 11, 40), // local — carries a zone
        origin: PhotoOrigin.pinged,
        filePath: '/frames/x.png',
      ),
      throwsArgumentError,
      reason: 'a local DateTime carries the device timezone into the trip',
    );
  });

  test('a phone that already holds an itinerary gains the table without '
      'losing the plan', () async {
    // The upgrade from schema 2 is the one path a real phone will take, and
    // its branch is easy to get wrong: v1's branch calls createAll(), which
    // already builds the photos table, so it must not fall through into
    // v3's createTable.
    final dir = Directory.systemTemp.createTempSync('cairn-db');
    final file = File('${dir.path}/cairn.sqlite');
    addTearDown(() => dir.deleteSync(recursive: true));

    final before = AppDatabase(
      DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true),
    );
    await before.replaceItinerary(
      days: [(number: 1, dateIso: '2027-06-14', place: 'Tokyo')],
      stops: [
        (
          dayNumber: 1,
          position: 0,
          text: 'Senso-ji',
          timeIso: null,
          kind: null,
          areaText: null,
          areaSource: null,
        ),
      ],
      setAsides: [],
      nowUtcIso: '2027-06-14T09:00:00.000Z',
    );
    // Wind the phone back to the itinerary slice's schema: everything a
    // later version added has to go, not only the version number, or the
    // upgrade re-adds what is already there.
    await before.customStatement('DROP TABLE photo_outbox');
    await before.customStatement('DROP TABLE photos');
    await before.customStatement('DROP TABLE sync_states');
    await before.customStatement(
      'ALTER TABLE itinerary_days DROP COLUMN revised_at_utc_iso',
    );
    await before.customStatement(
      'ALTER TABLE itinerary_stops DROP COLUMN kind',
    );
    await before.customStatement(
      'ALTER TABLE itinerary_stops DROP COLUMN area_text',
    );
    await before.customStatement(
      'ALTER TABLE itinerary_stops DROP COLUMN area_source',
    );
    await before.customStatement('DROP TABLE app_preferences');
    await before.customStatement('PRAGMA user_version = 2');
    await before.close();

    final after = AppDatabase(
      DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true),
    );
    addTearDown(after.close);

    expect(await after.watchItineraryDays().first, hasLength(1));
    expect(await after.readItineraryStops(), hasLength(1));

    await PhotoStore(after, mintId: () => 'upgraded').keep(
      dayNumber: 1,
      contributor: MemberId('me'),
      takenAt: at(11, 40),
      origin: PhotoOrigin.pinged,
      filePath: '/frames/x.png',
    );
    expect(await after.readPhotos(), hasLength(1));
  });

  test('every photo the seam keeps is a photo the store already had', () async {
    // Guards the one thing an id minter can silently break: two photos
    // sharing an id would have the second overwrite the first.
    await keep(taken: at(9));
    await keep(taken: at(10));
    final ids = [
      for (final p in await photos.watchTripPhotos().first) p.ref.id,
    ];
    expect(ids.toSet(), hasLength(2));
  });
}
