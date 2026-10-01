// APP STATE band (docs/architecture.md): the platform edge behind
// `NotificationEdge` (ping_schedule.dart). This is the piece that file's own
// doc comment names as the one genuinely unbuilt part of the ping -- the
// derivation, the pass and the replace-not-append rule are all real there;
// this class is what actually asks iOS to ring.
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'ping_schedule.dart';

/// The real [NotificationEdge]: registers pings as ordinary local
/// notifications through `flutter_local_notifications`.
///
/// **Ordinary alert level, always.** See [NotificationEdge]'s own doc
/// comment and `docs/decisions/2026-08-22-notification-alert-level.md`. This
/// class asks for exactly `alert` and `sound` on iOS
/// ([IOSFlutterLocalNotificationsPlugin.requestPermissions]) -- never
/// `critical`, which is the one parameter that would require Apple's
/// critical-alerts entitlement -- and delivers at
/// [InterruptionLevel.active], never `.timeSensitive` or `.critical`. On
/// iOS it requests no other permission.
///
/// **Degrades safely.** Initialisation, permission requests and scheduling
/// are all wrapped: a refused permission, a missing platform channel (no
/// native host, an unsupported OS, a plugin that has not registered) or any
/// other plugin failure is caught and logged, leaving the app with no pings
/// registered rather than crashing or hanging the registration pass that
/// `PingRegistration.build` runs on every rebuild of the schedule.
class LocalNotificationEdge implements NotificationEdge {
  LocalNotificationEdge({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  Future<void> _replacementTail = Future<void>.value();

  /// Null until the first attempt; then true or false for good, so a
  /// platform channel that is truly absent (never a transient failure -- the
  /// plugin's own `initialize` is not that kind of call) is not retried once
  /// per ping-schedule rebuild.
  bool? _initialized;

  Future<bool> _ensureInitialized() async {
    final done = _initialized;
    if (done != null) return done;
    try {
      tz_data.initializeTimeZones();
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(iOS: iosSettings),
      );
      _initialized = ok ?? true;
      if (_initialized == true) await _requestPermission();
    } catch (error, stackTrace) {
      _logRefusal('initialise', error, stackTrace);
      _initialized = false;
    }
    return _initialized ?? false;
  }

  Future<void> _requestPermission() async {
    try {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        // Ordinary alert level only -- no `critical`, no `provisional`.
        await ios.requestPermissions(alert: true, badge: false, sound: true);
      }
    } catch (error, stackTrace) {
      _logRefusal('request permission', error, stackTrace);
    }
  }

  @override
  Future<void> replaceScheduledPings(List<ScheduledPing> pings) {
    final snapshot = List<ScheduledPing>.unmodifiable(pings);
    final replacement = _replacementTail.then(
      (_) => _replaceScheduledPings(snapshot),
    );
    _replacementTail = replacement.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _logRefusal('register pings', error, stackTrace);
      },
    );
    return _replacementTail;
  }

  Future<void> _replaceScheduledPings(List<ScheduledPing> pings) async {
    if (!await _ensureInitialized()) {
      await _cancelPendingBestEffort('cancel after initialization failure');
      return;
    }
    try {
      // Cancel-then-register is the whole of the replace rule: this plugin
      // instance is the only surface in the app that ever schedules a local
      // notification, so cancelling everything it holds is cancelling
      // exactly the pings this app previously registered.
      await _plugin.cancelAll();
      for (var i = 0; i < pings.length; i++) {
        final ping = pings[i];
        await _plugin.zonedSchedule(
          id: i,
          title: ping.title,
          body: ping.body,
          scheduledDate: tz.TZDateTime.from(ping.at, tz.UTC),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          notificationDetails: const NotificationDetails(
            iOS: DarwinNotificationDetails(
              interruptionLevel: InterruptionLevel.active,
            ),
          ),
        );
      }
    } catch (error, stackTrace) {
      _logRefusal('register pings', error, stackTrace);
      await _cancelPendingBestEffort('cancel failed registration');
    }
  }

  Future<void> _cancelPendingBestEffort(String what) async {
    try {
      await _plugin.cancelAll();
    } catch (error, stackTrace) {
      _logRefusal(what, error, stackTrace);
    }
  }

  void _logRefusal(String what, Object error, StackTrace stackTrace) {
    if (kDebugMode) {
      developer.log(
        'LocalNotificationEdge could not $what; pings will not ring.',
        error: error,
        stackTrace: stackTrace,
        name: 'LocalNotificationEdge',
      );
    }
  }
}
