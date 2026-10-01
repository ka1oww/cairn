import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required by flutter_local_notifications so the ping can be delivered
    // (and tapped) while the app is in the foreground.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
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
    // The anonymous account's refresh token belongs in the Keychain, not in
    // an Application Support file that can enter a device backup.
    SessionVaultChannel.register(with: engineBridge.applicationRegistrar.messenger())
  }
}
