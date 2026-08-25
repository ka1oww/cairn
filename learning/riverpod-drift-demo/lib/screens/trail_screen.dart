// The plain-select counterpart to the join/aggregate queries used on the
// Pool screen: this screen just lists every stop, grouped by day, with no
// counting or joining. Included so the README's "read these files in order"
// tour has something to point at as the simple baseline before the more
// interesting query in pool_screen.dart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/trip_providers.dart';

class TrailScreen extends ConsumerWidget {
  const TrailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stopsAsync = ref.watch(allStopsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Trail')),
      body: stopsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) =>
            Center(child: Text('Could not load trail: $err')),
        data: (stops) {
          // Grouping by day here, in Dart, rather than in SQL, is a
          // deliberate contrast with the GROUP BY query on the Pool screen:
          // this is fine for "list every stop" because there's no
          // computation involved, just display order. Once you need a
          // number (a count, a sum) computed from many rows, doing it in
          // Dart means pulling every row into memory first — that's the
          // case the aggregate query exists to avoid.
          final byDay = <int, List<dynamic>>{};
          for (final stop in stops) {
            byDay.putIfAbsent(stop.dayNumber, () => []).add(stop);
          }
          final days = byDay.keys.toList()..sort();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final day in days) ...[
                Text(
                  'Day $day',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                for (final stop in byDay[day]!)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.place, size: 18),
                        const SizedBox(width: 8),
                        Text(stop.name as String),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ],
          );
        },
      ),
    );
  }
}
