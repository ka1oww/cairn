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
import 'repositories/membership_repository.dart';
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
///
/// [membership] is the same trick for the roster, and it is the only way to
/// stand the party up at the size the product is for: this phone can write
/// exactly one member row, so a test that wants to watch eight people get
/// eight different minutes seeds the read side and leaves the write side
/// bound to the store. Bind them to two different objects in the app and the
/// trip's own surface would go blank the moment somebody renamed it.
Widget bootstrapApp({
  AppDatabase? database,
  DateTime? today,
  DateTime? now,
  Duration? utcOffset,
  CameraSource? camera,
  PhotoRepository? photos,
  MembershipRepository? membership,
}) {
  final db = database ?? openAppDatabase();
  final store = PhotoStore(db);
  final roster = MembershipStore(db);
  return ProviderScope(
    overrides: [
      tripRepositoryProvider.overrideWithValue(TripRepository(db)),
      photoRepositoryProvider.overrideWithValue(photos ?? store),
      photoStoreProvider.overrideWithValue(store),
      membershipRepositoryProvider.overrideWithValue(membership ?? roster),
      membershipStoreProvider.overrideWithValue(roster),
      if (today != null) todayProvider.overrideWithValue(today),
      if (now != null) nowProvider.overrideWithValue(now),
      if (utcOffset != null) tripUtcOffsetProvider.overrideWithValue(utcOffset),
      if (camera != null) cameraSourceProvider.overrideWithValue(camera),
    ],
    child: const CairnApp(),
  );
}
