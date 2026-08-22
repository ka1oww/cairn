// Pure-Dart tests of the sequential capture mechanic: no camera, no
// platform channel, no widget tree. This is the part of the spike that can
// be proven correct without a physical device, and it is the part the whole
// recommendation rests on -- see CaptureSequencer's doc comment.

import 'dart:typed_data';

import 'package:dual_camera_spike/moment/capture_sequencer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaptureSequencer', () {
    test('captures back before front, in that order, exactly once each', () async {
      final calls = <String>[];
      final sequencer = CaptureSequencer(
        takeBackPhoto: () async {
          calls.add('back');
          return Uint8List.fromList([1, 2, 3]);
        },
        switchToFrontLens: () async {
          calls.add('switch');
        },
        takeFrontPhoto: () async {
          calls.add('front');
          return Uint8List.fromList([4, 5, 6]);
        },
      );

      final result = await sequencer.capture();

      expect(calls, ['back', 'switch', 'front']);
      expect(result.back.role, ShotRole.back);
      expect(result.front.role, ShotRole.front);
      expect(result.back.imageBytes, [1, 2, 3]);
      expect(result.front.imageBytes, [4, 5, 6]);
    });

    test('the front shot is always timestamped after the back shot', () async {
      final sequencer = CaptureSequencer(
        takeBackPhoto: () async => Uint8List(0),
        switchToFrontLens: () async {
          // Stand in for whatever a real lens switch costs on real hardware
          // (dispose one CameraController, construct and initialize the
          // next). The point under test is ordering and a non-negative gap,
          // not this specific number -- see the README for real numbers.
          await Future<void>.delayed(const Duration(milliseconds: 30));
        },
        takeFrontPhoto: () async => Uint8List(0),
      );

      final result = await sequencer.capture();

      expect(result.front.capturedAt, greaterThan(result.back.capturedAt));
      expect(result.gapBetweenShots, greaterThanOrEqualTo(const Duration(milliseconds: 25)));
    });

    test('propagates a failure from the back shot without calling the rest', () async {
      final calls = <String>[];
      final sequencer = CaptureSequencer(
        takeBackPhoto: () async {
          calls.add('back');
          throw StateError('camera denied');
        },
        switchToFrontLens: () async => calls.add('switch'),
        takeFrontPhoto: () async {
          calls.add('front');
          return Uint8List(0);
        },
      );

      await expectLater(sequencer.capture(), throwsStateError);
      expect(calls, ['back']);
    });

    test('propagates a failure from switching lenses without taking the front shot', () async {
      final calls = <String>[];
      final sequencer = CaptureSequencer(
        takeBackPhoto: () async {
          calls.add('back');
          return Uint8List(0);
        },
        switchToFrontLens: () async {
          calls.add('switch');
          throw StateError('front camera unavailable');
        },
        takeFrontPhoto: () async {
          calls.add('front');
          return Uint8List(0);
        },
      );

      await expectLater(sequencer.capture(), throwsStateError);
      expect(calls, ['back', 'switch']);
    });
  });
}
