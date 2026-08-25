import 'package:flutter/material.dart';

import '../widgets/dual_camera_frame.dart';
import 'capture_sequencer.dart';

/// Shows the finished moment the way Cairn's design draws it: the back shot
/// full-bleed, the front shot in a small rounded corner inset -- plus the one
/// number this whole spike exists to produce: the measured gap, in
/// milliseconds, between the two shots on whatever hardware ran this build.
class MomentReviewScreen extends StatelessWidget {
  const MomentReviewScreen({super.key, required this.capture});

  final MomentCapture capture;

  @override
  Widget build(BuildContext context) {
    final gapMs = capture.gapBetweenShots.inMilliseconds;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: DualCameraFrame(
                subject: Image.memory(
                  capture.back.imageBytes,
                  fit: BoxFit.cover,
                ),
                inset: Image.memory(
                  capture.front.imageBytes,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Back shot at ${capture.back.capturedAt.inMilliseconds}ms, '
                    'front shot at ${capture.front.capturedAt.inMilliseconds}ms '
                    'after the shutter was tapped.',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Gap between shots: ${gapMs}ms',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Retake'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
