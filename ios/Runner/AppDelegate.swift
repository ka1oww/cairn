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
    // The file-import feature's OCR edge (slice D): one hand-written
    // channel beside the generated plugins.
    TextRecognition.register(with: engineBridge.applicationRegistrar.messenger())
    // The trip clock's edge: the one fact the shared `trips` row needs that
    // Dart cannot ask the phone for itself.
    DeviceTimeZone.register(with: engineBridge.applicationRegistrar.messenger())
  }
}
