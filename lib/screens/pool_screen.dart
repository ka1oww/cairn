// SCREENS band (docs/architecture.md): knows app state and nothing below it.
// No repository, no store, no SQL — the view model comes from
// app_state/pool_view.dart.
//
// The Pool is the trip's shared photo pool: every photo everyone took, in one
// place everybody can see, grouped by day and read newest first. **It is
// plumbing** (`docs/decisions/2026-08-21-first-calls.md`) — plain, correct and
// fast, and explicitly not a place to spend design effort. So this is the
// structure and the states, in the theme's own colours: the house palette, the
// sticker treatment and the taker's initial chip belong to the design-system
// slice, and inventing them here would be inventing the surface twice.
//
// The three states are all real. An empty pool is a written line, not a
// skeleton grid and not a nag — the same rule the day page's "nothing planned"
// follows. A tile whose bytes are not on this phone is drawn as a tile waiting
// for them: in a pool eight people share, a photo is a real row here long
// before its bytes arrive, and that is a permanent state of the product rather
// than a stub. And a day the gate holds shut — only ever the day being lived,
// only until you add yours — keeps its heading, its date and its count and
// withholds its pictures, because a shut gate shows the shape of the day
// obscured rather than hiding that anything happened
// (`docs/decisions/2026-08-22-design-calls.md` §4). It says so in a line, so
// blank tiles read as withheld rather than as broken.
//
// Deliberately absent: the taker's initial chip (no roster is stored — see
// `pool_view.dart`), the dashed "+" tile (an invitation to a capture screen
// that does not exist), and opening a photo full-screen, which is a surface
// nobody has drawn.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/pool_view.dart';
import 'photo_frame.dart';

class PoolScreen extends ConsumerWidget {
  const PoolScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pool = ref.watch(poolViewProvider);
    return Scaffold(
      body: SafeArea(
        child: switch (pool) {
          AsyncData(value: final PoolView view) => _Pool(view: view),
          AsyncData() => const SizedBox.shrink(),
          AsyncError(:final error) => Center(
            child: Text('Failed to read: $error'),
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Pool extends StatelessWidget {
  const _Pool({required this.view});

  final PoolView view;

  @override
  Widget build(BuildContext context) {
    // Slivers rather than a list of shrink-wrapped grids: a pool is the one
    // screen in this app that can hold a thousand things — eight people over a
    // fortnight — and the decision that made it plumbing asked for fast. A
    // grid inside a `ListView` builds every tile of every day at once; this
    // builds the ones you are looking at.
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
          sliver: SliverToBoxAdapter(
            child: _Header(countLabel: view.countLabel),
          ),
        ),
        if (view.isEmpty)
          const SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverToBoxAdapter(child: _EmptyPool()),
          )
        else
          for (final day in view.days) ..._daySlivers(day),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}

/// The trip's whole pool, and how much of it there is.
class _Header extends StatelessWidget {
  const _Header({required this.countLabel});

  final String? countLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            'The Pool',
            key: const Key('pool-headline'),
            style: theme.textTheme.headlineMedium,
          ),
        ),
        if (countLabel != null)
          Text(
            countLabel!,
            key: const Key('pool-count'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// One day of the trip: the day it is, then the photos that landed on it.
List<Widget> _daySlivers(PoolDay day) => [
  SliverPadding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
    sliver: SliverToBoxAdapter(child: _DayHeading(day: day)),
  ),
  SliverPadding(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 22),
    sliver: SliverGrid.count(
      crossAxisCount: 3,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        for (final photo in day.photos)
          _Tile(photo: photo, isWithheld: !day.isOpen),
      ],
    ),
  ),
];

/// Which day this is, and how much of it there is.
class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.day});

  final PoolDay day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      key: Key('pool-day-${day.number}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              day.number.toString().padLeft(2, '0'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                day.title,
                key: Key('pool-day-${day.number}-title'),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              day.detail,
              key: Key('pool-day-${day.number}-detail'),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
        const SizedBox(height: 2),
        // A day accepted with its date still open says so rather than
        // wearing a date nobody gave it — the day page's own spelling.
        Text(
          day.dateLabel ?? 'date open',
          key: Key('pool-day-${day.number}-date'),
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        // Why the tiles below are blank. Without it a shut day is
        // indistinguishable from a day whose bytes have not arrived, and the
        // gate reads as a fault instead of an invitation.
        if (!day.isOpen) ...[
          const SizedBox(height: 4),
          Text(
            'Shut until you add yours.',
            key: Key('pool-day-${day.number}-shut'),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ],
    );
  }
}

/// One photo.
///
/// `pool-photo-<id>-image`, `pool-photo-<id>-awaiting` and
/// `pool-photo-<id>-withheld` are the keys a test asks the tile's state
/// through, so "the bytes are here", "the bytes are not here yet" and "this
/// day is not yours to see yet" are asserted apart rather than assumed. The
/// last two look alike on purpose — both are a tile with no picture in it —
/// which is exactly why they are not allowed to be the same key.
class _Tile extends StatelessWidget {
  const _Tile({required this.photo, required this.isWithheld});

  final PoolPhoto photo;

  /// The gate holds this photo's day shut. [PoolPhoto.imagePath] is null on
  /// such a tile whether or not the bytes are on this phone — the screen is
  /// never handed a path it is meant not to use.
  final bool isWithheld;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = photo.imagePath;
    return Container(
      key: Key('pool-photo-${photo.id}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: switch ((isWithheld, path)) {
        (true, _) => _Blank(
          icon: Icons.visibility_off_outlined,
          iconKey: Key('pool-photo-${photo.id}-withheld'),
        ),
        (false, null) => _Blank(
          icon: Icons.photo_outlined,
          iconKey: Key('pool-photo-${photo.id}-awaiting'),
        ),
        // Through [PhotoFrame], never `Image.file` directly: the file is
        // the original the pool keeps, and a tile this size decodes a tile's
        // worth of it. See lib/screens/photo_frame.dart.
        (false, final String here) => PhotoFrame(
          file: File(here),
          imageKey: Key('pool-photo-${photo.id}-image'),
          fit: BoxFit.cover,
        ),
      },
    );
  }
}

/// A tile with no picture in it — either because the bytes are not here or
/// because the gate is holding the day shut. Which one it is, is the icon and
/// its key.
class _Blank extends StatelessWidget {
  const _Blank({required this.icon, required this.iconKey});

  final IconData icon;
  final Key iconKey;

  @override
  Widget build(BuildContext context) => Center(
    child: Icon(
      icon,
      key: iconKey,
      size: 20,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// An empty pool is a written state, not an empty grid — the same rule the
/// day page's "nothing planned" follows. No skeleton tiles, and no nagging:
/// the pool fills because people answer their ping, never because a screen
/// asked them to.
class _EmptyPool extends StatelessWidget {
  const _EmptyPool();

  @override
  Widget build(BuildContext context) => Text(
    'Nothing in the pool yet. Everyone\'s photos land here.',
    key: const Key('pool-empty'),
    style: Theme.of(context).textTheme.titleMedium,
  );
}
