// BeReal-familiar capture, through Cairn's real app, providers and Drift
// store. This is deliberately one journey: today's ping opens the two-minute
// window, the camera takes a back/front pair, the review shows the back frame
// with the front inset and the caption line, the owner retakes twice across
// the original deadline, posts late, and the photo lands in the Pool bare —
// no lateness mark, no caption surface, no retake count.
//
// Three places this spec deliberately diverges from BeReal's shape, each a
// settled product decision rather than a gap:
//
//  - **The last stretch is a thirty-second tail**, not the whole window
//    (capture_flow.dart's `lastStretch`): a tail equal to the window would
//    make the not-yet reading a state nobody could be in.
//  - **The caption is written at capture**, on the review sheet under the
//    hour, and the Pool has no caption surface: blank is the usual, and the
//    line is skippable by construction (design round 10, 18a/18b).
//  - **The Pool does not mark a late post.** The photo keeps its real
//    after-deadline instant — that is the only pressure the system applies —
//    and lateness is not a stored fact.
//
// The camera is the only fake. It returns real image files synchronously for
// the same fake-async reason documented in capture_flow_test.dart. Like the
// device seam, one call takes the back frame first, then the front frame, and
// returns one capture event carrying both paths.
import 'dart:io';

import 'package:cairn_model/cairn_model.dart' as model;
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'package:cairn/app_state/camera_source.dart';
import 'package:cairn/app_state/capture_flow.dart';
import 'package:cairn/app_state/ping_schedule.dart';
import 'package:cairn/app_state/stand_in_frame.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

const _tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- 09:30 Skytree

