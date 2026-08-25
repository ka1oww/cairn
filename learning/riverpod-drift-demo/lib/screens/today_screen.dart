// Read this file second (after database.dart) if you're touring the repo —
// it's the screen where the "one action, two places update" behaviour is
// easiest to see, because the Pool tab's badge (pool_screen.dart) reacts to
// the exact same button press without either file referencing the other.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/forecast_provider.dart';
import '../providers/trip_providers.dart';

/// `ConsumerWidget` is Riverpod's replacement for `StatelessWidget`: its
/// `build` method receives a `WidgetRef` (here `ref`), which is what lets a
/// widget call `ref.watch(...)`. Everything below that calls `ref.watch`
/// gets rebuilt automatically when the watched provider changes — that's
/// the entire mechanism, there's no manual `setState` or refresh call
/// anywhere in this file.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch() subscribes this widget to todayPhotoCountProvider. Every time
    // the underlying Drift stream emits a new count (i.e. every time a
    // photo is added anywhere in the app), Riverpod re-runs this build()
    // method with the new value — which is why this line and the Pool tab's
    // badge stay in sync despite neither widget knowing the other exists.
    final todayCount = ref.watch(todayPhotoCountProvider);
    final stopsAsync = ref.watch(allStopsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Today — Day 1')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // AsyncValue.when forces you to handle all three states a stream
          // can be in: still loading (no data yet), an error, or data. This
          // is the same handling pattern the async "trip tip" card below
          // uses — StreamProvider and FutureProvider both produce
          // AsyncValue, so the same `.when` shape works for both.
          todayCount.when(
            loading: () => const Text('Loading photo count…'),
            error: (err, stack) => Text('Could not load photo count: $err'),
            data: (count) => Text(
              '$count photo${count == 1 ? '' : 's'} today',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.add_a_photo),
            label: const Text('Simulate a photo arriving'),
            // This is the entire "write" side of the demo: call the
            // database write function and do nothing else. It does not
            // touch todayCount, does not call setState, does not know the
            // Pool tab exists. Every widget watching a provider backed by
            // the `photos` table updates itself.
            onPressed: () => addTodaysPhoto(ref),
          ),
          const SizedBox(height: 24),
          Text("Today's stops", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          stopsAsync.when(
            loading: () => const CircularProgressIndicator(),
            error: (err, stack) => Text('Could not load stops: $err'),
            data: (stops) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: stops
                  .where((s) => s.dayNumber == kTodayDayNumber)
                  .map(
                    (s) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          const Icon(Icons.place, size: 18),
                          const SizedBox(width: 8),
                          Text(s.name),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 24),
          const TripTipCard(),
        ],
      ),
    );
  }
}

/// The "async data arrives later" example, isolated in its own small
/// widget. Deliberately kept separate from the photo-count logic above so
/// it's obvious this is a second, independent lesson: a `FutureProvider`
/// that starts loading, then resolves to either data or an error.
class TripTipCard extends ConsumerWidget {
  const TripTipCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tip = ref.watch(tripTipProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lightbulb_outline),
                const SizedBox(width: 8),
                Text(
                  'Trip tip',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Fetch another tip',
                  // ref.invalidate() throws away the cached AsyncValue and
                  // re-runs the provider's callback from scratch, which
                  // means the UI drops back to the loading state before the
                  // new (randomly pass/fail) Future resolves — this is how
                  // you get a manual "retry" for a FutureProvider.
                  onPressed: () => ref.invalidate(tripTipProvider),
                ),
              ],
            ),
            const SizedBox(height: 8),
            tip.when(
              loading: () => const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Fetching a tip from the "server"…'),
                ],
              ),
              error: (err, stack) => Text(
                '$err',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              data: (text) => Text(text),
            ),
          ],
        ),
      ),
    );
  }
}
