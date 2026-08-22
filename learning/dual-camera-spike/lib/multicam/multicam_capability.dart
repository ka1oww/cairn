import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Whether this specific device can run true hardware-simultaneous dual
/// camera capture -- i.e. `AVCaptureMultiCamSession` on iOS, or Android's
/// `FEATURE_CAMERA_CONCURRENT` front+back combination.
enum MultiCamSupport {
  /// The device/OS combination reports it can run both cameras at once.
  /// This is a declared capability flag, not a live-tested guarantee -- it
  /// was observed to read `true` on the iOS Simulator too (see the README
  /// and `ios/Runner/AppDelegate.swift`), which has no real camera hardware
  /// at all. Treat it as "eligible to try", not "confirmed working".
  supported,

  /// The device and OS were checked, and cannot.
  unsupported,

  /// This platform has no capability check wired up in this spike. See the
  /// README for what each unimplemented platform's real answer is.
  notProbedOnThisPlatform,
}

/// Asks native code the reachability question directly, the way iOS and
/// Android actually expose it: as a runtime capability query against the
/// device in your hand, never a hardcoded model list -- Apple's guidance is
/// that `isMultiCamSupported` is the right way to ask, rather than
/// hardcoding a device list yourself. It answers from the device's declared
/// chip class, though, not from a live probe of actual camera hardware: this
/// spike measured it returning `true` on the iOS Simulator, which has no
/// camera at all. Treat a `supported` result as "worth attempting", and only
/// a real capture on a physical device as proof it actually works.
///
/// Only iOS is wired up in this spike (see
/// `ios/Runner/AppDelegate.swift`), because that is the platform a physical
/// device exists to eventually verify this against. Android's real answer
/// -- `CameraManager.getConcurrentCameraIds()`, Android 11+, no CameraX
/// support, real-world adoption far from universal -- is documented in the
/// README but not implemented here: there is no Android SDK on the machine
/// this spike was written on, so there was no way to even compile-check a
/// line of Kotlin, and shipping untested native code inside a spike whose
/// whole point is honesty about what is proven would defeat it.
class MultiCamCapability {
  MultiCamCapability._();

  static const MethodChannel _channel =
      MethodChannel('cairn.dualcamera/multicam');

  static Future<MultiCamSupport> probe() async {
    if (kIsWeb || !Platform.isIOS) {
      return MultiCamSupport.notProbedOnThisPlatform;
    }
    try {
      final supported =
          await _channel.invokeMethod<bool>('isMultiCamSupported');
      return (supported ?? false)
          ? MultiCamSupport.supported
          : MultiCamSupport.unsupported;
    } on MissingPluginException {
      // The native handler in AppDelegate.swift isn't present in this build
      // -- e.g. a `flutter test` host, or an iOS build made before that file
      // was wired up.
      return MultiCamSupport.notProbedOnThisPlatform;
    }
  }
}
