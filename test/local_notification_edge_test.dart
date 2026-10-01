// Exercises LocalNotificationEdge against a fake of the plugin's own
// platform channel ('dexterous.com/flutter/local_notifications') rather than
// a real device -- the replace-not-append rule and the degrade-safely paths
// are the only things this seam promises, and both are channel-level
// behaviour.
import 'dart:async';

import 'package:cairn/app_state/local_notification_edge.dart';
import 'package:cairn/app_state/ping_schedule.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

List<ScheduledPing> _pings(List<DateTime> instants) => [
  for (final at in instants)
    ScheduledPing(at: at, title: 'Cairn now', body: "Look up."),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('replace, not append', () {
    test('cancels every prior ping before registering new ones', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'initialize':
                return true;
              case 'requestPermissions':
                return true;
              default:
                return null;
            }
          });

      final edge = LocalNotificationEdge(
        plugin: FlutterLocalNotificationsPlugin(),
      );

      final first = DateTime.utc(2027, 6, 14, 8);
      final second = DateTime.utc(2027, 6, 15, 9);
      await edge.replaceScheduledPings(_pings([first, second]));

      expect(calls.map((c) => c.method), containsAllInOrder(['cancelAll']));
      final firstBatchSchedules = calls
          .where((c) => c.method == 'zonedSchedule')
          .toList();
      expect(firstBatchSchedules, hasLength(2));

      calls.clear();

      // A second, narrower deal — one ping, not two — must leave nothing
      // of the first deal behind: a real device firing both would be the
      // two-interruptions-in-a-day bug the interface's doc comment names.
      final third = DateTime.utc(2027, 6, 16, 10);
      await edge.replaceScheduledPings(_pings([third]));

      expect(calls.first.method, 'cancelAll');
      final secondBatchSchedules = calls
          .where((c) => c.method == 'zonedSchedule')
          .toList();
      expect(secondBatchSchedules, hasLength(1));
    });

    test(
      'serializes overlapping replacements so the latest deal wins',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        IOSFlutterLocalNotificationsPlugin.registerWith();

        final calls = <MethodCall>[];
        final firstScheduleStarted = Completer<void>();
        final releaseFirstSchedule = Completer<void>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              calls.add(call);
              switch (call.method) {
                case 'initialize':
                  return true;
                case 'requestPermissions':
                  return true;
                case 'zonedSchedule':
                  if (!firstScheduleStarted.isCompleted) {
                    firstScheduleStarted.complete();
                    await releaseFirstSchedule.future;
                  }
                  return null;
                default:
                  return null;
              }
            });

        final edge = LocalNotificationEdge(
          plugin: FlutterLocalNotificationsPlugin(),
        );
        final firstReplacement = edge.replaceScheduledPings(
          _pings([DateTime.utc(2027, 6, 14, 8), DateTime.utc(2027, 6, 15, 9)]),
        );
        await firstScheduleStarted.future;

        final latestReplacement = edge.replaceScheduledPings(
          _pings([DateTime.utc(2027, 6, 16, 10)]),
        );
        await Future<void>.delayed(Duration.zero);
        final cancelsWhileFirstScheduleBlocked = calls
            .where((call) => call.method == 'cancelAll')
            .length;

        releaseFirstSchedule.complete();
        await Future.wait([firstReplacement, latestReplacement]);

        expect(cancelsWhileFirstScheduleBlocked, 1);
        expect(calls.map((call) => call.method), [
          'initialize',
          'requestPermissions',
          'cancelAll',
          'zonedSchedule',
          'zonedSchedule',
          'cancelAll',
          'zonedSchedule',
        ]);
      },
    );
  });

  group('degrades safely', () {
    test('when the platform asks for the ordinary alert level only', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();

      final permissionCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'initialize') return true;
            if (call.method == 'requestPermissions') {
              permissionCalls.add(call);
            }
            return true;
          });

      final edge = LocalNotificationEdge(
        plugin: FlutterLocalNotificationsPlugin(),
      );
      await edge.replaceScheduledPings(_pings([DateTime.utc(2027, 6, 14, 8)]));

      expect(permissionCalls, hasLength(1));
      final arguments =
          permissionCalls.single.arguments as Map<dynamic, dynamic>;
      expect(arguments['alert'], isTrue);
      expect(arguments['sound'], isTrue);
      // The bug to refuse: this must never flip true, and never carry the
      // Focus-mode-piercing entitlement request that comes with it.
      expect(arguments['critical'], isFalse);
      expect(arguments['provisional'], isFalse);
    });

    test('when permission is refused, without throwing or hanging', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            switch (call.method) {
              case 'initialize':
                return true;
              case 'requestPermissions':
                return false;
              default:
                return null;
            }
          });

      final edge = LocalNotificationEdge(
        plugin: FlutterLocalNotificationsPlugin(),
      );

      await expectLater(
        edge.replaceScheduledPings(_pings([DateTime.utc(2027, 6, 14, 8)])),
        completes,
      );
    });

    test(
      'when the platform channel is unavailable, without throwing or hanging',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        IOSFlutterLocalNotificationsPlugin.registerWith();
        // No mock handler installed at all: every invokeMethod call throws
        // MissingPluginException, the same shape a device with no native host
        // registered would produce.

        final edge = LocalNotificationEdge(
          plugin: FlutterLocalNotificationsPlugin(),
        );

        await expectLater(
          edge.replaceScheduledPings(_pings([DateTime.utc(2027, 6, 14, 8)])),
          completes,
        );

        // A second call after the failed first must not retry `initialize`
        // forever, but it still must not throw.
        await expectLater(
          edge.replaceScheduledPings(_pings([DateTime.utc(2027, 6, 15, 8)])),
          completes,
        );
      },
    );

    test(
      'when initialize itself throws, without throwing or hanging',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        IOSFlutterLocalNotificationsPlugin.registerWith();

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              if (call.method == 'initialize') {
                throw PlatformException(code: 'unavailable');
              }
              return null;
            });

        final edge = LocalNotificationEdge(
          plugin: FlutterLocalNotificationsPlugin(),
        );

        await expectLater(
          edge.replaceScheduledPings(_pings([DateTime.utc(2027, 6, 14, 8)])),
          completes,
        );
      },
    );
  });
}
