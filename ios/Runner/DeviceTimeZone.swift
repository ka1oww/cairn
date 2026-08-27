import Flutter
import Foundation

/// The trip clock's edge: this phone's own IANA time zone name, behind the
/// hand-written `cairn/time_zone` channel.
///
/// One fact, one line: `TimeZone.current.identifier` is an IANA name
/// (`Asia/Tokyo`, `Europe/Oslo`), which is what `trips.timezone` is validated
/// against on the server (`supabase/migrations/0003_trips.sql` looks it up in
/// `pg_timezone_names` at write time). Dart cannot ask for this itself:
/// `DateTime.now().timeZoneName` gives an *abbreviation* (`JST`, `GMT+8`),
/// which is not an IANA name and is not accepted there.
///
/// Deliberately not the device's UTC *offset*. A fixed offset has no daylight
/// saving in it, and `Etc/GMT±N` cannot even spell the half-hour zones a
/// billion people live in — India, Iran, South Australia, Newfoundland,
/// Nepal. The identifier carries all of that and costs nothing.
///
/// See `docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md` for why the
/// phone's zone is the trip's, and what that is and is not right about.
enum DeviceTimeZone {
  static let channelName = "cairn/time_zone"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "ianaName" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Read per call rather than cached: a phone that lands somewhere else
      // reports the zone it is in now, and this is asked once per trip.
      result(TimeZone.current.identifier)
    }
  }
}
