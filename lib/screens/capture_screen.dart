// SCREENS band (docs/architecture.md): knows app state and nothing below it.
// No camera, no repository, no store — the flow's states come from
// app_state/capture_flow.dart and the camera lives behind a seam that this
// file cannot see.
//
// **The house's own paper, and no Material scheme anywhere under it.** The
// capture surface keeps the house style rather than a Material scheme, so it
// keeps Cairn's voice and look rather than taking on BeReal's black chrome.
// That is not a no-op: this screen ran on `Theme.of(context)` and so on
// whatever Material happened to hand it. Every colour and every face below
// now comes from `house_style.dart`, which is the design record's one
// transcription — a second spelling of a house colour, or a `Theme.of`
// reaching for one, is the thing to refuse in review.
//
// Still not here: the design's drawn treatment of this screen — the dashed
// thread burning down the edge with its coral bead (10a/10b), the paper sheet,
// the caption line set in the trip's own text face at the width the book gives
// it (round 10, 18a/18b). What is here is the flow, its states, and the one
// piece of 10a/10b that stopped being decoration when the window narrowed to
// two minutes: the countdown. Three things it keeps because they are rules
// rather than looks — the line takes what is typed without correcting it into
// tidiness, a late capture is shown no timer at all (surface 10c), and the
// posted photograph never says how many retakes it took, so nothing here
// counts them.
//
// Also not here: a live viewfinder. The seam hands back a frame, not a
// preview, so on a phone the shutter fires without one. That is the next
// slice's, with the treatment.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/capture_flow.dart';
import '../app_state/ping_schedule.dart';
import 'house_style.dart';
import 'photo_frame.dart';

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
      backgroundColor: housePaper,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          // **One clock for the whole route, and it sits above the switch on
          // purpose.** A clock that restarts hands the person back seconds
          // the window has already spent, which is the retake bug wearing a
          // different hat. A clock written into each surface only avoids that
          // while Flutter happens to line the two surfaces up and reuse the
          // element — give either one a key, or put anything between them,
          // and every hop between framing and the breath seeds a fresh one at
          // the full two minutes. Up here it is mounted when the camera opens
          // and disposed when it closes, so the continuity is structural
          // rather than a coincidence of the tree's shape.
          child: _CaptureClock(
            until: switch (state) {
              Framing(:final closesAt) => closesAt,
              TheBreath(:final closesAt) => closesAt,
              CaptureClosed() || CaptureRefusedState() => null,
            },
            builder: (context, now) => switch (state) {
              final Framing framing => _Framing(
                framing: framing,
                window: windowStandingAt(closesAt: framing.closesAt, now: now),
              ),
              final TheBreath breath => _Breath(
                breath: breath,
                window: windowStandingAt(closesAt: breath.closesAt, now: now),
              ),
              final CaptureRefusedState refused => _Refused(
                reason: refused.reason,
              ),
              CaptureClosed() => const SizedBox.shrink(),
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The house's type on this surface. The tokens are house_style.dart's; only
// the composition is this screen's.
// ---------------------------------------------------------------------------

const _eyebrow = TextStyle(
  fontFamily: houseTextFamily,
  fontSize: 11,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.4,
  color: houseMuted,
);

const _line = TextStyle(
  fontFamily: houseTextFamily,
  fontSize: 17,
  height: 1.35,
  color: houseInk,
);

const _whisper = TextStyle(
  fontFamily: houseTextFamily,
  fontSize: 12.5,
  color: houseMuted,
);

/// The countdown's own face. Ink while there is room, amber in the tail — a
/// change, not an alarm (surface 10b).
///
/// **Not coral, in either state.** Coral fills the today-flag and one primary
/// action per screen and is never a count (house_style.dart); on this screen
/// it is already spoken for by the shutter, which is the thing the countdown
/// is asking you to press.
TextStyle _countdownFace(bool isLastStretch) => TextStyle(
  fontFamily: houseTextFamily,
  fontSize: 30,
  fontWeight: FontWeight.w700,
  // The digits keep their columns, so a countdown does not jitter its own
  // width once a second.
  fontFeatures: const [FontFeature.tabularFigures()],
  color: isLastStretch ? houseAmber : houseInk,
);

/// The one coral action on the screen.
ButtonStyle get _primary => FilledButton.styleFrom(
  backgroundColor: houseCoral,
  foregroundColor: houseSticker,
  disabledBackgroundColor: houseWash,
  disabledForegroundColor: houseMuted,
  minimumSize: const Size.fromHeight(50),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
  ),
  textStyle: const TextStyle(
    fontFamily: houseTextFamily,
    fontSize: 16,
    fontWeight: FontWeight.w700,
  ),
);

/// Everything that is not the coral action: quiet, and never a second door
/// dressed up as the first.
ButtonStyle get _quiet => TextButton.styleFrom(
  foregroundColor: houseMuted,
  disabledForegroundColor: houseWash,
  textStyle: const TextStyle(
    fontFamily: houseTextFamily,
    fontSize: 14,
    fontWeight: FontWeight.w700,
  ),
);

// ---------------------------------------------------------------------------
// The clock.
// ---------------------------------------------------------------------------

/// The capture route's own second hand, and the one surface allowed one.
///
/// **The tick redraws the sheet; it never tells it the time.** `nowProvider`
/// is the app's one clock and it is live at every ask (ping_schedule.dart
/// says why), so each rebuild here asks it again and gets the wall clock as
/// it really is. Nothing is accumulated and nothing is counted, which is what
/// makes the two ways of losing time both harmless: a `Timer.periodic` fires
/// no catch-up ticks for the seconds a suspended app slept through, and
/// nothing rebuilds a sheet nobody is touching. Either way the next look is
/// the true one, and the resume the observer below catches is a *prompt* to
/// look rather than the source of the answer. Counting ticks instead was the
/// defect: a phone away in a pocket for ninety seconds came back reading
/// `2:00 left / a while yet` half a minute after the window had shut.
///
/// The tick is here rather than at the app root because of its *grain*. The
/// root asks the clock again on every resume and every `clockRefresh`, which
/// is what keeps the day page's call honest, and it is deliberately too
/// coarse to run a countdown: a whole app rebuilt once a second for the sake
/// of one screen is a price only this screen should pay. So the finer asking
/// is local, for exactly as long as the camera is open, and `dispose` stops
/// it.
///
/// It knows [until] only so that it can *stop*: once there is nothing left to
/// count it cancels itself rather than rebuilding the sheet once a second for
/// the rest of the session, and a capture that was already late never starts
/// one at all — which is surface 10c's rule taken literally. What the time
/// left *means* is not decided here; that is `windowStandingAt`, and this
/// widget hands its callers an instant, not a verdict.
class _CaptureClock extends ConsumerStatefulWidget {
  const _CaptureClock({required this.until, required this.builder});

  /// The live moment's deadline, straight off the flow's state, or null when
  /// no capture is live. Never derived here and never adjusted here.
  final DateTime? until;

  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  ConsumerState<_CaptureClock> createState() => _CaptureClockState();
}

class _CaptureClockState extends ConsumerState<_CaptureClock>
    with WidgetsBindingObserver {
  Timer? _timer;

  bool get _hasSomethingToCount {
    final until = widget.until;
    // `ref.read` here and `ref.watch` in `build`, so the clock asked is the
    // same one a test's `bootstrapApp(now:)` pins for everything else.
    return until != null && ref.read(nowProvider)().isBefore(until);
  }

  void _ensureTicking() {
    if (!_hasSomethingToCount) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _lookAgain());
  }

  /// Redraw, then decide whether there is still anything to redraw for. The
  /// `setState` carries no value on purpose — `build` asks the clock itself,
  /// so there is nothing here to get out of step with it.
  void _lookAgain() {
    setState(() {});
    _ensureTicking();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensureTicking();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from somebody else's app is the one moment no tick of ours
    // announces, so it is asked for by hand. It changes nothing about *what*
    // is read — only about when the sheet is asked to read it.
    if (state == AppLifecycleState.resumed) _lookAgain();
  }

  @override
  void didUpdateWidget(_CaptureClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureTicking();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, ref.watch(nowProvider)());
}

