// The composition root: the one file allowed to know every layer, because
// something has to assemble the stack in dependency order. The map's rule
// ("a layer may only know the layers beneath it", docs/architecture.md)
// governs the layers; this file is where the layers are put together, and
// confining that knowledge here is what keeps it out of everywhere else.
// See lib/README.md.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app_state/day_view.dart';
import 'app_state/trip_providers.dart';
import 'repositories/trip_repository.dart';
import 'storage/drift/app_database.dart';

/// Builds the whole app: storage → seam → providers → shell.
///
/// [database] exists for tests, which pass an in-memory database instead of
/// the on-device file. [today] likewise: a widget test pins the date the day
/// page reads, because a page deriving today from the real device clock
/// would otherwise assert different things in June 2027 than it does now.
Widget bootstrapApp({AppDatabase? database, DateTime? today}) {
  final db = database ?? openAppDatabase();
  return ProviderScope(
    overrides: [
      tripRepositoryProvider.overrideWithValue(TripRepository(db)),
      if (today != null) todayProvider.overrideWithValue(today),
    ],
    child: const CairnApp(),
  );
}
