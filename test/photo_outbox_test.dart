// A photograph durably leaves this phone: bytes first, row second, surviving
// a kill and a dead network.
//
// **The ordering rule is asserted mechanically in every test here, not just
// in the one about ordering.** [FakePool] models the two remote stores the
// way they actually relate — an object store keyed by object key, an index
// keyed by photo id — and fails the test itself if a row is ever recorded
// whose bytes have not landed, or a caption is ever written for a photo that
// was never recorded. Any driver change that breaks the invariant breaks the
// whole file.
//
// **A crash is a state, not an event.** Durability means every row of the
// crash matrix (the plan's §4.4) is testable as: write the durable state
// through the same store methods the driver uses, build a fresh [PhotoSync]
// over the same database, run one pass. No process is killed; nothing needs
// to be.
//
// Plain `test`s rather than `testWidgets`, like the itinerary's suite: the
// outbox is a fact about the seam, and nothing above the seam knows it
// exists. That also makes real file I/O and real (brief) waits safe here.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cairn_model/cairn_model.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/repositories/photo_repository.dart';
import 'package:cairn/repositories/photo_sync.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn/storage/remote/shared_facts.dart';

AppDatabase inMemory() => AppDatabase(
  DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
);

const anna = 'a0000000-0000-4000-8000-000000000001';

/// A stand-in for the shared pool's two remote stores, related the way the
/// real ones are: [objects] is R2 (bytes by key), [recorded] is the `photos`
/// index (rows by id), and a row may not exist without its bytes.
///
/// Deliberately dumb about everything else, like the itinerary's
/// [FakeServer]: it records what the phone did and answers what the test
/// scripted. The refusal semantics it does model are the load-bearing ones —
/// the flat claimed-id refusal at mint, and idempotent record — because the
/// outbox's crash matrix closes *through* them.
class FakePool implements SharedFacts {
  SharedFactsSession? auth = SharedFactsSession(
    accessToken: 'token',
    userId: MemberId(anna),
  );

  /// Set to make every network call fail the way a tunnel does.
  String? unreachable;

  /// Scripted verdicts, one per step. Each stands until the test clears it.
  String? mintRefuses;
  String? putRejects;
  String? recordRefuses;
  String? recordUnavailable;
  String? captionRefuses;

  /// Runs while the record insert is "in flight", so a test can land an edit
  /// mid-call and prove nothing is lost to the race.
  Future<void> Function()? onRecord;

  /// R2: what bytes sit at which key.
  final objects = <String, List<int>>{};

  /// The `photos` index. First insert wins, as `ignore-duplicates` makes it.
  final recorded = <String, RemotePhoto>{};

  /// The latest caption written per photo, through [writePhotoCaption] only.
  final captions = <String, String?>{};

  /// Every call the phone made, in order: (step, photoId).
  final calls = <(String, String)>[];

  /// Completes at the first record, so a test can wait for a push nobody
  /// drove by hand.
  final firstRecord = Completer<void>();

  void _gate() {
    if (unreachable != null) throw SharedFactsUnavailable(unreachable!);
  }

  @override
  Future<SharedFactsSession?> session() async => auth;

  @override
  Future<RemoteUploadTicket> photoUploadTicket({
    required TripId tripId,
    required String photoId,
    required String contentType,
    required int byteSize,
  }) async {
    _gate();
    calls.add(('mint', photoId));
    if (mintRefuses != null) throw SharedFactsRefused(mintRefuses!);
    // The flat claimed-id refusal, contributor included: a row is what
    // closes an original to further writes. Mirrored here because the crash
    // matrix's "PUT landed, 200 lost" row is safe precisely because no row
    // exists yet to make this fire.
    if (recorded.containsKey(photoId)) {
      throw const SharedFactsRefused(
        '409: a photo with this id already exists',
      );
    }
    final key = 'trips/${tripId.value}/photos/$photoId/original';
    return RemoteUploadTicket(
      uploadUrl: Uri.parse('https://r2.example/$key?signed=yes'),
      objectKey: key,
      contentType: contentType,
      byteSize: byteSize,
      expiresAt: DateTime.utc(2027, 6, 15, 12, 5),
    );
  }

