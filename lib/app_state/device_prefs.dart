// APP STATE band (docs/architecture.md): the phone's own preferences.
//
// Local and staying local. Which maps app somebody likes is a fact about
// their phone, not about the trip, so it is deliberately not in
// `itinerary_sync.dart`'s cargo: eight phones have no reason to agree on it,
// and pushing it would overwrite a preference somebody set on their own
// device.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/maps_handoff.dart';
import '../storage/drift/app_database.dart';

/// The maps app a handoff opens in, as stored. `google` is the default, and
/// it is the *app's* default rather than a stored value: an unset preference
/// reads null and resolves here, so nothing has to be written on first run.
class DevicePrefsRepository {
  DevicePrefsRepository(this._db);
  final AppDatabase _db;

  Stream<MapsApp> watchMapsApp() => _db.watchMapsApp().map(mapsAppFromStored);

  Future<MapsApp> readMapsApp() async =>
      mapsAppFromStored(await _db.readMapsApp());

  Future<void> writeMapsApp(MapsApp app) => _db.writeMapsApp(app.name);
}

/// Reads back a stored preference. Anything unreadable — an unset row, a
/// value written by a build that named them differently — is Google Maps,
/// which is the default a person who has never opened the setting gets.
MapsApp mapsAppFromStored(String? stored) => switch (stored) {
  'apple' => MapsApp.apple,
  'waze' => MapsApp.waze,
  _ => MapsApp.google,
};

/// What the settings row calls each of them.
String mapsAppName(MapsApp app) => switch (app) {
  MapsApp.google => 'Google Maps',
  MapsApp.apple => 'Apple Maps',
  MapsApp.waze => 'Waze',
};

final devicePrefsRepositoryProvider = Provider<DevicePrefsRepository>(
  (ref) => throw UnimplementedError('bound in bootstrap'),
);

/// The preference as the settings row draws it. It has a value from the first
/// frame — the default — so no surface has to hold a "not loaded yet" case.
final mapsAppProvider = StreamProvider<MapsApp>(
  (ref) => ref.watch(devicePrefsRepositoryProvider).watchMapsApp(),
);
