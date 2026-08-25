// SCREENS band (docs/architecture.md): knows app state and nothing below it.
//
// The container. The app's destinations are tabs, not a stack you navigate
// out of — Today, the Trail and the Pool, which is design surface 2e's whole
// structure. The Pool was absent rather than greyed out until it existed; it
// exists now, and it arrived the way that comment promised — one entry in
// `_destinations` and one root widget. The principle stands for whatever is
// next: a greyed-out tab is chrome for a thing that does not exist.
//
// Trip-level actions hang off the Trail's own title and never off a tab
// (surface 6e, "off the trail's title, never a fourth tab"); the temporary
// route back to the paste box lives there now.
//
// Each tab owns a `Navigator`, so a day page opened from the Trail is still
// open when you come back from Today. That is what "the Trail is the front
// door" means in navigation terms: switching destinations never throws away
// where you were inside one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/day_view.dart';
import 'day_page.dart';
import 'pool_screen.dart';
import 'trail_screen.dart';

/// One tab of the container.
typedef _Destination = ({String label, IconData icon, Widget root});

const _destinations = <_Destination>[
  (label: 'Today', icon: Icons.wb_sunny_outlined, root: _TodayTab()),
  (label: 'Trail', icon: Icons.route_outlined, root: TrailScreen()),
  (label: 'Pool', icon: Icons.grid_view_outlined, root: PoolScreen()),
];

class TripShell extends StatefulWidget {
  const TripShell({super.key});

  @override
  State<TripShell> createState() => _TripShellState();
}

class _TripShellState extends State<TripShell> {
  /// The app opens on Today. The Trail is the trip's front door in the sense
  /// that it is where the whole trip lives; the day you are standing in is
  /// still what you want first thing in the morning.
  int _index = 0;

  final _navigators = [
    for (final _ in _destinations) GlobalKey<NavigatorState>(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (final (i, destination) in _destinations.indexed)
            Navigator(
              key: _navigators[i],
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (context) => destination.root,
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        key: const Key('tab-bar'),
        selectedIndex: _index,
        // Tapping the tab you are already on returns to that tab's root —
        // the standard way out of a pushed day page without a gesture.
        onDestinationSelected: (next) {
          if (next == _index) {
            _navigators[next].currentState?.popUntil((route) => route.isFirst);
          }
          setState(() => _index = next);
        },
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              key: Key('tab-${destination.label.toLowerCase()}'),
              icon: Icon(destination.icon),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}

/// Today is not a screen of its own: it is the day page, opened on today's
/// date. Days advance by the clock and never by completing anything, so this
/// is the whole of it.
class _TodayTab extends ConsumerWidget {
  const _TodayTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      DayPage(date: ref.watch(todayProvider));
}
