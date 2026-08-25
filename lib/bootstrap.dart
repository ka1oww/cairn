// The composition root: the one file allowed to know every layer, because
// something has to assemble the stack in dependency order. The map's rule
// ("a layer may only know the layers beneath it", docs/architecture.md)
// governs the layers; this file is where the layers are put together, and
// confining that knowledge here is what keeps it out of everywhere else.
// See lib/README.md.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app_state/camera_source.dart';
import 'app_state/day_view.dart';
import 'app_state/ping_schedule.dart';
import 'app_state/trip_providers.dart';
import 'repositories/photo_repository.dart';
import 'repositories/trip_repository.dart';
import 'storage/drift/app_database.dart';

/// Builds the whole app: storage → seam → providers → shell.
///
/// [database] exists for tests, which pass an in-memory database instead of
/// the on-device file. [today] likewise: a widget test pins the date the day
/// page reads, because a page deriving today from the real device clock
/// would otherwise assert different things in June 2027 than it does now.
/// [now] and [utcOffset] pin the other two clock reads for the same reason —
/// a test that walked the capture window against the real wall clock would
/// pass or fail by the hour it ran at. [camera] lets a test hand the flow a
/// frame without a device; the app takes [DeviceCameraSource], which is the
/// real back camera on a phone and the stand-in where there is no camera.
///
/// [photos] overrides the **read** side of the pool alone, for a test that
/// wants a pool of a known shape without writing one. The app passes nothing
/// and both sides are bound to the same [PhotoStore], which is what makes the
/// photo capture writes the photo the Pool draws — the two features share a
/// store, not a wire between them.
Widget bootstrapApp({
  AppDatabase? database,
  DateTime? today,
  DateTime? now,
  Duration? utcOffset,
  CameraSource? camera,
  PhotoRepository? photos,
}) {
  final db = database ?? openAppDatabase();
  final store = PhotoStore(db);
  return ProviderScope(
    overrides: [
      tripRepositoryProvider.overrideWithValue(TripRepository(db)),
      photoRepositoryProvider.overrideWithValue(photos ?? store),
      photoStoreProvider.overrideWithValue(store),
      if (today != null) todayProvider.overrideWithValue(today),
      if (now != null) nowProvider.overrideWithValue(now),
      if (utcOffset != null) tripUtcOffsetProvider.overrideWithValue(utcOffset),
      if (camera != null) cameraSourceProvider.overrideWithValue(camera),
    ],
    child: const CairnApp(),
  );
}