/// The countdown itself, or nothing at all once the window has shut.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.window});

  final WindowStanding window;

  @override
  Widget build(BuildContext context) {
    final label = window.countdownLabel;
    if (label == null) return const SizedBox.shrink();
    return Text(
      label,
      key: const Key('capture-countdown'),
      style: _countdownFace(window.isLastStretch),
    );
  }
}

// ---------------------------------------------------------------------------
// The surfaces.
// ---------------------------------------------------------------------------

/// Before the shutter: what the window is doing, and one action.
class _Framing extends ConsumerWidget {
  const _Framing({required this.framing, required this.window});

  final Framing framing;
  final WindowStanding window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('YOUR MOMENT', key: Key('capture-eyebrow'), style: _eyebrow),
        const SizedBox(height: 10),
        Text(
          // Surface 10c: on a late capture the timer simply is not there, so
          // there is nothing to have failed. The card states the deal in the
          // app's own deadpan instead.
          switch ((window.isLate, window.isLastStretch)) {
            (true, _) =>
              "Your slot was teatime. It's fine — whatever you "
                  'take now lands at the hour it\'s taken.',
            (false, true) => 'last stretch',
            (false, false) => 'a while yet',
          },
          key: const Key('capture-window'),
          style: _line,
        ),
        const SizedBox(height: 8),
        _Countdown(window: window),
        const Spacer(),
        FilledButton(
          key: const Key('capture-shutter'),
          style: _primary,
          onPressed: framing.isTaking
              ? null
              : () => ref.read(captureFlowProvider.notifier).shoot(),
          child: const Text('Take it'),
        ),
        TextButton(
          key: const Key('capture-leave'),
          style: _quiet,
          onPressed: () => ref.read(captureFlowProvider.notifier).abandon(),
          child: const Text('Not now'),
        ),
      ],
    );
  }
}

