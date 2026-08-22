import 'package:flutter/material.dart';

/// The visual language Cairn's design already settled on for the moment
/// (`docs/decisions/2026-08-22-design-calls.md`, section 5): the back camera
/// fills the frame because the photographer is looking at other people, and
/// the front camera sits in a small rounded corner inset "in the manner
/// people already know from BeReal".
///
/// This widget only composes two already-available pieces of content -- it
/// has no opinion on whether [subject] and [inset] are live camera previews
/// or already-captured still images. `MomentCameraScreen` uses it with a live
/// back preview and a static placeholder inset (see that file for why);
/// `MomentReviewScreen` uses it with both shots as finished stills.
class DualCameraFrame extends StatelessWidget {
  const DualCameraFrame({
    super.key,
    required this.subject,
    this.inset,
    this.insetAlignment = Alignment.bottomLeft,
  });

  /// Full-bleed content: the back camera, subject-facing.
  final Widget subject;

  /// Small corner content: the front camera, self-facing. Null hides the
  /// inset entirely (used while the front shot hasn't been taken yet).
  final Widget? inset;

  final Alignment insetAlignment;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: subject),
          if (inset != null)
            Align(
              alignment: insetAlignment,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  width: 100,
                  height: 132,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black45,
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: inset,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
