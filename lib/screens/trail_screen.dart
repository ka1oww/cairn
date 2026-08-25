// SCREENS band (docs/architecture.md): knows app state and nothing below it.
// No repository, no store, no SQL, no parser — the view model comes from
// app_state/trail_view.dart.
//
// The Trail is the trip's front door: the whole trip at a glance, one node
// per day on a winding path, a flag on today. **The winding is the screen's
// identity**, not decoration — surfaces 1c/2a/2b draw the same path every
// time, and a straight list of days would be a different screen wearing this
// one's name. So the geometry here is faithful (alternating sides, a wide
// bezier swing, ink road behind you and dashes ahead) while the surface
// treatment stays plain: the house palette — paper, ink, coral — arrives with
// the design-system slice, so this uses the theme's own colours and the
// today-flag takes the theme's primary where the drawings put coral.
//
// Tapping a node opens `DayPage` for that day. There is no second day
// surface and building one is the thing to refuse in review.
//
// Deliberately absent: photos on a node (they do not exist yet — see
// TrailNodeState), the long-trip chapters and edge dot-scrubber, and the cat.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/trail_view.dart';
import '../app_state/trip_settings.dart';
import 'day_page.dart';
import 'trip_sheet.dart';

/// Where a node sits across the width, alternating left and right as the
/// path winds. Fractions of the available width, taken from surface 2a's
/// node centres on its 390pt frame.
const _leftOfPath = 0.30;
const _rightOfPath = 0.71;

/// The vertical distance between two nodes, and the room left above the
/// first and below the last (today's node carries a flag above it and a
/// place under it, and both must have somewhere to be).
const _stepY = 128.0;
const _padTop = 58.0;
const _padBottom = 92.0;

class TrailScreen extends ConsumerWidget {
  const TrailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trail = ref.watch(trailViewProvider);
    return Scaffold(
      body: SafeArea(
        child: switch (trail) {
          AsyncData(value: final TrailView view) => _Trail(view: view),
          AsyncData() => const SizedBox.shrink(),
          AsyncError(:final error) =>
            Center(child: Text('Failed to read: $error')),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Trail extends StatelessWidget {
  const _Trail({required this.view});

  final TrailView view;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(view: view),
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height: _padTop + (view.nodes.length - 1) * _stepY + _padBottom,
              child: _Path(view: view, width: constraints.maxWidth),
            ),
          ),
        ],
      ),
    );
  }
}

/// The trip, and where in it we are.
///
/// The design's eyebrow above this line is the trip's own name ("JAPAN,
/// JUNE"). A trip can be named now, so the name is here when there is one —
/// and absent, rather than guessed from the plan, when nobody has named it.
class _Header extends ConsumerWidget {
  const _Header({required this.view});

  final TrailView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = ref.watch(tripSettingsProvider).value?.name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (name != null)
                  Text(
                    name.toUpperCase(),
                    key: const Key('trail-trip-name'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                Text(
                  view.headline,
                  key: const Key('trail-headline'),
                  style: theme.textTheme.headlineMedium,
                ),
                if (view.detail != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    view.detail!,
                    key: const Key('trail-detail'),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const _TripSheetButton(),
        ],
      ),
    );
  }
}

/// Everything trip-level, hanging off the trail's title and never off a
/// fourth tab (surface 6e). The chevron the design grows on the title: it
/// slides `TripSheet` over the trail.
class _TripSheetButton extends StatelessWidget {
  const _TripSheetButton();

  @override
  Widget build(BuildContext context) => IconButton(
        key: const Key('trip-sheet-open'),
        icon: const Icon(Icons.expand_more),
        onPressed: () => showTripSheet(context),
      );
}

/// The path and everything standing on it.
class _Path extends StatelessWidget {
  const _Path({required this.view, required this.width});

  final TrailView view;
  final double width;

