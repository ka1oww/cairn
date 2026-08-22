import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Answers the spike's second question for whatever device this actually
    // runs on: can this specific phone open both cameras in one
    // AVCaptureMultiCamSession? This is a runtime capability query, not a
    // device-model list, because Apple's own guidance is that hardcoding
    // model names is the wrong approach -- `isMultiCamSupported` is meant to
    // be the one source of truth.
    //
    // MEASURED, not assumed: older community guidance (repeated as recently
    // as this spike's own research pass) says this flag is "permanently
    // false" in Simulator. That is NOT what was observed here -- on Xcode
    // 26.6 / iOS 26.5 Simulator, "iPhone 17 Pro", this logged
    // `MULTICAM_PROBE_RAW_VALUE=true`. Simulators have zero real camera
    // hardware either way, so a `true` here cannot mean "a live session will
    // actually work" -- it can only mean the flag answers from the
    // simulated device's declared chip class, not from any live sensor
    // probe. Practical conclusion: do not trust this flag alone, on
    // simulator or device, as proof a session will actually start and
    // deliver frames -- see the README's findings section for what this
    // does and doesn't prove, and why only a physical device closes the
    // loop.
    let multiCamChannel = FlutterMethodChannel(
      name: "cairn.dualcamera/multicam",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    multiCamChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "isMultiCamSupported":
        let raw = AVCaptureMultiCamSession.isMultiCamSupported
        NSLog("MULTICAM_PROBE_RAW_VALUE=\(raw) model=\(UIDevice.current.model) systemVersion=\(UIDevice.current.systemVersion)")
        result(raw)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
