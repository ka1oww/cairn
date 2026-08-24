// SCREENS band (docs/architecture.md): knows app state and nothing below it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/trip_providers.dart';

/// The deliberate placeholder after accepting: proof the itinerary was
/// persisted, read back from the local store through the whole stack. Today,
/// the Trail, the pool and capture are later slices — this screen's only job
/// is to still be here after a relaunch.
class TripSavedScreen extends ConsumerWidget {
  const TripSavedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final summary = ref.watch(savedItineraryProvider).value;
    if (summary == null) {
      // Only reachable in the instant the itinerary is being replaced; the
      // root screen owns the empty and error states.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final counts = [
      '${summary.dayCount} ${summary.dayCount == 1 ? 'day' : 'days'}',
      '${summary.stopCount} ${summary.stopCount == 1 ? 'stop' : 'stops'}',
      if (summary.starredCount > 0) '${summary.starredCount} starred',
    ].join(' · ');
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('The plan is on this phone.',
                style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              counts,
              key: const Key('saved-summary'),
              style: theme.textTheme.bodyMedium,
            ),
            if (summary.keptAsideCount > 0)
              Text(
                '${summary.keptAsideCount} '
                '${summary.keptAsideCount == 1 ? 'line' : 'lines'} kept '
                'aside, with reasons.',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 14),
            for (final day in summary.days)
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        day.number.toString().padLeft(2, '0'),
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: theme.colorScheme.primary),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child:
                            Text(day.title, style: theme.textTheme.titleSmall),
                      ),
                      Text(
                        [
                          if (day.dateLabel != null) day.dateLabel!,
                          '${day.stopCount} '
                              '${day.stopCount == 1 ? 'stop' : 'stops'}',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Text(
              'Today, the Trail and the pool arrive in later slices. This '
              'screen exists to prove the plan survives a relaunch.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