  @override
  Future<void> putPhotoBytes(RemoteUploadTicket ticket, Uint8List bytes) async {
    _gate();
    calls.add(('put', ticket.objectKey.split('/')[3]));
    if (putRejects != null) throw UploadTicketRejected(putRejects!);
    objects[ticket.objectKey] = List.of(bytes);
  }

  @override
  Future<void> recordPhoto(RemotePhoto photo) async {
    _gate();
    calls.add(('record', photo.id));
    if (recordUnavailable != null) {
      throw SharedFactsUnavailable(recordUnavailable!);
    }
    if (recordRefuses != null) throw SharedFactsRefused(recordRefuses!);
    // THE invariant, asserted on every driver run in this file: a `photos`
    // row implies the object is at its key.
    if (!objects.containsKey(photo.r2ObjectKey)) {
      fail(
        'recordPhoto for ${photo.id} before its bytes landed at '
        '${photo.r2ObjectKey} — the bytes-first-row-second ordering is broken',
      );
    }
    await onRecord?.call();
    recorded.putIfAbsent(photo.id, () => photo);
    if (!firstRecord.isCompleted) firstRecord.complete();
  }

  @override
  Future<void> writePhotoCaption({
    required TripId tripId,
    required String photoId,
    required String? caption,
  }) async {
    _gate();
    calls.add(('caption', photoId));
    if (captionRefuses != null) throw SharedFactsRefused(captionRefuses!);
    if (!recorded.containsKey(photoId)) {
      fail(
        'writePhotoCaption for $photoId, which was never recorded — '
        'a caption has nothing to ride',
      );
    }
    captions[photoId] = caption;
  }

  // The itinerary half of the seam is TripSync's business and PhotoSync must
  // never speak it; reaching any of it here is a wrong number, not a stub.
  @override
  Future<RemoteTrip?> readTrip(TripId tripId) =>
      throw UnimplementedError('PhotoSync never reads the trip row');

  @override
  Future<void> createTrip(RemoteTripDraft draft) =>
      throw UnimplementedError('PhotoSync never creates the trip row');

  @override
  Future<RemoteItinerary> syncItinerary({
    required TripId tripId,
    required DateTime planRevisedAt,
    required List<RemoteDay> days,
    required DateTime pocketRevisedAt,
    required List<RemoteSetAside> setAside,
  }) => throw UnimplementedError('PhotoSync never syncs the itinerary');
}

/// A die that always lands the same way, so a backoff assertion can name an
/// exact instant. 0.5 puts the ±20% jitter at exactly 1.0×.
class FixedRandom implements Random {
  FixedRandom(this.value);
  final double value;

  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => (value * max).floor();
  @override
  bool nextBool() => value >= 0.5;
}

ConfirmedDay confirmed(int number, String place, {CalendarDate? date}) =>
    ConfirmedDay(number: number, date: date, place: place, stops: const []);