/// The breath before the flip (surface 10d), with the line on it (18a).
class _Breath extends ConsumerWidget {
  const _Breath({required this.breath, required this.window});

  final TheBreath breath;
  final WindowStanding window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.read(captureFlowProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            // The two frames of the one capture event, composed here and
            // nowhere lower: the seam delivers two files and the inset's
            // layout is this screen's (camera_source.dart). The back frame
            // sizes the stack; the front frame rides its corner, the way the
            // moment's composition was decided
            // (docs/decisions/2026-08-22-camera-like-bereal.md).
            child: Stack(
              children: [
                // The frame on disk is the full-size original the pool will
                // keep; the breath shows a screen's worth of it and leaves
                // the file alone. See lib/screens/photo_frame.dart.
                PhotoFrame(
                  file: File(breath.framePath),
                  imageKey: const Key('capture-back-frame'),
                  fit: BoxFit.contain,
                  // A frame that will not decode is still a real capture and
                  // still has an hour; losing the sheet over it would lose
                  // the moment as well.
                  errorBuilder: (context, _, _) =>
                      const SizedBox(key: Key('capture-back-frame-unreadable')),
                ),
                if (breath.frontFramePath case final frontPath?)
                  Positioned(
                    left: 10,
                    top: 10,
                    child: Container(
                      width: 88,
                      height: 116,
                      // The sticker's own edge, so the inset reads as laid on
                      // the photograph rather than cut out of it.
                      decoration: BoxDecoration(
                        color: houseSticker,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: houseSticker, width: 3),
                        boxShadow: const [
                          BoxShadow(
                            color: houseStickerShadow,
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: PhotoFrame(
                          file: File(frontPath),
                          imageKey: const Key('capture-front-frame'),
                          fit: BoxFit.cover,
                          // Same rule as the back frame: an inset that will
                          // not decode costs the inset, never the sheet.
                          errorBuilder: (context, _, _) => const SizedBox(
                            key: Key('capture-front-frame-unreadable'),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
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
          style: _line,
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
          style: _line,
          cursorColor: houseInk,
          decoration: const InputDecoration(
            border: UnderlineInputBorder(
              borderSide: BorderSide(color: houseMuted),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: houseMuted),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: houseInk),
            ),
            hintText: 'words, if any',
            hintStyle: _whisper,
          ),
          onChanged: flow.write,
        ),
        const SizedBox(height: 6),
        const Text(
          'blank is the usual',
          key: Key('capture-word-whisper'),
          style: _whisper,
        ),
        const SizedBox(height: 18),
        FilledButton(
          key: const Key('capture-keep'),
          style: _primary,
          // Never dimmed, and never a decline: the tap that skips writing is
          // the same tap that was always there, so silence is the default the
          // sheet is shaped around.
          onPressed: breath.isKeeping ? null : flow.turnTheDayOver,
          child: const Text('Turn the day over'),
        ),
        // Once more, and again, and again: there is no cap on retakes, so
        // the control is simply always here. What bounds a retake is the
        // countdown beside it — the *same* countdown the framing screen
        // showed, because a retake buys no more of the window
        // (capture_flow.dart's `onceMore`).
        Row(
          children: [
            TextButton(
              key: const Key('capture-once-more'),
              style: _quiet,
              onPressed: breath.isKeeping ? null : flow.onceMore,
              child: const Text('Once more'),
            ),
            const SizedBox(width: 12),
            _Countdown(window: window),
          ],
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
        Text(reason, key: const Key('capture-refused'), style: _line),
        const Spacer(),
        TextButton(
          key: const Key('capture-leave'),
          style: _quiet,
          onPressed: () => ref.read(captureFlowProvider.notifier).abandon(),
          child: const Text('Back to the day'),
        ),
      ],
    );
  }
}
