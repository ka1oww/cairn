// APP STATE band (docs/architecture.md), platform-edge side: the camera,
// behind a seam.
//
// The camera is a platform edge — the map draws those beside this band:
// services know them, they know nothing of Cairn. Everything above this file
// asks for one frame and is handed a file path and an instant; nothing above
// it names a lens, a controller, or a plugin.
//
// **Back camera only.** That is the first release, decided and settled: the
// composition is back-full-bleed with the front inset following after the
// line (docs/decisions/2026-08-22-camera-like-bereal.md, and the first
// release's list in docs/roadmap.md). The spike at
// learning/dual-camera-spike/ established that the inset, when it lands, is a
// back-*then*-front sequence and never a simultaneous capture — which is
// why this interface takes one frame at a time rather than a pair. Adding the
// inset is a second method here, not a different shape.
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'stand_in_frame.dart';

/// One frame, taken.
class CapturedFrame {
  /// Where the bytes landed on this device.
  final String path;

  /// When the shutter fired, in UTC.
  ///
  /// The app took it, so this instant is known exactly rather than derived —
  /// which is the whole difference between `PhotoOrigin.pinged` and
  /// `PhotoOrigin.imported` (design-calls §2, "the hour is reliable").
  final DateTime takenAtUtc;

  const CapturedFrame({required this.path, required this.takenAtUtc});
}

/// The camera could not be used. Carries a sentence a person could read.
class CameraRefused implements Exception {
  final String reason;
  const CameraRefused(this.reason);

  @override
  String toString() => 'CameraRefused: $reason';
}

/// Whatever can hand the app one photograph.
abstract interface class CameraSource {
  /// Takes one frame with the back camera, or throws [CameraRefused].
  Future<CapturedFrame> takeOne();

  /// Throws away a frame that was never kept — a retake, or a capture
  /// abandoned before the day turned over. The file was this seam's to make,
  /// so it is this seam's to unmake; no band above does file I/O.
  Future<void> discard(String path);
}

/// Where kept and unkept frames both live on this device.
///
/// The app's own documents directory, not the camera roll: a pinged photo is
/// the trip's, and putting it in the roll before the pool exists would make
/// the import sweep re-find the app's own photographs.
Future<Directory> _frameDirectory() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/frames');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// The real one. **Real device only** — see [standInOrRealCamera].
class BackCameraSource implements CameraSource {
  const BackCameraSource();

  @override
  Future<CapturedFrame> takeOne() async {
    final cameras = await availableCameras();
    final back = cameras.where(
      (c) => c.lensDirection == CameraLensDirection.back,
    );
    if (back.isEmpty) {
      throw const CameraRefused('This device has no back camera.');
    }
    // `max`, not `high`. The pool stores the **original**
    // (docs/decisions/2026-08-22-grill-round-one.md §3), and the handover
    // promise is a full-size set, so the largest frame the sensor will give
    // is the frame this app is entitled to keep. `ResolutionPreset.high` is
    // 720p on iOS (`camera_avfoundation` maps it to `.hd1280x720`) -- a
    // downsize applied before the bytes ever reach the store, which no later
    // layer could undo. `max` selects the device's highest-resolution format
    // instead, and the plugin falls back down the ladder on a device that
    // cannot offer it, so asking for it is never the thing that fails.
    // Every smaller size the app shows is derived at decode time by
    // `lib/screens/photo_frame.dart` and never written back over this file.
    final controller = CameraController(
      back.first,
      ResolutionPreset.max,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      final shot = await controller.takePicture();
      final at = DateTime.now().toUtc();
      final dir = await _frameDirectory();
      final path = '${dir.path}/${at.microsecondsSinceEpoch}.jpg';
      // A byte-for-byte copy, deliberately: no re-encode, no strip, no
      // recompression. The file the plugin wrote is the original, and this
      // is only where it is filed.
      await File(shot.path).copy(path);
      return CapturedFrame(path: path, takenAtUtc: at);
    } on CameraException catch (e) {
      throw CameraRefused(e.description ?? 'The camera would not open.');
    } finally {
      await controller.dispose();
    }
  }

  @override
  Future<void> discard(String path) => _delete(path);
}

/// The one that works where there is no camera.
///
/// This is not a mock and not a test double: it is a real source that writes
/// a real image file, so the flow it feeds is the same flow on the simulator
/// as on a phone. Only the photograph is invented. See `stand_in_frame.dart`
/// for why that matters.
class StandInCameraSource implements CameraSource {
  const StandInCameraSource();

  @override
  Future<CapturedFrame> takeOne() async {
    final at = DateTime.now().toUtc();
    final dir = await _frameDirectory();
    final path = '${dir.path}/${at.microsecondsSinceEpoch}.png';
    await File(path).writeAsBytes(standInFrameBytes(at.millisecondsSinceEpoch));
    return CapturedFrame(path: path, takenAtUtc: at);
  }

  @override
  Future<void> discard(String path) => _delete(path);
}

Future<void> _delete(String path) async {
  final file = File(path);
  // A frame that is already gone is the state we wanted; nothing above this
  // seam should have to care which of the two it got.
  if (await file.exists()) await file.delete();
}

/// The back camera where there is one, the stand-in where there is not.
///
/// The fallback is decided by asking the platform, not by a build flag: the
/// simulator answers `availableCameras()` with an empty list, so the whole
/// capture flow is walkable there without anything being switched on. On a
/// real phone the same code takes a real photograph.
class DeviceCameraSource implements CameraSource {
  const DeviceCameraSource();

  @override
  Future<CapturedFrame> takeOne() async {
    if (await _hasBackCamera()) return const BackCameraSource().takeOne();
    return const StandInCameraSource().takeOne();
  }

  @override
  Future<void> discard(String path) => _delete(path);

  static Future<bool> _hasBackCamera() async {
    try {
      final cameras = await availableCameras();
      return cameras.any((c) => c.lensDirection == CameraLensDirection.back);
    } catch (_) {
      // Catching broadly on purpose: the answers to "is there a back camera"
      // are yes, no, and every way the platform channel can decline to say —
      // a simulator, a denied permission, a host with no camera plugin at
      // all. All three mean the same thing here, which is take the stand-in.
      return false;
    }
  }
}

/// Bound to [DeviceCameraSource] for the app, and to a fake by tests.
final cameraSourceProvider =
    Provider<CameraSource>((ref) => const DeviceCameraSource());
