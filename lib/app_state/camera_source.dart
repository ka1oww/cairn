// APP STATE band (docs/architecture.md), platform-edge side: the camera,
// behind a seam.
//
// The camera is a platform edge — the map draws those beside this band:
// services know them, they know nothing of Cairn. Everything above this file
// asks for one capture event and is handed file paths and an instant; nothing
// above it names a lens, a controller, or a plugin.
//
// The composition is back-full-bleed with the front inset
// (docs/decisions/2026-08-22-camera-like-bereal.md), and it is drawn on the
// capture review — this source composes nothing, it delivers two files and
// the inset's layout is lib/screens/capture_screen.dart's. What is still
// after the line is *keeping* the front frame; the first release stores the
// back one alone (docs/roadmap.md). The spike at
// learning/dual-camera-spike/ established that the inset is a
// back-*then*-front sequence and never a simultaneous capture. This source
// therefore opens and closes one camera at a time.
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'stand_in_frame.dart';

/// One capture event, with the back frame first and an optional front frame.
class CapturedFrame {
  /// Where the back-frame bytes landed on this device.
  ///
  /// This name is retained so the single-frame callers above the seam keep
  /// working — the kept photograph is the back frame alone. New consumers
  /// should use [backPath] and [frontPath].
  final String path;

  /// Where the front-frame bytes landed, when a front frame was taken.
  final String? frontPath;

  /// When the shutter fired, in UTC.
  ///
  /// The app took it, so this instant is known exactly rather than derived —
  /// which is the whole difference between `PhotoOrigin.pinged` and
  /// `PhotoOrigin.imported` (design-calls §2, "the hour is reliable").
  final DateTime takenAtUtc;

  const CapturedFrame({
    required this.path,
    required this.takenAtUtc,
    this.frontPath,
  });

  /// The back frame, named explicitly for two-frame consumers.
  String get backPath => path;

  /// Whether this capture event includes the front inset frame.
  bool get hasFrontFrame => frontPath != null;
}

/// The camera could not be used. Carries a sentence a person could read.
class CameraRefused implements Exception {
  final String reason;
  const CameraRefused(this.reason);

  @override
  String toString() => 'CameraRefused: $reason';
}

/// Whatever can hand the app one capture event.
abstract interface class CameraSource {
  /// Takes a back frame and, when available, a front frame, or throws
  /// [CameraRefused]. The two captures are sequential.
  Future<CapturedFrame> takeOne();

  /// Throws away a frame that was never kept — a retake, or a capture
  /// abandoned before the day turned over. The file was this seam's to make,
  /// so it is this seam's to unmake; no band above does file I/O.
  Future<void> discard(String path);
}

/// The hardware-facing part of [BackCameraSource].
///
/// Keeping this small seam separate from file storage lets tests exercise the
/// real sequencing and cleanup rules without needing a camera or a platform
/// channel.
abstract interface class CameraCaptureEdge {
  Future<List<CameraDescription>> listCameras();

  /// Captures a frame and returns the plugin-owned temporary path.
  Future<String> capture(CameraDescription camera);
}

class _PluginCameraCaptureEdge implements CameraCaptureEdge {
  const _PluginCameraCaptureEdge();

  @override
  Future<List<CameraDescription>> listCameras() => availableCameras();

  @override
  Future<String> capture(CameraDescription camera) async {
    // `max`, not `high`: the pool stores the original. Every smaller size
    // shown by the app is derived at decode time by
    // `lib/screens/photo_frame.dart` and never written back over this file.
    final controller = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      final shot = await controller.takePicture();
      return shot.path;
    } finally {
      await controller.dispose();
    }
  }
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
  const BackCameraSource({
    CameraCaptureEdge camera = const _PluginCameraCaptureEdge(),
    Future<Directory> Function() directoryProvider = _frameDirectory,
  }) : this._(camera, directoryProvider);

  const BackCameraSource._(this._camera, this._directoryProvider);

  final CameraCaptureEdge _camera;
  final Future<Directory> Function() _directoryProvider;

  @override
  Future<CapturedFrame> takeOne() async {
    String? backPath;
    try {
      final cameras = await _camera.listCameras();
      final back = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (back.isEmpty) {
        throw const CameraRefused('This device has no back camera.');
      }
      final front = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (front.isEmpty) {
        throw const CameraRefused('This device has no front camera.');
      }

      // The back capture completes before this call begins. Each controller
      // is disposed by the platform edge before the next lens is opened.
      final backFrame = await _captureAndStore(back.first, 'back');
      backPath = backFrame.path;
      final frontFrame = await _captureAndStore(front.first, 'front');
      return CapturedFrame(
        path: backFrame.path,
        frontPath: frontFrame.path,
        takenAtUtc: backFrame.takenAtUtc,
      );
    } catch (error, stackTrace) {
      if (backPath != null) {
        // If the second lens refuses or its capture fails, the first copy is
        // not a photograph the app can keep. Do not leave it behind.
        try {
          await discard(backPath);
        } catch (_) {
          // A cleanup that cannot delete is a stray file, and a stray file is
          // not what the caller is waiting to hear about: the refusal below is
          // the only thing above this seam handles.
        }
      }
      if (error is CameraException) {
        Error.throwWithStackTrace(
          CameraRefused(error.description ?? 'The camera would not open.'),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<({String path, DateTime takenAtUtc})> _captureAndStore(
    CameraDescription camera,
    String identity,
  ) async {
    final temporaryPath = await _camera.capture(camera);
    final at = DateTime.now().toUtc();
    final dir = await _directoryProvider();
    final path = '${dir.path}/$identity-${at.microsecondsSinceEpoch}.jpg';
    // A byte-for-byte copy, deliberately: no re-encode, no strip, no
    // recompression. The file the plugin wrote is the original, and this
    // is only where it is filed.
    try {
      await File(temporaryPath).copy(path);
    } catch (error, stackTrace) {
      // A copy that stops half way — a full disk, on a `max` original —
      // leaves a truncated destination behind. Nothing above knows this path
      // yet, so unmaking it is this call's own business.
      try {
        await _delete(path);
      } catch (_) {
        // Same rule as the caller's cleanup: the original failure travels.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    return (path: path, takenAtUtc: at);
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
final cameraSourceProvider = Provider<CameraSource>(
  (ref) => const DeviceCameraSource(),
);
