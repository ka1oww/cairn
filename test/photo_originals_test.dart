// The pool keeps the original, and every size the app shows is derived.
//
// The decision is `docs/decisions/2026-08-22-grill-round-one.md` §3, and it
// is the one the trip's full-size handover promise rests on: whatever the
// camera wrote is what the pool holds, byte for byte, forever. What the rule
// costs is measured in `docs/storage-and-cost.md`.
//
// Two claims, tested apart because they fail apart:
//
//  1. **The original survives the whole walk.** A frame taken, kept, and then
//     drawn by the Pool is the same bytes on disk at the end as at the start.
//     This is the claim a well-meant "just downscale before storing" would
//     break, and nothing else in the suite would notice — every other test
//     asserts on rows, and the row is fine either way.
//  2. **No surface decodes an original at full size.** Showing a photograph
//     small is a decode-time derivation, not a stored variant. A tile that
//     forgets it looks exactly right and costs about 48 MB of image cache
//     per 12-megapixel frame, which is how a grid of them kills the app.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app. The camera is faked and writes synchronously for
// the reason capture_flow_test.dart's header gives.
import 'dart:io';

import 'package:cairn_model/cairn_model.dart' show TripId;
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'package:cairn/app_state/camera_source.dart';
import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/stand_in_frame.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/screens/photo_frame.dart';
import 'package:cairn/storage/drift/app_database.dart';