Tue 15 June 2027 - Kyoto
- Fushimi Inari
''';

final _testTripId = model.TripId.mint(List.filled(16, 0x5a));

tm.Ping _pingOn(DateTime date) => tm
    .dayAssignment(
      tripId: _testTripId.value,
      party: tm.Party(const [localMemberId]),
      day: tm.TripDay(date: date, utcOffset: Duration.zero),
    )
    .pingFor(localMemberId)!;

class _MutableClock {
  _MutableClock(this.now);

  DateTime now;
}

class _FrameEvent {
  const _FrameEvent({required this.role, required this.frame});

  final String role;
  final CapturedFrame frame;
}

class _TwoFrameCamera implements CameraSource {
  _TwoFrameCamera(this.directory, this.clock);

  final Directory directory;
  final _MutableClock clock;
  final List<_FrameEvent> taken = [];
  final List<String> discarded = [];

  @override
  Future<CapturedFrame> takeOne() async {
    final back = _take('back');
    final front = _take('front');
    // The production capture event, exactly as the device seam builds it:
    // the back path is the frame the day keeps, the front path rides beside
    // it for the review's inset.
    return CapturedFrame(
      path: back.path,
      frontPath: front.path,
      takenAtUtc: back.takenAtUtc,
    );
  }

  @override
  Future<void> discard(String path) async => discarded.add(path);

  CapturedFrame _take(String role) {
    final index = taken.length + 1;
    final path = '${directory.path}/$index-$role.png';
    File(path).writeAsBytesSync(standInFrameBytes(index));
    final frame = CapturedFrame(path: path, takenAtUtc: clock.now);
    taken.add(_FrameEvent(role: role, frame: frame));
    return frame;
  }
}

/// Keeps parity failures independent, so one missing surface does not stop
/// the same run from reporting every other gap as well. The test still fails
/// once, with every missing behaviour in plain language.
class _ParityChecks {
  final List<String> passed = [];
  final List<String> missing = [];

  void pass(String message) => passed.add(message);

  void check(bool condition, String message) {
    (condition ? passed : missing).add(message);
  }

  void finish() {
    // These lines make the baseline run usable as the PR-body checklist.
    for (final message in passed) {
      // ignore: avoid_print
      print('PARITY PASS: $message');
    }
    for (final message in missing) {
      // ignore: avoid_print
      print('PARITY WAITING: $message');
    }
    expect(
      missing,
      isEmpty,
      reason:
          'BeReal-familiar capture is still missing:\n'
          '${missing.map((message) => '- $message').join('\n')}',
    );
  }
}

void main() {
  testWidgets(
    'ping to two-frame retakes to a late Pool post, captioned at capture',
    (tester) async {
      final checks = _ParityChecks();
      final today = DateTime.utc(2027, 6, 14);
      final ping = _pingOn(today);
      final clock = _MutableClock(ping.at);
      final db = AppDatabase(
        DatabaseConnection(
          NativeDatabase.memory(),
          closeStreamsSynchronously: true,
        ),
        mint: () => _testTripId,
      );
      final frames = Directory.systemTemp.createTempSync('cairn-bereal-parity');
      final camera = _TwoFrameCamera(frames, clock);
      addTearDown(() async {
        await db.close();
        if (frames.existsSync()) frames.deleteSync(recursive: true);
      });

      final pingCall = captureCallFor(
        ping: ping,
        now: ping.at,
        answeredAt: null,
        utcOffset: Duration.zero,
        standing: model.TripStanding.underway,
      );
      final finalOpenCall = captureCallFor(
        ping: ping,
        now: ping.at.add(const Duration(minutes: 1, seconds: 59)),
        answeredAt: null,
        utcOffset: Duration.zero,
        standing: model.TripStanding.underway,
      );
      final boundaryCall = captureCallFor(
        ping: ping,
        now: ping.at.add(const Duration(minutes: 2)),
        answeredAt: null,
        utcOffset: Duration.zero,
        standing: model.TripStanding.underway,
      );
      checks.check(
        captureWindow == const Duration(minutes: 2),
        'The capture deadline is two minutes after the ping, not thirty.',
      );
      // The last stretch is a thirty-second tail, so at the ping instant the
      // whole window is still ahead and the tail has not begun.
      checks.check(
        pingCall is MomentOpen && !pingCall.isLastStretch,
        'The window is open and not yet its last stretch at the ping instant.',
      );
      checks.check(
        finalOpenCall is MomentOpen && finalOpenCall.isLastStretch,
        'The window remains open and is inside its 30-second last stretch '
        'through 01:59.',
      );
      checks.check(
        boundaryCall is MomentLate,
        'The original window is late at exactly 02:00 and is not reset.',
      );

      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // bootstrapApp owns the real provider graph. Copy its overrides and add
      // a mutable nowProvider so the single journey can cross the deadline.
      final bootstrapped = bootstrapApp(
        database: db,
        today: today,
        utcOffset: Duration.zero,
        camera: camera,
      ) as ProviderScope;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...bootstrapped.overrides,
            nowProvider.overrideWith((ref) => Clock(() => clock.now)),
          ],
          child: bootstrapped.child,
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.enterText(find.byKey(const Key('paste-input')), _tripPaste);
      await tester.tap(find.byKey(const Key('read-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('accept-button')));
      await tester.pump();
      await tester.pump();

      // The scheduled daily ping has arrived and made the capture door live.
      expect(
        find.byKey(const Key('capture-call-action')),
        findsOneWidget,
        reason: 'The daily ping should open a capture action on Today.',
      );
      checks.pass('The daily ping opens the capture action on Today.');
      checks.check(
        _textUnder(const Key('capture-call')) == 'Your minute. Look up.',
        'Today calls the freshly opened window in its not-yet words: the '
        '30-second tail has not begun at the ping.',
      );

      await tester.tap(find.byKey(const Key('capture-call-action')));
      await tester.pumpAndSettle();
      final notYetOnScreen = _textUnder(const Key('capture-window'));

      // Step into the final thirty seconds. Invalidating the provider changes
      // the clock; it does not create a new ping or deadline.
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('capture-shutter'))),
        listen: false,
      );
      clock.now = ping.at.add(const Duration(minutes: 1, seconds: 35));
      container.invalidate(nowProvider);
      await tester.pump();
      final inTailOnScreen = _textUnder(const Key('capture-window'));
      checks.check(
        notYetOnScreen == 'a while yet' && inTailOnScreen == 'last stretch',
        'The capture screen says a while yet at the ping and turns to last '
        'stretch only inside the final thirty seconds.',
      );

      await tester.tap(find.byKey(const Key('capture-shutter')));
      await tester.pumpAndSettle();
      checks.check(
        _isBackFrontPair(camera.taken, attempts: 1),
        'One shutter takes exactly a back frame followed by a front frame.',
      );
      checks.check(
        find.byKey(const Key('capture-back-frame')).evaluate().length == 1 &&
            find.byKey(const Key('capture-front-frame')).evaluate().length == 1,
        'The capture review keeps the back frame and the front inset together.',
      );
      // The caption is written at capture: the line sits on the review sheet
      // under the hour, skippable by construction, and blank is the usual.
      checks.check(
        find.byKey(const Key('capture-word')).evaluate().length == 1 &&
            find.byKey(const Key('capture-word-whisper')).evaluate().length ==
                1,
        'The caption line is on the capture review, under the hour, before '
        'anything posts.',
      );

      // Cross the original deadline before the first retake.
      clock.now = ping.at.add(const Duration(minutes: 2, seconds: 1));
      container.invalidate(nowProvider);
      await tester.pump();

      final firstRetake = find.byKey(const Key('capture-once-more'));
      checks.check(
        firstRetake.evaluate().length == 1,
        'The first retake remains available after a complete two-frame attempt.',
      );
      if (firstRetake.evaluate().length == 1) {
        await tester.tap(firstRetake);
        await tester.pumpAndSettle();
        checks.check(
          _showsLateCapture(),
          'Crossing the original deadline marks the retake late instead of resetting the window.',
        );
        await tester.tap(find.byKey(const Key('capture-shutter')));
        await tester.pumpAndSettle();
        checks.check(
          _isBackFrontPair(camera.taken, attempts: 2),
          'The first retake replaces the moment with a second back/front pair.',
        );
      }

      final secondRetake = find.byKey(const Key('capture-once-more'));
      checks.check(
        secondRetake.evaluate().length == 1,
        'Retakes are unlimited: the control remains after the second attempt.',
      );
      if (secondRetake.evaluate().length == 1) {
        await tester.tap(secondRetake);
        await tester.pumpAndSettle();
        checks.check(
          _showsLateCapture(),
          'The late mark stays visible through a second retake.',
        );
        await tester.tap(find.byKey(const Key('capture-shutter')));
        await tester.pumpAndSettle();
        checks.check(
          _isBackFrontPair(camera.taken, attempts: 3),
          'Three attempts each take a complete back/front pair.',
        );
        checks.check(
          find.byKey(const Key('capture-once-more')).evaluate().length == 1,
          'Retakes are unlimited: after taking three, the control is still there.',
        );
      }

      // Post with the line left blank. Blank is the usual, and an untouched
      // caption line stores no word; a late post remains allowed.
      await tester.tap(find.byKey(const Key('capture-keep')));
      await tester.pumpAndSettle();
      final posted = await db.readPhotos();
      expect(
        posted,
        hasLength(1),
        reason:
            'Posting after the two-minute deadline must still keep a photo.',
      );
      checks.pass('Posting after the original deadline still keeps the photo.');
      expect(
        posted.single.word,
        isNull,
        reason: 'A caption line left blank must store no word.',
      );
      checks.pass('The stored photo has no caption at the instant it posts.');
      checks.check(
        posted.single.takenAtUtcIso == clock.now.toIso8601String(),
        'The late post keeps its real after-deadline capture instant.',
      );
      final photoId = posted.single.id;

      await tester.tap(
        find.ancestor(
          of: find.byKey(const Key('tab-pool')),
          matching: find.byType(GestureDetector),
        ),
      );
      await tester.pumpAndSettle();
      final tile = find.byKey(Key('pool-photo-$photoId'));
      expect(
        tile,
        findsOneWidget,
        reason: 'The posted photo must land in the Pool in the same journey.',
      );
      checks.pass('The posted photo lands in the Pool in the same journey.');
      // The real instant is the only trace of lateness the record carries:
      // the Pool tile wears no mark, because lateness is not a stored fact.
      checks.check(
        find.byKey(Key('pool-photo-$photoId-late')).evaluate().isEmpty,
        'The Pool keeps a late post without marking it late.',
      );
      checks.check(
        find
                .textContaining(
                  RegExp(r'\b(retake|retry|attempt)s?\b', caseSensitive: false),
                )
                .evaluate()
                .isEmpty &&
            find.byKey(Key('pool-photo-$photoId-retakes')).evaluate().isEmpty,
        'The posted photo exposes no retake count to a viewer.',
      );
      // The caption's one home is the capture review. A posted photo offers
      // no caption entry in the Pool — the word was written, or skipped, at
      // capture.
      checks.check(
        find
                .byKey(Key('pool-photo-$photoId-caption-edit'))
                .evaluate()
                .isEmpty &&
            find
                .byKey(Key('pool-photo-$photoId-caption-field'))
                .evaluate()
                .isEmpty,
        'The Pool offers no caption entry: the word belongs to capture.',
      );

      checks.finish();
    },
  );
}

bool _isBackFrontPair(List<_FrameEvent> events, {required int attempts}) {
  if (events.length != attempts * 2) return false;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (events[attempt * 2].role != 'back' ||
        events[attempt * 2 + 1].role != 'front') {
      return false;
    }
  }
  return true;
}

String? _textUnder(Key key) {
  final texts = find
      .descendant(
        of: find.byKey(key),
        matching: find.byType(Text),
        matchRoot: true,
      )
      .evaluate();
  if (texts.isEmpty) return null;
  final text = texts.first.widget as Text;
  return text.data ?? text.textSpan?.toPlainText();
}

bool _showsLateCapture() {
  final line = _textUnder(const Key('capture-window'));
  return line?.contains('Your slot was') == true &&
      find.byKey(const Key('capture-countdown')).evaluate().isEmpty;
}
