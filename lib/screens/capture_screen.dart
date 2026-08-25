// SCREENS band (docs/architecture.md): knows app state and nothing below it.
// No camera, no repository, no store — the flow's states come from
// app_state/capture_flow.dart and the camera lives behind a seam that this
// file cannot see.
//
// **Bare on purpose.** The design's treatment of this screen — the dashed
// thread burning down the edge with its coral bead (10a/10b), the paper
// sheet, the one coral door, the caption line set in the trip's own text face
// at the width the book gives it (round 10, 18a/18b) — is not here. What is
// here is the flow and its states, which is what the treatment will be hung
// on. Two things it does keep, because they are rules rather than looks: the
// retake control is *absent* once spent rather than disabled, and the line
// takes what is typed without correcting it into tidiness.
//
// Also not here: a live viewfinder. The seam hands back a frame, not a
// preview, so on a phone the shutter fires without one. That is the next
// slice's, with the treatment.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/capture_flow.dart';

class CaptureScreen extends ConsumerWidget {
  const CaptureScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The flow closes itself — after the day turns over, or when the moment
    // was never open. The screen follows it rather than deciding; there is
    // one place that knows whether a capture is live and it is not here.
    ref.listen<CaptureState>(captureFlowProvider, (_, next) {
      if (next is CaptureClosed && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    final state = ref.watch(captureFlowProvider);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: switch (state) {
            final Framing framing => _Framing(framing: framing),
            final TheBreath breath => _Breath(breath: breath),
            final CaptureRefusedState refused =>
              _Refused(reason: refused.reason),
            CaptureClosed() => const SizedBox.shrink(),
          },
        ),
      ),
    );
  }
}

/// Before the shutter. One label, one action.
class _Framing extends ConsumerWidget {
  const _Framing({required this.framing});

  final Framing framing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('YOUR MOMENT',
            key: const Key('capture-eyebrow'),
            style: theme.textTheme.labelSmall
                ?.copyWith(letterSpacing: 1.4, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Text(
          // Surface 10c: on a late capture the timer simply is not there, so
          // there is nothing to have failed. The card states the deal in the
          // app's own deadpan instead.
          switch ((framing.isLate, framing.isLastStretch)) {
            (true, _) => "Your slot was teatime. It's fine — whatever you "
                'take now lands at the hour it\'s taken.',
            (false, true) => 'last stretch',
            (false, false) => 'a while yet',
          },
          key: const Key('capture-window'),
          style: theme.textTheme.titleMedium,
        ),
        const Spacer(),
        FilledButton(
          key: const Key('capture-shutter'),
          onPressed: framing.isTaking
              ? null
              : () => ref.read(captureFlowProvider.notifier).shoot(),
          child: const Text('Take it'),
        ),
        TextButton(
          key: const Key('capture-leave'),
          onPressed: () => ref.read(captureFlowProvider.notifier).abandon(),
          child: const Text('Not now'),
        ),
      ],
    );
  }
}

/// The breath before the flip (surface 10d), with the line on it (18a).
class _Breath extends ConsumerWidget {
  const _Breath({required this.breath});

  final TheBreath breath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final flow = ref.read(captureFlowProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: Image.file(
              File(breath.framePath),
              key: const Key('capture-frame'),
              fit: BoxFit.contain,
              // A frame that will not decode is still a real capture and
              // still has an hour; losing the sheet over it would lose the
              // moment as well.
              errorBuilder: (context, _, _) =>
                  const SizedBox(key: Key('capture-frame-unreadable')),
            ),
          ),
        ),
        const SizedBox(height: 14),
        // The hour the photo will print beside, with the line anchored under
        // it — that is where the book sets it, so that is where it is
        // written.
        Text(
          '${breath.hourLabel}, yours.',
          key: const Key('capture-hour'),
          style: theme.textTheme.titleMedium,
        ),
        TextField(
          key: const Key('capture-word'),
          // Nothing is corrected into tidiness: caps stay caps, lowercase
          // stays lowercase, and no full stop is added (round 10, 18b).
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          // One line, because the book never prints a second one.
          maxLines: 1,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            border: UnderlineInputBorder(),
            hintText: 'words, if any',
          ),
          onChanged: flow.write,
        ),
        const SizedBox(height: 6),
        Text(
          'blank is the usual',
          key: const Key('capture-word-whisper'),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        FilledButton(
          key: const Key('capture-keep'),
          // Never dimmed, and never a decline: the tap that skips writing is
          // the same tap that was always there, so silence is the default the
          // sheet is shaped around.
          onPressed: breath.isKeeping ? null : flow.turnTheDayOver,
          child: const Text('Turn the day over'),
        ),
        // One retake, and only one. After it is used the control is not
        // there — absent, not disabled (surface 10d).
        if (!breath.isRetakeSpent)
          TextButton(
            key: const Key('capture-once-more'),
            onPressed: breath.isKeeping ? null : flow.onceMore,
            child: const Text('Once more'),
          ),
      ],
    );
  }
}

class _Refused extends ConsumerWidget {
  const _Refused({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(reason,
            key: const Key('capture-refused'),
            style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        TextButton(
          key: const Key('capture-leave'),
          onPressed: () => ref.read(captureFlowProvider.notifier).abandon(),
          child: const Text('Back to the day'),
        ),
      ],
    );
  }
}
