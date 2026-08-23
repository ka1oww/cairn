// APP STATE band (docs/architecture.md): Riverpod providers. One source of
// truth per question; screens watch these and nothing below them.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/trip_repository.dart';

/// Bound to the real repository by the composition root (`bootstrap.dart`),
/// and to fakes by tests. Left unbound it throws, loudly and immediately,
/// which is the correct behaviour for a wiring mistake.
final tripRepositoryProvider = Provider<TripRepository>(
  (ref) => throw UnimplementedError(
    'tripRepositoryProvider is bound in bootstrap.dart (or a test override)',
  ),
);

/// The draft trip's working title. A Drift stream flows through this
/// provider, so a write anywhere updates every watching screen — the wiring
/// this scaffold exists to prove.
final tripNameProvider = StreamProvider<String?>(
  (ref) => ref.watch(tripRepositoryProvider).watchTripName(),
);
