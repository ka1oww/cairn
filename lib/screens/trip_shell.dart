// SCREENS band (docs/architecture.md): knows app state and nothing below it.
//
// The container. The app's destinations are tabs, not a stack you navigate
// out of — Today, the Trail and the Pool, which is design surface 2e's whole
// structure. The Pool was absent rather than greyed out until it existed; it
// exists now, and it arrived the way that comment promised — one entry in
// `_destinations` and one root widget. The principle stands for whatever is
// next: a greyed-out tab is chrome for a thing that does not exist — which is
// also why the drawn bar's Book tab (frame 5b) is not here: the captain kept
// the built three-tab shape (2026-08-28), and the Book gets no tab while it
// stays unbuilt.
//
// The bar's skin is frame 5b's, token for token: a sticker pill floating on
// the paper (radius 18, the 0-1-4 lift), each tab a column of a 22px
// stroke-drawn icon, a 10.5px bold Atkinson Hyperlegible label and a 4px
// coral dot, the active tab washed `#EFE3D2` at radius 12 and inked, the
// rest muted. The dot is the only coral in the bar — coral marks where you
// stand, never a count. The icons are drawn here as paths rather than taken
// from the Material set because the house iconography is 2px round-capped
// strokes on a 24 grid, which no glyph font carries; Trail and Pool trace
// 5b's own SVG paths, and Today — a tab 5b did not draw — is a flag in the
// same vocabulary, because the today-flag is what marks today everywhere
// else in the system.
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
import '../app_state/ping_schedule.dart';
import 'day_page.dart';
import 'house_style.dart';
import 'pool_screen.dart';
import 'trail_screen.dart';

/// One tab of the container. The icon is a constructor tear-off so the list
/// stays const while each tab can be drawn in the ink its state calls for.
typedef _Destination = ({
  String label,
  CustomPainter Function(Color ink) icon,
  Widget root,
});

const _destinations = <_Destination>[
  (label: 'Today', icon: _TodayFlagIcon.new, root: _TodayTab()),
  (label: 'Trail', icon: _TrailPathIcon.new, root: TrailScreen()),
  (label: 'Pool', icon: _PoolGridIcon.new, root: PoolScreen()),
];

class TripShell extends ConsumerStatefulWidget {
  const TripShell({super.key});

  @override
  ConsumerState<TripShell> createState() => _TripShellState();
}

class _TripShellState extends ConsumerState<TripShell> {
  /// The app opens on Today. The Trail is the trip's front door in the sense
  /// that it is where the whole trip lives; the day you are standing in is
  /// still what you want first thing in the morning.
  int _index = 0;

  final _navigators = [
    for (final _ in _destinations) GlobalKey<NavigatorState>(),
  ];

  @override
  Widget build(BuildContext context) {
    // Registering the pings is a side effect of the trip existing, not of any
    // one screen. The container is the only thing that is on screen for the
    // whole of a trip, so this is where the schedule is kept in step: watching
    // it re-registers whenever the deal changes, and not when the clock moves.
    // See `pingRegistrationProvider`.
    ref.watch(pingRegistrationProvider);
    return Scaffold(
      // The paper the bar floats on. Each tab's own screen paints its whole
      // body, so this ground shows only around the bar itself.
      backgroundColor: housePaper,
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
      bottomNavigationBar: SafeArea(
        // 20 is the drawn sheet's own margin around the bar; 8 keeps the pill
        // off the content above and off the very edge on a home-button phone,
        // and the safe inset takes over below when it is larger.
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: _HouseTabBar(
          key: const Key('tab-bar'),
          index: _index,
          // Tapping the tab you are already on returns to that tab's root —
          // the standard way out of a pushed day page without a gesture.
          onSelect: (next) {
            if (next == _index) {
              _navigators[next].currentState?.popUntil(
                (route) => route.isFirst,
              );
            }
            setState(() => _index = next);
          },
        ),
      ),
    );
  }
}

/// Frame 5b's bar: a sticker pill, one washed tab, everything else muted.
class _HouseTabBar extends StatelessWidget {
  const _HouseTabBar({super.key, required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: houseSticker,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: houseStickerShadow,
            offset: Offset(0, 1),
            blurRadius: 4,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        child: Row(
          children: [
            for (final (i, destination) in _destinations.indexed) ...[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: _HouseTab(
                  destination: destination,
                  selected: i == index,
                  onTap: () => onSelect(i),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HouseTab extends StatelessWidget {
  const _HouseTab({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final slug = destination.label.toLowerCase();
    final ink = selected ? houseInk : houseMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          key: Key('tab-$slug'),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: selected
              ? BoxDecoration(
                  color: houseWash,
                  borderRadius: BorderRadius.circular(12),
                )
              : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size.square(22),
                painter: destination.icon(ink),
              ),
              const SizedBox(height: 3),
              Text(
                destination.label,
                style: TextStyle(
                  fontFamily: houseTextFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 10.5,
                  color: ink,
                ),
              ),
              const SizedBox(height: 3),
              // The dot keeps its 4px seat on every tab so the columns stay
              // level; only the tab you stand on fills it coral.
              SizedBox(
                width: 4,
                height: 4,
                child: selected
                    ? DecoratedBox(
                        key: Key('tab-$slug-dot'),
                        decoration: const BoxDecoration(
                          color: houseCoral,
                          shape: BoxShape.circle,
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The house icon stroke: 2px, round-capped, on a 24-unit grid, scaled to
/// the box it is painted into. Each subclass supplies its path in grid units.
abstract class _StrokeIcon extends CustomPainter {
  const _StrokeIcon(this.ink);

  final Color ink;

  Path gridPath();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = ink;
    canvas.drawPath(
      gridPath().transform(
        (Matrix4.identity()..scaleByDouble(scale, scale, scale, 1)).storage,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _StrokeIcon oldDelegate) =>
      oldDelegate.ink != ink;
}

/// Today: the today-flag, drawn in the bar's own vocabulary — the pole and a
/// banner whose edges wave the way frame 5b's book covers do.
class _TodayFlagIcon extends _StrokeIcon {
  const _TodayFlagIcon(super.ink);

  @override
  Path gridPath() => Path()
    ..moveTo(6, 21)
    ..lineTo(6, 4)
    ..cubicTo(9.5, 2.5, 13.5, 2.5, 17, 4)
    ..lineTo(17, 12)
    ..cubicTo(13.5, 10.5, 9.5, 10.5, 6, 12);
}

/// Trail: frame 5b's winding path (`M6 4c6 2 8 3 6 6s-8 3-6 6 8 3 6 6`).
class _TrailPathIcon extends _StrokeIcon {
  const _TrailPathIcon(super.ink);

  @override
  Path gridPath() => Path()
    ..moveTo(6, 4)
    ..cubicTo(12, 6, 14, 7, 12, 10)
    ..cubicTo(10, 13, 4, 13, 6, 16)
    ..cubicTo(8, 19, 14, 19, 12, 22);
}

/// Pool: frame 5b's four tiles (`M4 4h7v7H4z` and its three siblings).
class _PoolGridIcon extends _StrokeIcon {
  const _PoolGridIcon(super.ink);

  @override
  Path gridPath() => Path()
    ..addRect(const Rect.fromLTWH(4, 4, 7, 7))
    ..addRect(const Rect.fromLTWH(13, 4, 7, 7))
    ..addRect(const Rect.fromLTWH(4, 13, 7, 7))
    ..addRect(const Rect.fromLTWH(13, 13, 7, 7));
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
