// A standalone example of the "async data arrives later" pattern, separate
// from the Drift-backed providers in trip_providers.dart. The real app's
// server-fetched data (e.g. a weather forecast, or a friend's live location)
// looks exactly like this: nothing to show at first, then either a value or
// an error some time later.
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Simulates fetching a one-line trip tip from a server: an artificial
/// delay, then either a result or a thrown error.
///
/// `FutureProvider` is what turns a plain `Future<String>` into something a
/// widget can watch as loading/data/error — see `TripTipCard` in
/// today_screen.dart for the `.when(...)` that consumes this. The provider
/// itself has no knowledge of AsyncValue, loading spinners, or error text;
/// Riverpod derives all of that from the Future's lifecycle automatically.
final tripTipProvider = FutureProvider<String>((ref) async {
  await Future<void>.delayed(const Duration(seconds: 2));

  // Randomly fail about a third of the time, purely so the error branch of
  // `.when(...)` in the UI is reachable without editing code — refresh the
  // provider (see the retry button) a few times to see both outcomes.
  if (Random().nextInt(3) == 0) {
    throw Exception('Could not reach the trip-tips server (simulated).');
  }

  const tips = [
    'Pack a portable charger — the cliffside trail has no outlets.',
    'The harbour breakfast spot fills up before 8am on weekends.',
    'Cell coverage drops near the lighthouse; download offline maps first.',
  ];
  return tips[Random().nextInt(tips.length)];
});