  Offset _centre(int index) => Offset(
        width * (index.isEven ? _leftOfPath : _rightOfPath),
        _padTop + index * _stepY,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final centres = [
      for (var i = 0; i < view.nodes.length; i++) _centre(i),
    ];
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _RoadPainter(
              centres: centres,
              // A segment is road already walked when the day it arrives at
              // is behind us or is today; ahead of that it is the system's
              // dashed "not yet" (surface 2a: ink to today, dashes after).
              solidSegments: _solidSegments(view.nodes),
              ink: theme.colorScheme.onSurface,
              dash: theme.colorScheme.outline,
            ),
          ),
        ),
        for (final (index, node) in view.nodes.indexed)
          ..._nodeLayer(context, node, centres[index]),
      ],
    );
  }

  List<Widget> _nodeLayer(BuildContext context, TrailNode node, Offset at) {
    final label = node.isToday || node.isNextUp ? node.place : null;
    return [
      if (node.isToday)
        Positioned(
          left: at.dx - 20,
          top: at.dy - _diameter(node) / 2 - 30,
          child: _Flag(color: Theme.of(context).colorScheme.primary),
        ),
      Positioned(
        left: at.dx - _diameter(node) / 2,
        top: at.dy - _diameter(node) / 2,
        child: _Node(node: node),
      ),
      if (label != null)
        Positioned(
          left: at.dx - 70,
          top: at.dy + _diameter(node) / 2 + 8,
          child: SizedBox(
            width: 140,
            child: Text(
              label,
              key: Key('trail-place-${node.number}'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
    ];
  }
}

/// How many leading segments are road rather than dashes.
int _solidSegments(List<TrailNode> nodes) {
  var solid = 0;
  for (var i = 1; i < nodes.length; i++) {
    if (nodes[i].state == TrailNodeState.ahead) break;
    solid++;
  }
  return solid;
}

double _diameter(TrailNode node) => switch (node) {
      TrailNode(isToday: true) => 80,
      TrailNode(state: TrailNodeState.past) => 68,
      TrailNode(isNextUp: true) => 72,
      _ => 64,
    };

/// One day on the path.
///
/// The three states are drawn apart, not merely tinted apart: a past day is a
/// solid outline on the surface's own paper, today is a filled ring in the
/// one accent colour with its numeral and the word, and a day ahead is a
/// dashed outline. `trail-node-n-<state>` is the key a test asks the state
/// through, so the distinction is asserted rather than assumed.
class _Node extends StatelessWidget {
  const _Node({required this.node});

  final TrailNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = _diameter(node);
    final accent = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: _semanticLabel(node),
      child: InkWell(
        key: Key('trail-node-${node.number}'),
        customBorder: const CircleBorder(),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => DayPage.planDay(node.number),
          ),
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            key: Key('trail-node-${node.number}-${node.state.name}'),
            painter: _NodePainter(
              state: node.state,
              isNextUp: node.isNextUp,
              accent: accent,
              ink: theme.colorScheme.onSurface,
              muted: muted,
              surface: theme.colorScheme.surface,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${node.number}',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: switch (node.state) {
                        TrailNodeState.today => theme.colorScheme.onSurface,
                        TrailNodeState.past => muted,
                        TrailNodeState.ahead =>
                          node.isNextUp ? theme.colorScheme.onSurface : muted,
                      },
                    ),
                  ),
                  if (node.isToday)
                    Text(
                      'TODAY',
                      key: const Key('trail-today-word'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.bold,
                        color: accent,
                      ),
                    )
                  // Surface 2b: before the trip, day one alone wears its
                  // weekday under its numeral.
                  else if (node.isNextUp && node.weekdayLabel != null)
                    Text(
                      node.weekdayLabel!.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.2,
                        color: muted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _semanticLabel(TrailNode node) {
  final where = node.place == null ? '' : ', ${node.place}';
  final when = node.dateLabel ?? 'date open';
  final state = switch (node.state) {
    TrailNodeState.today => 'today',
    TrailNodeState.past => 'past',
    TrailNodeState.ahead => 'ahead',
  };
  return 'Day ${node.number}$where, $when, $state';
}

class _NodePainter extends CustomPainter {
  const _NodePainter({
    required this.state,
    required this.isNextUp,
    required this.accent,
    required this.ink,
    required this.muted,
    required this.surface,
  });

  final TrailNodeState state;
  final bool isNextUp;
  final Color accent;
  final Color ink;
  final Color muted;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width / 2 - 1.5;
    // Every node sits on the paper, so the road never shows through it.
    canvas.drawCircle(centre, radius, Paint()..color = surface);

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = state == TrailNodeState.today ? 2.5 : 2
      ..color = switch (state) {
        TrailNodeState.today => accent,
        TrailNodeState.past => muted,
        TrailNodeState.ahead => isNextUp ? ink : muted,
      };

    if (state == TrailNodeState.ahead && !isNextUp) {
      // The dashed "not yet" ring — the same mark the road ahead wears.
      canvas.drawPath(_dashed(Path()..addOval(
        Rect.fromCircle(center: centre, radius: radius),
      )), ring);
      return;
    }
    canvas.drawCircle(centre, radius, ring);
  }

  @override
  bool shouldRepaint(_NodePainter old) =>
      old.state != state ||
      old.isNextUp != isNextUp ||
      old.accent != accent ||
      old.ink != ink ||
      old.muted != muted ||
      old.surface != surface;
}

/// The coral pennant of surface 2a: a short pole out of today's node and a
/// flag flying off it. The one thing on this screen that says "here".
class _Flag extends StatelessWidget {
  const _Flag({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        key: const Key('trail-flag'),
        size: const Size(40, 30),
        painter: _FlagPainter(color: color),
      );
}

class _FlagPainter extends CustomPainter {
  const _FlagPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final poleX = size.width / 2;
    canvas.drawLine(
      Offset(poleX, 2),
      Offset(poleX, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      Path()
        ..moveTo(poleX, 2)
        ..lineTo(poleX + 15, 8)
        ..lineTo(poleX, 15)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_FlagPainter old) => old.color != color;
}

/// The winding road between the nodes.
///
/// Solid ink for the days behind you, the system's dashes for the days
/// ahead — the same two marks the day page uses for the same meaning, and the
/// reason the screen reads as a journey rather than a list.
class _RoadPainter extends CustomPainter {
  const _RoadPainter({
    required this.centres,
    required this.solidSegments,
    required this.ink,
    required this.dash,
  });

  final List<Offset> centres;
  final int solidSegments;
  final Color ink;
  final Color dash;

  @override
  void paint(Canvas canvas, Size size) {
    final solid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = ink;
    final dashed = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = dash;

    for (var i = 0; i + 1 < centres.length; i++) {
      final segment = _segment(centres[i], centres[i + 1]);
      if (i < solidSegments) {
        canvas.drawPath(segment, solid);
      } else {
        canvas.drawPath(_dashed(segment), dashed);
      }
    }
  }

  /// One bend. The control points are pushed *outward* past each end, which
  /// is what gives the path the wide swing the drawings have rather than the
  /// gentle S a naive cubic produces.
  Path _segment(Offset a, Offset b) {
    final dy = b.dy - a.dy;
    final swing = (b.dx - a.dx) * 0.28;
    return Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(
        a.dx - swing,
        a.dy + dy * 0.5,
        b.dx + swing,
        b.dy - dy * 0.5,
        b.dx,
        b.dy,
      );
  }

  @override
  bool shouldRepaint(_RoadPainter old) =>
      old.solidSegments != solidSegments ||
      old.ink != ink ||
      old.dash != dash ||
      !_sameCentres(old.centres, centres);
}

bool _sameCentres(List<Offset> a, List<Offset> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The system's dash: a near-dot every nine points, the mark that means
/// "ahead" everywhere in this app and never "behind".
Path _dashed(Path source, {double dash = 2.5, double gap = 9}) {
  final out = Path();
  for (final metric in source.computeMetrics()) {
    var travelled = 0.0;
    while (travelled < metric.length) {
      final end = math.min(travelled + dash, metric.length);
      out.addPath(metric.extractPath(travelled, end), Offset.zero);
      travelled = end + gap;
    }
  }
  return out;
}