const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Kyoto
- Fushimi Inari
''';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

/// The trip id the flow's database is told to mint (see
/// docs/decisions/2026-08-25-the-trip-mints-its-own-id.md).
final testTripId = TripId.mint(List.filled(16, 0x5a));

tm.Ping pingOn(DateTime date) => tm
    .dayAssignment(
      tripId: testTripId.value,
      party: tm.Party(const [localMemberId]),
      day: tm.TripDay(date: date, utcOffset: Duration.zero),
    )
    .pingFor(localMemberId)!;

/// A camera that writes one real image file, and remembers exactly what it
/// wrote so a later assertion can compare against it rather than against an
/// idea of it.
class RecordingCamera implements CameraSource {
  RecordingCamera(this.directory, {required this.takenAtUtc});

  final Directory directory;
  final DateTime takenAtUtc;

  /// The bytes handed out, by path. The point of comparison.
  final Map<String, List<int>> written = {};

  @override
  Future<CapturedFrame> takeOne() async {
    final path = '${directory.path}/frame-${written.length + 1}.png';
    final bytes = standInFrameBytes(written.length + 1);
    File(path).writeAsBytesSync(bytes);
    written[path] = bytes;
    return CapturedFrame(path: path, takenAtUtc: takenAtUtc);
  }

  @override
  Future<void> discard(String path) async {}
}

void main() {
  // -------------------------------------------------------------------------
  group('the display rule', () {
    // A pure function, so the rule can be argued with directly rather than
    // read off a widget tree.

    test('a box is decoded at its own size in device pixels', () {
      expect(displayDecodeWidth(logicalEdge: 110, devicePixelRatio: 3), 330);
      expect(displayDecodeWidth(logicalEdge: 393, devicePixelRatio: 3), 1179);
    });

    test('a fractional box rounds up, never down', () {
      // Down would mean a photograph drawn very slightly soft, which is a
      // worse trade than one extra row of pixels.
      expect(displayDecodeWidth(logicalEdge: 110.4, devicePixelRatio: 2), 221);
    });

    test('no box can ask for a decode larger than the ceiling', () {
      expect(
        displayDecodeWidth(logicalEdge: 4000, devicePixelRatio: 3),
        maxDisplayDecodeEdge,
      );
    });

    test('an unbounded box falls back to the ceiling, not to nothing', () {
      // A photograph that will not draw is worse than one decoded larger
      // than it needed to be.
      expect(
        displayDecodeWidth(logicalEdge: double.infinity, devicePixelRatio: 3),
        maxDisplayDecodeEdge,
      );
      expect(
        displayDecodeWidth(logicalEdge: 0, devicePixelRatio: 3),
        maxDisplayDecodeEdge,
      );
    });

    test('a degenerate pixel ratio is read as one, and never as zero', () {
      expect(displayDecodeWidth(logicalEdge: 120, devicePixelRatio: 0), 120);
    });

    test('the ceiling is a backstop, not the working size', () {
      // If this ever fails, a full-screen decode is being clamped, and the
      // ceiling — not the layout — is deciding how sharp a photo looks.
      expect(maxDisplayDecodeEdge, greaterThan(430 * 3));
    });

    test('the ceiling stands at 2560 device pixels', () {
      // Pinned literally on purpose: 2560 is a deliberate trade of image
      // cache against sharpness headroom (see the constant's doc comment),
      // and drift in either direction should fail loudly here rather than
      // slide through a relative assertion like the ones above.
      expect(maxDisplayDecodeEdge, 2560);
    });

    // The fit is not a detail. Reading the wrong edge is silent in both
    // directions — soft photographs one way, a several-times-oversized
    // decode the other.
    test('a covered box is governed by its longest edge', () {
      // Cover scales until the box is filled, so a landscape frame in a
      // tall box is drawn wider than the box itself.
      expect(governingEdge(BoxFit.cover, 110, 300), 300);
      expect(governingEdge(BoxFit.fitHeight, 110, 300), 300);
    });

    test('a contained box is governed by its width', () {
      // Contain fits the frame inside, so it is never drawn wider than the
      // box. Taking the longest edge here would decode a full-height sheet
      // at its *height* — several times the pixels it can use.
      expect(governingEdge(BoxFit.contain, 390, 2600), 390);
      expect(governingEdge(BoxFit.fitWidth, 390, 2600), 390);
      expect(governingEdge(BoxFit.scaleDown, 390, 2600), 390);
      expect(governingEdge(BoxFit.fill, 390, 2600), 390);
    });

    test(
      'BoxFit.none derives nothing, because it would shrink the picture',
      () {
        // `none` draws the image at whatever size it decoded to, so a smaller
        // decode is a smaller photograph on screen rather than the same one
        // more cheaply.
        expect(governingEdge(BoxFit.none, 390, 2600), isNull);
      },
    );
  });

  // -------------------------------------------------------------------------
  group('through the whole stack', () {
    late AppDatabase db;
    late Directory frames;

    setUp(() {
      db = AppDatabase(
        DatabaseConnection(
          NativeDatabase.memory(),
          closeStreamsSynchronously: true,
        ),
        mint: () => testTripId,
      );
      frames = Directory.systemTemp.createTempSync('cairn_originals');
    });
    tearDown(() {
      db.close();
      frames.deleteSync(recursive: true);
    });

    Future<void> keepOnePhoto(
      WidgetTester tester,
      RecordingCamera camera,
    ) async {
      final ping = pingOn(day(14));
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        bootstrapApp(
          database: db,
          today: day(14),
          now: ping.at,
          utcOffset: Duration.zero,
          camera: camera,
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

      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
    }

    testWidgets('the frame the camera wrote is the frame the pool keeps', (
      tester,
    ) async {
      final camera = RecordingCamera(frames, takenAtUtc: pingOn(day(14)).at);
      await keepOnePhoto(tester, camera);

      // The breath has drawn it once already — a surface that resized in
      // place would have done its damage by here.
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final row = (await db.readPhotos()).single;
      final onDisk = File(row.filePath);
      expect(
        onDisk.existsSync(),
        isTrue,
        reason: 'the row points at a file that is not there',
      );

      final original = camera.written[row.filePath];
      expect(
        original,
        isNotNull,
        reason:
            'the store filed a path the camera never wrote — something '
            'between the two made a second file',
      );
      expect(
        onDisk.readAsBytesSync(),
        original,
        reason:
            'the stored frame is not the frame the camera wrote: '
            'something on the way re-encoded or downsized the original',
      );

      // And drawing it in the Pool leaves it alone too.
      await tester.tap(find.byKey(const Key('tab-pool')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('pool-photo-${row.id}-image')), findsOneWidget);
      expect(
        onDisk.readAsBytesSync(),
        original,
        reason: 'showing a photograph rewrote it',
      );
    });

    testWidgets('a discarded retake takes no original with it', (tester) async {
      // The frame that was kept and the frame that was thrown away are
      // different files; a retake must not be able to reach the first.
      final camera = RecordingCamera(frames, takenAtUtc: pingOn(day(14)).at);
      await keepOnePhoto(tester, camera);
      await tester.tap(find.byKey(const Key('capture-once-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final row = (await db.readPhotos()).single;
      expect(camera.written, hasLength(2));
      expect(
        File(row.filePath).readAsBytesSync(),
        camera.written[row.filePath],
        reason: 'the kept frame is not the second frame, byte for byte',
      );
    });

    testWidgets('the Pool draws a tile at the tile\'s size, not the frame\'s', (
      tester,
    ) async {
      final camera = RecordingCamera(frames, takenAtUtc: pingOn(day(14)).at);
      await keepOnePhoto(tester, camera);
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();

      final row = (await db.readPhotos()).single;
      await tester.tap(find.byKey(const Key('tab-pool')));
      await tester.pumpAndSettle();

      final image = tester.widget<Image>(
        find.byKey(Key('pool-photo-${row.id}-image')),
      );
      expect(
        image.image,
        isA<ResizeImage>(),
        reason:
            'the tile is decoding the original at full size — every '
            'photo surface goes through PhotoFrame',
      );

      // Not merely "smaller": the decode is the tile's own size, so this
      // fails if the rule ever drifts to a fixed thumbnail number.
      final tile = tester.getSize(find.byKey(Key('pool-photo-${row.id}')));
      expect(
        (image.image as ResizeImage).width,
        displayDecodeWidth(
          // `BoxFit.cover` in the grid, so the longest edge governs.
          logicalEdge: tile.longestSide,
          devicePixelRatio: tester.view.devicePixelRatio,
        ),
      );
      // And it really is a saving against the frame behind it.
      expect((image.image as ResizeImage).width, lessThan(standInWidth));
    });

    testWidgets(
      'the breath draws the frame at the screen, not at the ceiling',
      (tester) async {
        final camera = RecordingCamera(frames, takenAtUtc: pingOn(day(14)).at);
        await keepOnePhoto(tester, camera);

        final image = tester.widget<Image>(
          find.byKey(const Key('capture-frame')),
        );
        expect(image.image, isA<ResizeImage>());
        // `BoxFit.contain` in a tall sheet: the width governs, so the decode
        // follows the 800-pixel view and not the sheet's height. A decode at
        // the ceiling here would mean the fit is not being consulted at all —
        // which is exactly what this test caught the first time it ran.
        expect((image.image as ResizeImage).width, lessThanOrEqualTo(800));
        expect(
          (image.image as ResizeImage).width,
          lessThan(maxDisplayDecodeEdge),
        );
      },
    );
  });
}
