// SCREENS band (docs/architecture.md): the one place a stored photograph is
// turned into pixels on a screen.
//
// **The stored file is the original, and nothing here writes.** The pool
// keeps the frame the sensor gave, untouched
// (docs/decisions/2026-08-22-grill-round-one.md §3, and the full-size
// handover promise it upholds). Every smaller size the app shows is
// *derived*, at decode time, from that same file: a tile 110 points wide
// decodes 110 points' worth of pixels and throws the rest away for this
// frame only. No surface downsizes, re-encodes or replaces what is on disk,
// and none may.
//
// Why it is one file rather than a `cacheWidth:` at each call site: two call
// sites are two chances to forget, and forgetting is invisible — a full 12
// megapixel decode behind a thumbnail looks exactly right and costs about
// 48 MB of image cache per tile. A grid of them is how iOS kills the app.
// So the rule is written once, here, and every photo surface goes through
// [PhotoFrame].
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The largest edge, in device pixels, any surface will decode a stored
/// photograph to.
///
/// A ceiling rather than a target: it exists so that an unbounded layout box
/// — or a future surface on a very dense display — cannot ask for a decode
/// the size of the original by accident. Full-screen review on today's
/// densest phone is comfortably under it, so in practice nothing is ever
/// clamped by this number; it is the backstop, not the rule.
const int maxDisplayDecodeEdge = 2048;

/// How many device pixels wide to decode a photograph that will be drawn
/// across [logicalEdge] logical pixels.
///
/// Rounds up, never down: a spare row of pixels costs almost nothing and a
/// missing one is a photograph drawn visibly soft.
///
/// An unbounded or nonsensical edge (an infinite constraint, a zero-height
/// sliver mid-layout) falls back to [maxEdge] rather than to nothing — a
/// photograph that will not draw is a worse failure than one decoded larger
/// than it needed to be. Nothing is ever *upscaled* by this: Flutter's
/// `cacheWidth` does not enlarge a smaller original.
int displayDecodeWidth({
  required double logicalEdge,
  required double devicePixelRatio,
  int maxEdge = maxDisplayDecodeEdge,
}) {
  if (!logicalEdge.isFinite || logicalEdge <= 0) return maxEdge;
  final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  final pixels = (logicalEdge * ratio).ceil();
  return math.max(1, math.min(pixels, maxEdge));
}

/// The widest a photograph can actually be drawn in a box of
/// [maxWidth] × [maxHeight] under [fit], in logical pixels — or null when
/// resizing the decode would change the picture rather than just its
/// resolution.
///
/// The fit has to be consulted, and getting this wrong is silent in both
/// directions. `BoxFit.cover` scales until the box is *covered*, so a
/// landscape frame in a tall box is drawn wider than the box and decoding to
/// the box's width alone would show it soft. `BoxFit.contain` fits the frame
/// *inside*, so it is never drawn wider than the box, and taking the longest
/// edge there would decode a full-height sheet at its height — several times
/// the pixels it can possibly use.
///
/// `BoxFit.none` is the one that gets null. It draws the image at whatever
/// size it decoded to, so a smaller decode is a smaller picture on screen,
/// not the same picture more cheaply.
double? governingEdge(BoxFit fit, double maxWidth, double maxHeight) =>
    switch (fit) {
      BoxFit.cover || BoxFit.fitHeight => math.max(maxWidth, maxHeight),
      BoxFit.contain ||
      BoxFit.fill ||
      BoxFit.fitWidth ||
      BoxFit.scaleDown => maxWidth,
      BoxFit.none => null,
    };

/// A stored photograph, drawn at a size derived from the box it lands in.
///
/// The [key] is put on the `Image` itself rather than on this widget, because
/// what a test means by "the photo is on screen" is that an image is, and the
/// [errorBuilder]'s replacement stands in the same place.
class PhotoFrame extends StatelessWidget {
  const PhotoFrame({
    super.key,
    required this.file,
    required this.fit,
    this.imageKey,
    this.errorBuilder,
  });

  /// The original on this device. Read-only, always.
  final File file;

  final BoxFit fit;

  /// Goes on the `Image`, not on the `LayoutBuilder` above it.
  final Key? imageKey;

  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final edge = governingEdge(
        fit,
        constraints.maxWidth,
        constraints.maxHeight,
      );
      return Image.file(
        file,
        key: imageKey,
        fit: fit,
        cacheWidth: edge == null
            ? null
            : displayDecodeWidth(
                logicalEdge: edge,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              ),
        errorBuilder: errorBuilder,
      );
    },
  );
}
