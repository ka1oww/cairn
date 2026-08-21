// Start reading here. This file only does two Riverpod-specific things:
// wrap the app in a ProviderScope, and read totalPhotoCountProvider for the
// bottom-nav badge. Everything else (the tabs) is ordinary Flutter.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/trip_providers.dart';
import 'screens/pool_screen.dart';
import 'screens/today_screen.dart';
import 'screens/trail_screen.dart';

void main() {
  runApp(
    // ProviderScope is where Riverpod actually stores every provider's
    // state. It must wrap the whole app, exactly once, at the root —
    // without it, `ref.watch(...)` anywhere below has nothing to talk to
    // and throws. Think of it as the single source of truth every
    // ConsumerWidget in this app reads from and writes to.
    const ProviderScope(child: TripApp()),
  );
}

class TripApp extends StatelessWidget {
  const TripApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Riverpod + Drift demo',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal)),
      home: const TripHome(),
    );
  }
}

/// Hosts the three tabs (Today / Trail / Pool) behind a bottom navigation
/// bar. Ordinary `StatefulWidget` — the currently-selected tab index is
/// local UI state that nothing else in the app cares about, so it does not
/// need to be a Riverpod provider. Not every piece of state belongs in
/// Riverpod; only state that's shared across widgets that don't otherwise
/// know about each other, which is exactly the photo count and nothing else
/// in this demo.
class TripHome extends StatefulWidget {
  const TripHome({super.key});

  @override
  State<TripHome> createState() => _TripHomeState();
}

class _TripHomeState extends State<TripHome> {
  int _tabIndex = 0;

  static const _screens = [TodayScreen(), TrailScreen(), PoolScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
          const NavigationDestination(icon: Icon(Icons.route), label: 'Trail'),
          NavigationDestination(
            // This Consumer is the second of the two places the photo
            // count is displayed (the first is the "N photos today" line in
            // today_screen.dart). It's a `Consumer` rather than turning the
            // whole `TripHome` into a `ConsumerWidget`, so that only this
            // small badge rebuilds when the count changes — the tab bar
            // icons and the rest of the Scaffold around it don't need to
            // re-run just because a photo was added.
            icon: Consumer(
              builder: (context, ref, _) {
                final totalAsync = ref.watch(totalPhotoCountProvider);
                final count = totalAsync.valueOrNull ?? 0;
                return Badge(
                  label: Text('$count'),
                  isLabelVisible: count > 0,
                  child: const Icon(Icons.photo_library),
                );
              },
            ),
            label: 'Pool',
          ),
        ],
      ),
    );
  }
}
