// ignore_for_file: prefer_initializing_formals -- the public constructor
// parameter names below (takeBackPhoto, ...) are the documented API; the
// leading underscore on the backing fields is an implementation detail that
// shouldn't leak into how callers construct this class.

// Note: `Uint8List` comes from `package:flutter/foundation.dart`'s
// re-export of `dart:typed_data`, so that's the only import needed here.
import 'package:flutter/foundation.dart';

/// Which lens a shot came from.
enum ShotRole { back, front }

/// One still frame captured during a moment.
@immutable
class CapturedShot {
  const CapturedShot({
    required this.role,
    required this.imageBytes,
    required this.capturedAt,
  });

  final ShotRole role;
  final Uint8List imageBytes;

  /// Elapsed time since [CaptureSequencer.capture] was called -- i.e. since
  /// the person tapped the shutter. This is the number that actually matters
  /// for "does it look simultaneous": not how the shots were technically
  /// taken, but how much daylight exists between them for a subject to
  /// notice and pose for the second one.
  final Duration capturedAt;
}

/// The two shots that make up one moment, back paired with front.
@immutable
class MomentCapture {
  const MomentCapture({required this.back, required this.front});

  final CapturedShot back;
  final CapturedShot front;

  /// The gap a human would actually perceive between the two shots. Zero
  /// would mean true hardware simultaneity; anything else is the cost of
  /// sequential capture made visible and measurable.
  Duration get gapBetweenShots => front.capturedAt - back.capturedAt;
}

/// Runs the back-then-front capture sequence and times it, independent of
/// what actually takes the photo.
///
/// This class never imports `package:camera` -- it is handed three closures
/// (take the back photo, switch lenses, take the front photo) and only cares
/// about the order and the timing between them. That is the entire
/// "sequential capture" mechanic; there is no other synchronization to get
/// right. Keeping it hardware-agnostic is what makes it possible to prove
/// this ordering logic correct in a plain `dart test` run (see
/// `test/capture_sequencer_test.dart`) with no camera, real or fake-hardware,
/// anywhere in the picture -- the real app wires real `CameraController`
/// calls into these same three closures (see `moment_camera_screen.dart`).
class CaptureSequencer {
  CaptureSequencer({
    required Future<Uint8List> Function() takeBackPhoto,
    required Future<void> Function() switchToFrontLens,
    required Future<Uint8List> Function() takeFrontPhoto,
    Stopwatch? stopwatch,
  }) : _takeBackPhoto = takeBackPhoto,
       _switchToFrontLens = switchToFrontLens,
       _takeFrontPhoto = takeFrontPhoto,
       _stopwatch = stopwatch ?? Stopwatch();

  final Future<Uint8List> Function() _takeBackPhoto;
  final Future<void> Function() _switchToFrontLens;
  final Future<Uint8List> Function() _takeFrontPhoto;
  final Stopwatch _stopwatch;

  Future<MomentCapture> capture() async {
    _stopwatch
      ..reset()
      ..start();
    final backBytes = await _takeBackPhoto();
    final backAt = _stopwatch.elapsed;
    await _switchToFrontLens();
    final frontBytes = await _takeFrontPhoto();
    final frontAt = _stopwatch.elapsed;
    _stopwatch.stop();
    return MomentCapture(
      back: CapturedShot(
        role: ShotRole.back,
        imageBytes: backBytes,
        capturedAt: backAt,
      ),
      front: CapturedShot(
        role: ShotRole.front,
        imageBytes: frontBytes,
        capturedAt: frontAt,
      ),
    );
  }
}
