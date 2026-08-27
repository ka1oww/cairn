// APP STATE band (docs/architecture.md), platform-edge side: the phone's own
// IANA time zone, behind a seam — the same shape as camera_source.dart and
// text_recognition_edge.dart. Everything above this file asks what clock this
// phone keeps and is handed a name; nothing above it names a method channel.
//
// **Why this is a platform call at all.** Dart cannot answer it. `DateTime`
// hands out a UTC *offset* and an *abbreviation* (`JST`, `GMT+8`), and
// `trips.timezone` is validated against `pg_timezone_names` at write time
// (`supabase/migrations/0003_trips.sql`), which knows neither. A fixed offset
// is also not the same fact: it carries no daylight saving, and `Etc/GMT±N`
// cannot spell the half-hour zones India, Iran, South Australia,
// Newfoundland and Nepal live in. So the name is read from the phone, or it
// is not claimed at all.
//
// The one caller is the composition root, which assembles the shared `trips`
// row (`bootstrap.dart`). See
// `docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md`.
import 'package:flutter/services.dart';

/// Whatever can say which IANA zone this phone keeps.
abstract interface class TimeZoneEdge {
  /// `Asia/Tokyo`, or null when this phone cannot say.
  ///
  /// Null is an ordinary answer and never an error: a caller that cannot be
  /// told the zone must decline to claim one rather than guess, which is what
  /// `SyncStanding.awaitingTripRow` is for.
  Future<String?> ianaName();
}

/// The real one: `TimeZone.current.identifier` over the hand-written
/// `cairn/time_zone` channel (ios/Runner/DeviceTimeZone.swift).
class DeviceTimeZone implements TimeZoneEdge {
  const DeviceTimeZone();

  static const _channel = MethodChannel('cairn/time_zone');

  @override
  Future<String?> ianaName() async {
    try {
      final name = await _channel.invokeMethod<String>('ianaName');
      // An empty string is not a zone. Treated as "cannot say" so that the
      // one check a caller makes is for null.
      return (name == null || name.isEmpty) ? null : name;
    } on MissingPluginException {
      // No channel host — a platform this app does not run on, or a Dart-only
      // test binary. Not a fault, and never a guess.
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// The test double, and the way a build pins a zone by hand.
class FixedTimeZone implements TimeZoneEdge {
  const FixedTimeZone(this.name);

  /// An IANA name, or null to stand in for a phone that cannot say.
  final String? name;

  @override
  Future<String?> ianaName() async => name;
}