void main() {
  late AppDatabase db;
  late FakePool pool;
  late Directory frames;
  late DateTime clock;

  /// The bytes every test's frame carries, distinctive enough to compare.
  final frameBytes = Uint8List.fromList([0xff, 0xd8, 1, 2, 3, 4, 0xff, 0xd9]);

  String writeFrame([String name = 'frame.jpg']) {
    final file = File('${frames.path}/$name')..writeAsBytesSync(frameBytes);
    return file.path;
  }

  setUp(() {
    db = inMemory();
    pool = FakePool();
    frames = Directory.systemTemp.createTempSync('cairn-outbox');
    clock = DateTime.utc(2027, 6, 15, 12);
  });

  tearDown(() async {
    await db.close();
    frames.deleteSync(recursive: true);
  });

  PhotoStore store({String Function()? mintId}) =>
      PhotoStore(db, mintId: mintId ?? (() => 'photo-1'), now: () => clock);

  PhotoSync driver({Random? jitter}) => PhotoSync(
    database: db,
    facts: pool,
    now: () => clock,
    utcOffset: () => Duration.zero,
    jitter: jitter ?? FixedRandom(0.5),
  );

  /// The trip every test walks: started by Anna, 14–16 June 2027, every day
  /// dated unless [dated] says otherwise.
  Future<TripId> startTrip({bool dated = true}) async {
    final tripId = await db.startTripIfAbsent(
      starterId: anna,
      starterDisplayName: 'Anna',
    );
    await TripRepository(db).saveItinerary(
      ConfirmedItinerary(
        days: [
          confirmed(1, 'Tokyo', date: dated ? CalendarDate(2027, 6, 14) : null),
          confirmed(2, 'Kyoto', date: dated ? CalendarDate(2027, 6, 15) : null),
          confirmed(3, 'Nara', date: dated ? CalendarDate(2027, 6, 16) : null),
        ],
        keptAside: const [],
      ),
      at: DateTime.utc(2027, 6, 1),
    );
    return tripId;
  }

  Future<PooledPhoto> keepOne({
    String? word,
    String? path,
    int dayNumber = 1,
    String Function()? mintId,
  }) => store(mintId: mintId).keep(
    dayNumber: dayNumber,
    contributor: MemberId(anna),
    takenAt: DateTime.utc(2027, 6, 14, 9),
    origin: PhotoOrigin.pinged,
    filePath: path ?? writeFrame(),
    word: word,
  );

  group('the happy path', () {
    test('a kept photograph crosses — mint, put, record, then an empty '
        'outbox', () async {
      final tripId = await startTrip();
      await keepOne(word: 'first light');

      await driver().syncNow();

      expect(pool.calls, [
        ('mint', 'photo-1'),
        ('put', 'photo-1'),
        ('record', 'photo-1'),
      ]);
      final row = pool.recorded['photo-1']!;
      expect(row.tripId, tripId.value);
      expect(row.contributorId, anna);
      expect(row.dayNumber, 1);
      expect(row.tripDayIso, '2027-06-14', reason: 'the calendar rides along');
      expect(row.caption, 'first light');
      expect(row.contentType, 'image/jpeg');
      expect(row.byteSize, frameBytes.length);
      expect(row.capturedAtIso, '2027-06-14T09:00:00.000Z');
      expect(
        pool.objects[row.r2ObjectKey],
        frameBytes,
        reason: 'the row must name the key the bytes actually sit under',
      );
      expect(
        await db.readOutboxRows(),
        isEmpty,
        reason:
            'terminal success is row deletion; an empty outbox means '
            'nothing pending',
      );
    });

    test('the photo row and its outbox row are one transaction', () async {
      await startTrip();
      // Poison the second insert: an outbox row already holds the id the
      // minter is about to mint, so `keep` must fail — and if the two
      // inserts were two transactions, the photo row would survive the
      // failure as a photograph that silently never leaves.
      await db.customStatement(
        "insert into photo_outbox (photo_id, state, next_attempt_at_utc_iso) "
        "values ('photo-1', 'queued', '2027-06-15T12:00:00.000Z')",
      );

      await expectLater(keepOne(), throwsA(anything));

      expect(
        await db.readPhotos(),
        isEmpty,
        reason: 'the failed outbox insert must take the photo row with it',
      );
    });

    test('an undated day uploads anyway — no form in front of the camera, '
        'ever', () async {
      // The settled photo-day-key rule's own constraint: the day *number* is
      // the photograph's home, so a plan nobody has dated withholds nothing
      // from the pool.
      await startTrip(dated: false);
      await keepOne(dayNumber: 2);

      await driver().syncNow();

      final row = pool.recorded['photo-1']!;
      expect(row.dayNumber, 2);
      expect(row.tripDayIso, isNull, reason: 'no date is no guess');
      expect(await db.readOutboxRows(), isEmpty);
    });
  });

  group('the crash matrix, replayed from durable state', () {
    test('queued with nothing remote: a fresh driver runs the full '
        'attempt', () async {
      await startTrip();
      await keepOne();
      // The "crash": the enqueue survived, the driver that would have pushed
      // did not. A new process is just a new PhotoSync over the same rows.
      await driver().syncNow();
      expect(pool.recorded, contains('photo-1'));
      expect(await db.readOutboxRows(), isEmpty);
    });

    test('a dead ticket goes back to queued and a fresh ticket is minted — '
        'never surrender', () async {
      await startTrip();
      await keepOne();
      pool.putRejects = '403: SignatureDoesNotMatch';

      await driver().syncNow();

      var outbox = (await db.readOutboxRows()).single;
      expect(outbox.state, 'queued');
      expect(outbox.attempts, 1);
      expect(outbox.lastError, contains('SignatureDoesNotMatch'));
      expect(
        outbox.nextAttemptAtUtcIso.compareTo(clock.toIso8601String()) > 0,
        isTrue,
        reason: 'a failed attempt is not retried in the same breath',
      );
      expect(pool.calls.where((c) => c.$1 == 'record'), isEmpty);

      // Not due yet: a pass now must leave it alone.
      pool.putRejects = null;
      await driver().syncNow();
      expect(pool.calls.where((c) => c.$1 == 'mint'), hasLength(1));

      // Due: a *fresh* ticket is minted — the dead one was discarded, never
      // stored, never reused.
      clock = DateTime.parse(outbox.nextAttemptAtUtcIso);
      await driver().syncNow();
      expect(pool.calls.where((c) => c.$1 == 'mint'), hasLength(2));
      expect(pool.recorded, contains('photo-1'));
      expect(await db.readOutboxRows(), isEmpty);
    });

    test('a PUT that landed whose 200 was lost re-mints and re-PUTs the '
        'same bytes, and is still signed', () async {
      final tripId = await startTrip();
      await keepOne();
      // The bytes made it; the acknowledgement did not; the state is still
      // `queued`. Safe *because* no row exists yet — the claimed-id refusal
      // the fake mirrors cannot fire, which is the ordering rule earning its
      // keep a second time.
      pool.objects['trips/${tripId.value}/photos/photo-1/original'] = List.of(
        frameBytes,
      );

      await driver().syncNow();

      expect(pool.calls.map((c) => c.$1), ['mint', 'put', 'record']);
      expect(pool.recorded, contains('photo-1'));
      expect(await db.readOutboxRows(), isEmpty);
    });

    test('uploaded: recovery goes straight to the record — no mint, no PUT, '
        'no bytes needed', () async {
      final tripId = await startTrip();
      await keepOne(word: 'kept word');
      final key = 'trips/${tripId.value}/photos/photo-1/original';
      await db.markOutboxUploaded(
        photoId: 'photo-1',
        r2ObjectKey: key,
        byteSize: frameBytes.length,
      );
      pool.objects[key] = List.of(frameBytes);
      // The frame file is gone — a crash-then-cleared-cache shaped world.
      // Recovery must not need it: `uploaded` durably means "the bytes are
      // at this key, this big".
      File((await db.readPhotos()).single.filePath!).deleteSync();

      await driver().syncNow();

      expect(pool.calls, [('record', 'photo-1')]);
      final row = pool.recorded['photo-1']!;
      expect(row.r2ObjectKey, key);
      expect(row.byteSize, frameBytes.length);
      expect(row.caption, 'kept word');
      expect(await db.readOutboxRows(), isEmpty);
    });

    test('record landed, ack lost: the replay is a silent success', () async {
      final tripId = await startTrip();
      await keepOne();
      final key = 'trips/${tripId.value}/photos/photo-1/original';
      await db.markOutboxUploaded(
        photoId: 'photo-1',
        r2ObjectKey: key,
        byteSize: frameBytes.length,
      );
      pool.objects[key] = List.of(frameBytes);
      final already = RemotePhoto(
        id: 'photo-1',
        tripId: tripId.value,
        contributorId: anna,
        r2ObjectKey: key,
        contentType: 'image/jpeg',
        byteSize: frameBytes.length,
        dayNumber: 1,
        updatedAtIso: '2027-06-15T11:59:00.000Z',
      );
      pool.recorded['photo-1'] = already;

      await driver().syncNow();

      expect(
        pool.recorded['photo-1'],
        same(already),
        reason:
            'ignore-duplicates: the first insert wins, the replay is a '
            'no-op',
      );
      expect(await db.readOutboxRows(), isEmpty);
    });

    test('record refused — the trip closed between the PUT and the row — is '
        'terminal, with the reason kept', () async {
      final tripId = await startTrip();
      await keepOne();
      final key = 'trips/${tripId.value}/photos/photo-1/original';
      await db.markOutboxUploaded(
        photoId: 'photo-1',
        r2ObjectKey: key,
        byteSize: frameBytes.length,
      );
      pool.objects[key] = List.of(frameBytes);
      pool.recordRefuses = '403: this trip is closed';

      await driver().syncNow();

      final outbox = (await db.readOutboxRows()).single;
      expect(outbox.state, 'refused');
      expect(outbox.lastError, contains('closed'));

      // Refused is refused: a later pass owes it nothing.
      pool.recordRefuses = null;
      pool.calls.clear();
      await driver().syncNow();
      expect(pool.calls, isEmpty);
    });

    test('unavailable after the bytes landed keeps the uploaded mark, and '
        'recovery skips the store', () async {
      await startTrip();
      await keepOne();
      pool.recordUnavailable = 'the server did not answer in time';

      await driver().syncNow();

      final outbox = (await db.readOutboxRows()).single;
      expect(
        outbox.state,
        'uploaded',
        reason: 'durable progress survives the pass that could not finish',
      );
      expect(outbox.attempts, 0, reason: 'a tunnel is nobody\'s fault');

      pool.recordUnavailable = null;
      pool.calls.clear();
      await driver().syncNow();
      expect(pool.calls, [
        ('record', 'photo-1'),
      ], reason: 'never re-mint once past the PUT');
      expect(await db.readOutboxRows(), isEmpty);
    });
  });

  group('later and no are not the same answer', () {
    test('unreachable stops the whole pass and penalises nothing', () async {
      await startTrip();
      await keepOne(mintId: () => 'photo-1');
      await store(mintId: () => 'photo-2').keep(
        dayNumber: 1,
        contributor: MemberId(anna),
        takenAt: DateTime.utc(2027, 6, 14, 10),
        origin: PhotoOrigin.pinged,
        filePath: writeFrame('second.jpg'),
      );
      pool.unreachable = 'no route to the server';

      await driver().syncNow();

      final rows = await db.readOutboxRows();
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row.state, 'queued');
        expect(row.attempts, 0);
        expect(
          row.nextAttemptAtUtcIso,
          clock.toIso8601String(),
          reason: 'offline leaves every item exactly as it stood',
        );
      }

      // The train leaves the tunnel; the poll's next pass delivers both.
      pool.unreachable = null;
      await driver().syncNow();
      expect(pool.recorded.keys, containsAll(['photo-1', 'photo-2']));
    });

    test('refused at mint is terminal', () async {
      await startTrip();
      await keepOne();
      pool.mintRefuses = '403: not a member of this trip';

      await driver().syncNow();

      final outbox = (await db.readOutboxRows()).single;
      expect(outbox.state, 'refused');
      expect(outbox.lastError, contains('not a member'));
      expect(pool.calls.where((c) => c.$1 == 'put'), isEmpty);
    });

    test('a week-later phone against a trip the server closed hears no, '
        'once, and stops', () async {
      // The local plan never learned its dates, so nothing local archives
      // it; the server's close-plus-grace check is the real deadline, and
      // `refused` is how it is relayed.
      await startTrip(dated: false);
      await keepOne();
      pool.mintRefuses = '403: this trip is closed';

      await driver().syncNow();

      expect((await db.readOutboxRows()).single.state, 'refused');
      pool.calls.clear();
      await driver().syncNow();
      expect(pool.calls, isEmpty);
    });
  });

  group("the trip's own standing", () {
    test('an archived trip pushes nothing at all — not even a mint', () async {
      await startTrip();
      await keepOne();
      // Last day 16 June, sealed at midnight into the 17th, grace over
      // 20 June. Ten days later is a record, and a record costs no network.
      clock = DateTime.utc(2027, 6, 26);

      await driver().syncNow();

      expect(pool.calls, isEmpty);
      expect(
        (await db.readOutboxRows()).single.state,
        'queued',
        reason: 'stopped, not refused: nobody ruled, the phone declined',
      );
    });

    test('the grace still takes late photographs', () async {
      await startTrip();
      await keepOne();
      // A day past the trip's end, well inside the 72 hours whose whole
      // point is exactly this push.
      clock = DateTime.utc(2027, 6, 18);

      await driver().syncNow();

      expect(pool.recorded, contains('photo-1'));
    });
  });

  group('the backoff', () {
    Future<PhotoOutboxData> failOnceAt(int priorAttempts) async {
      await db.delayOutboxRetry(
        photoId: 'photo-1',
        attempts: priorAttempts,
        nextAttemptAtUtcIso: clock.toIso8601String(),
        lastError: 'seeded',
      );
      pool.putRejects = '403: expired';
      await driver().syncNow();
      return (await db.readOutboxRows()).single;
    }

    test('the meter climbs by doubling and the jitter spreads it', () async {
      await startTrip();
      await keepOne();

      // FixedRandom(0.5) puts the ±20% spread at exactly 1.0×, so the
      // arithmetic is nameable: 30s × 2^attempts.
      var row = await failOnceAt(0);
      expect(row.attempts, 1);
      expect(
        DateTime.parse(row.nextAttemptAtUtcIso).difference(clock),
        const Duration(seconds: 60),
      );

      row = await failOnceAt(3);
      expect(row.attempts, 4);
      expect(
        DateTime.parse(row.nextAttemptAtUtcIso).difference(clock),
        const Duration(seconds: 480),
      );
    });

    test('the ceiling is an hour, and the spread stays inside its '
        'bounds', () async {
      await startTrip();
      await keepOne();

      // Deep into the meter: 30s × 2^11 would be 17 hours; the cap holds it
      // at one.
      final capped = await failOnceAt(10);
      expect(
        DateTime.parse(capped.nextAttemptAtUtcIso).difference(clock),
        const Duration(seconds: 3600),
      );

      // The jitter's floor: 0.8× the ceiling, never sooner.
      await db.close();
      db = inMemory();
      await startTrip();
      await keepOne();
      await db.delayOutboxRetry(
        photoId: 'photo-1',
        attempts: 10,
        nextAttemptAtUtcIso: clock.toIso8601String(),
        lastError: 'seeded',
      );
      pool.putRejects = '403: expired';
      await PhotoSync(
        database: db,
        facts: pool,
        now: () => clock,
        utcOffset: () => Duration.zero,
        jitter: FixedRandom(0.0),
      ).syncNow();
      expect(
        DateTime.parse((await db.readOutboxRows()).single.nextAttemptAtUtcIso)
            .difference(clock),
        const Duration(seconds: 2880),
        reason:
            '0.8 × 3600s: eight phones on one hotel wifi must not '
            'retry in lockstep',
      );
    });

    test('the meter never terminates: a phone that failed fifty times is '
        'still delivering', () async {
      await startTrip();
      await keepOne();
      await db.delayOutboxRetry(
        photoId: 'photo-1',
        attempts: 50,
        nextAttemptAtUtcIso: clock.toIso8601String(),
        lastError: 'a long week',
      );

      await driver().syncNow();

      expect(
        pool.recorded,
        contains('photo-1'),
        reason:
            'the real deadline is the server\'s close-plus-grace, '
            'never an attempt count',
      );
    });
  });

  group('the caption rides, or follows', () {
    Future<void> deliver() async {
      await driver().syncNow();
      expect(pool.recorded, contains('photo-1'));
    }

    test('a word written while the photo is still queued rides the insert '
        'and pushes nothing of its own', () async {
      await startTrip();
      await keepOne();
      await store().writeWord(PhotoId('photo-1'), 'written while waiting');

      expect(
        (await db.readOutboxRows()).single.state,
        'queued',
        reason: 'the record reads the word at record time; no second debt',
      );
      await deliver();
      expect(pool.recorded['photo-1']!.caption, 'written while waiting');
      expect(pool.calls.where((c) => c.$1 == 'caption'), isEmpty);
      expect(await db.readOutboxRows(), isEmpty);
    });

    test(
      'a word written after the record follows as one caption push',
      () async {
        final tripId = await startTrip();
        await keepOne();
        await deliver();

        await store().writeWord(PhotoId('photo-1'), 'hindsight');
        final debt = (await db.readOutboxRows()).single;
        expect(debt.state, 'caption');

        await driver().syncNow();
        expect(pool.captions['photo-1'], 'hindsight');
        expect(pool.calls.where((c) => c.$1 == 'caption'), hasLength(1));
        expect(await db.readOutboxRows(), isEmpty);
        expect(
          pool.recorded['photo-1']!.tripId,
          tripId.value,
          reason: 'the photograph itself is untouched by its caption',
        );
      },
    );

    test('two edits before the push collapse into one push, saying the '
        'later word', () async {
      await startTrip();
      await keepOne();
      await deliver();

      await store().writeWord(PhotoId('photo-1'), 'first thought');
      await store().writeWord(PhotoId('photo-1'), 'second thought');
      expect(await db.readOutboxRows(), hasLength(1));

      await driver().syncNow();
      expect(pool.captions['photo-1'], 'second thought');
      expect(pool.calls.where((c) => c.$1 == 'caption'), hasLength(1));
    });

    test('an edit landing while the record is in flight is not lost', () async {
      await startTrip();
      await keepOne(word: 'as taken');
      pool.onRecord = () =>
          store().writeWord(PhotoId('photo-1'), 'typed mid-flight');

      await driver().syncNow();

      // The settle saw the word move under the insert and turned the row
      // into a caption debt instead of deleting it.
      expect((await db.readOutboxRows()).single.state, 'caption');
      pool.onRecord = null;
      await driver().syncNow();
      expect(pool.captions['photo-1'], 'typed mid-flight');
      expect(await db.readOutboxRows(), isEmpty);
    });

    test('a caption push the server refuses is terminal for the push and '
        'only the push', () async {
      await startTrip();
      await keepOne();
      await deliver();
      await store().writeWord(PhotoId('photo-1'), 'too late');
      pool.captionRefuses = '403: this trip is closed';

      await driver().syncNow();

      expect((await db.readOutboxRows()).single.state, 'refused');
      expect(
        pool.recorded,
        contains('photo-1'),
        reason: 'the photograph crossed; only its late word did not',
      );
    });

    test('a word on a photograph that never crossed has nothing to ride, '
        'and stays refused', () async {
      await startTrip();
      await keepOne();
      pool.mintRefuses = '403: not a member of this trip';
      await driver().syncNow();
      expect((await db.readOutboxRows()).single.state, 'refused');

      await store().writeWord(PhotoId('photo-1'), 'a word for nobody');

      final row = (await db.readOutboxRows()).single;
      expect(row.state, 'refused', reason: 'refused is refused');
      pool.mintRefuses = null;
      pool.calls.clear();
      await driver().syncNow();
      expect(pool.calls, isEmpty);
      expect(
        (await db.readPhotos()).single.word,
        'a word for nobody',
        reason: 'the local word is still the person\'s to keep',
      );
    });
  });

  group('the pool dies with the trip', () {
    test('deleteTripWholesale takes the outbox rows with it', () async {
      await startTrip();
      await keepOne();
      expect(await db.readOutboxRows(), hasLength(1));

      await db.deleteTripWholesale();

      expect(await db.readOutboxRows(), isEmpty);
      expect(await db.readPhotos(), isEmpty);
    });
  });

  group('the driver is driven by the outbox, and only the outbox', () {
    test('a capture triggers its own push with nobody asking', () async {
      await startTrip();
      final sync = driver()..start();
      addTearDown(sync.stop);

      await keepOne();
      await pool.firstRecord.future.timeout(const Duration(seconds: 5));

      expect(pool.recorded, contains('photo-1'));
    });

    test('a photo row written without an outbox row — the pull, one day — '
        'wakes nothing', () async {
      await startTrip();
      final sync = driver()..start();
      addTearDown(sync.stop);
      // Let the startup settle so the assertion below is about the insert.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final before = pool.calls.length;

      await db.insertPhoto((
        id: 'someone-elses',
        dayNumber: 1,
        contributorId: 'b0000000-0000-4000-8000-000000000002',
        takenAtUtcIso: '2027-06-14T10:00:00.000Z',
        origin: 'pinged',
        word: null,
        filePath: null,
        contentType: 'image/jpeg',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        pool.calls.length,
        before,
        reason:
            'the driver watches photo_outbox alone: applying a pull '
            'must never re-trigger the push',
      );
    });
  });

  group('the v8 migration', () {
    test('a v7 phone upgrades with its photographs intact and no debts '
        'invented', () async {
      Future<void> windBackToV7(AppDatabase db) async {
        await db.customStatement('DROP TABLE photo_outbox');
        await db.customStatement(
          'ALTER TABLE sync_states DROP COLUMN photos_updated_cursor',
        );
        // SQLite cannot tighten a column in place any more than Drift can
        // loosen one: rebuild `photos` in its v7 shape — `file_path` not
        // null, no `content_type`.
        await db.customStatement(
          'CREATE TABLE photos_v7 ('
          'id TEXT NOT NULL, day_number INTEGER NOT NULL, '
          'contributor_id TEXT NOT NULL, taken_at_utc_iso TEXT NOT NULL, '
          'origin TEXT NOT NULL, word TEXT, file_path TEXT NOT NULL, '
          'PRIMARY KEY (id))',
        );
        await db.customStatement(
          'INSERT INTO photos_v7 SELECT id, day_number, contributor_id, '
          'taken_at_utc_iso, origin, word, file_path FROM photos',
        );
        await db.customStatement('DROP TABLE photos');
        await db.customStatement('ALTER TABLE photos_v7 RENAME TO photos');
        await db.customStatement('PRAGMA user_version = 7');
      }

      final dir = Directory.systemTemp.createTempSync('cairn-outbox-upgrade');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/cairn.sqlite');

      var upgraded = AppDatabase(
        DatabaseConnection(
          NativeDatabase(file),
          closeStreamsSynchronously: true,
        ),
      );
      await upgraded.startTripIfAbsent(
        starterId: anna,
        starterDisplayName: 'Anna',
      );
      await upgraded.insertPhoto((
        id: 'photo-from-before',
        dayNumber: 1,
        contributorId: anna,
        takenAtUtcIso: '2027-06-14T09:00:00.000Z',
        origin: 'pinged',
        word: 'an old word',
        filePath: '/somewhere/frame.jpg',
        contentType: null,
      ));
      await windBackToV7(upgraded);
      await upgraded.close();

      upgraded = AppDatabase(
        DatabaseConnection(
          NativeDatabase(file),
          closeStreamsSynchronously: true,
        ),
      );
      addTearDown(upgraded.close);

      final photo = (await upgraded.readPhotos()).single;
      expect(photo.id, 'photo-from-before');
      expect(photo.word, 'an old word');
      expect(photo.filePath, '/somewhere/frame.jpg');
      expect(photo.contentType, isNull);
      expect(
        await upgraded.readOutboxRows(),
        isEmpty,
        reason:
            'no build that could capture has shipped; the migration '
            'enqueues nothing',
      );
      expect((await upgraded.readSyncState()).photosUpdatedCursor, isNull);

      // And the upgraded schema does everything v8 promises: a new keep
      // writes both rows, and a null file path is storable.
      await PhotoStore(upgraded, mintId: () => 'photo-after').keep(
        dayNumber: 1,
        contributor: MemberId(anna),
        takenAt: DateTime.utc(2027, 6, 14, 10),
        origin: PhotoOrigin.pinged,
        filePath: '${dir.path}/new-frame.jpg',
      );
      expect(await upgraded.readOutboxRows(), hasLength(1));
      await upgraded.insertPhoto((
        id: 'pulled-row',
        dayNumber: 2,
        contributorId: anna,
        takenAtUtcIso: '2027-06-15T09:00:00.000Z',
        origin: 'pinged',
        word: null,
        filePath: null,
        contentType: 'image/heic',
      ));
      expect(
        (await upgraded.readPhotos()).where((p) => p.filePath == null),
        hasLength(1),
      );
    });
  });
}
