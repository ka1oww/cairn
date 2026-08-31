import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/maps_handoff.dart';
import '../storage/drift/app_database.dart';

final devicePrefsRepositoryProvider = Provider<DevicePrefsRepository>(
  (ref) => throw UnimplementedError('bound in bootstrap'),
);

class DevicePrefsRepository {
  DevicePrefsRepository(this._db);
  final AppDatabase _db;

  Future<String?> readMapsApp() => _db.readMapsApp();
  Future<void> writeMapsApp(String? app) => _db.writeMapsApp(app);
  Stream<String?> watchMapsApp() =>
      (_db.select(_db.appPreferences)..where((t) => t.id.equals(1))).watchSingleOrNull().map((r) => r?.mapsApp);
}

String mapsAppToString(MapsApp app) => switch (app) {
  MapsApp.googleMaps => 'googleMaps',
  MapsApp.appleMaps => 'appleMaps',
  MapsApp.waze => 'waze',
};

MapsApp mapsAppFromString(String? raw) => switch (raw) {
  'appleMaps' => MapsApp.appleMaps,
  'waze' => MapsApp.waze,
  _ => MapsApp.googleMaps,
};

final mapsAppPrefProvider = StreamProvider<MapsApp>((ref) {
  final repo = ref.watch(devicePrefsRepositoryProvider);
  return repo.watchMapsApp().map((raw) => mapsAppFromString(raw));
});


