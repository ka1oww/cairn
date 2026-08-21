// The other half of the "one action, two places update" demo. The badge
// built in main.dart's bottom navigation bar watches the same
// totalPhotoCountProvider this screen's body does — go back to
// today_screen.dart and press the add-photo button while this tab is
// visible (or not) and both move together.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/trip_providers.dart';

class PoolScreen extends ConsumerWidget {
  const PoolScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totalAsync = ref.watch(totalPhotoCountProvider);
    final perDayAsync = ref.watch(photoCountsPerDayProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Pool')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          totalAsync.when(
            loading: () => const Text('Loading…'),
            error: (err, stack) => Text('Error: $err'),
            data: (count) => Text(
              '$count photo${count == 1 ? '' : 's'} in the pool',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 24),
          Text('Photos per day', style: Theme.of(context).textTheme.titleMedium),
          const Text(
            '(join Stops → Photos, GROUP BY day — see watchPhotoCountsPerDay in database.dart)',
            style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 8),
          perDayAsync.when(
            loading: () => const CircularProgressIndicator(),
            error: (err, stack) => Text('Error: $err'),
            data: (counts) {
              if (counts.isEmpty) {
                return const Text('No photos yet — add one from the Today tab.');
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in counts)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 60,
                            child: Text('Day ${row.dayNumber}'),
                          ),
                          Expanded(
                            // A bare-bones bar chart: width scaled against
                            // the largest count so the relative sizes read
                            // at a glance. Not a real charting widget —
                            // this demo has no design work, on purpose.
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: row.photoCount /
                                  counts
                                      .map((c) => c.photoCount)
                                      .reduce((a, b) => a > b ? a : b),
                              child: Container(
                                height: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${row.photoCount}'),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
