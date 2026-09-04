// APP STATE band (docs/architecture.md): the capture flow's whole brain.
//
// The whole of the moment lives here: whether your minute has come, what the
// camera is asked for, the breath between the shutter and the flip, the word
// written on it, and the write through the seam. The screens render the view
// models declared in this file and call this notifier's methods; every type
// they see is this band's own.
//
// The shape is the design's, and every part of it is settled:
//
//  - **The ping** is one a day, at your own minute, dealt by
//    `packages/trip_moments`. See `ping_schedule.dart`.
//  - **The camera** is the back camera and nothing else in the first release
//    (docs/decisions/2026-08-22-camera-like-bereal.md). It sits behind
//    `camera_source.dart` so this file never names a lens.
//  - **Two minutes, and late is always allowed.** The window is two minutes,
//    which narrows the thirty of design-calls §7 and changes nothing else.
//    There is no lockout: a photo taken at 23:40 carries its real hour and is
//    visibly late, which is the only pressure the system applies and is
//    enough.
//  - **The pause** is surface 10d, the breath before the flip: the frame, a
//    retake whenever you want one, and a primary action that names the payoff.
//  - **A retake is the same moment, so it is the same deadline.** There is no
//    cap on retakes, and the cap that came off was the only thing that used
//    to bound one; what bounds a retake now is the window, and a retake that
//    re-opened the window would bound nothing at all. That is why
//    [Framing] carries the moment's own `closesAt` and *nothing else* about
//    the window: late, the last stretch and the countdown are all
//    [windowStandingAt] over that one instant, so there is no second copy of
//    the deadline for a retake to reset. The bug this replaces did exactly
//    that — `onceMore` handed back `isLate: false`, and a late capture came
//    back from a retake looking punctual.
//  - **The word** is design round 10's `18a`: one line on that sheet, under
//    the hour it will print beside, skippable by construction. Blank is the
//    usual. Nothing is corrected into tidiness — no autocapitalise, no full
//    stop added, no second line, because the book never prints one.
//  - **And the pool shuts when the trip closes.** Every write below asks
//    `tripStandingProvider` first, because "the archive takes nothing more"
//    is a property of the pool and not of a screen
//    (docs/decisions/2026-08-26-the-ending.md). The rule itself is
//    `cairn_model`'s `TripStanding.takesPhotos`; this file only obeys it.
//
// **What the grace window opens, and what still cannot reach it.** A trip
// that has ended goes on taking photographs for seventy-two hours, and the
// guards below let them through. Nothing in the app can *offer* one yet: the
// ping only ever fires on a day of the plan, and capture only ever writes to
// today, so once the last day seals there is no built door into the pool.
// The door the grace exists for is the import sweep
// (docs/decisions/2026-08-22-auto-import-honesty.md), which is later work.
// That is why the rule is written at the write path rather than at a button:
// when the sweep lands it inherits the correct answer instead of needing its
// own.
//
// Deliberately absent: any surface that shows *when* your minute is. A ping
// you can see coming is a ping you can pose for, and the entire value of the
// mechanic is that the photograph is one nobody planned.
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import '../repositories/photo_repository.dart';
import 'camera_source.dart';
import 'day_view.dart';
import 'ping_schedule.dart';
import 'trip_lifecycle.dart';
import 'trip_providers.dart';

/// How long the moment stays open after the ping.
///
/// Two minutes, narrowed from the thirty of design-calls §7. The narrowing is
/// only affordable because the ping is *yours* and nobody else's: a personal
/// minute is a much smaller thing to miss than a party-wide one, and the late
/// path below is still open till midnight either way.
const captureWindow = Duration(minutes: 2);

/// The tail of that window the design calls "last stretch" (surface 10b).
/// Change, not alarm: the wording moves and the countdown warms; nothing
/// blinks.
///
/// **Thirty seconds, retuned with the window and not left where it was.** It
/// was two minutes when the window was thirty, and two minutes of a
/// two-minute window is not a tail — it is the whole thing, which would make
/// `MomentOpen(isLastStretch: false)` a state nobody could ever be in and the
/// day page's "Your minute. Look up." a line nobody could ever read. A quarter
/// of the window keeps both readings reachable and keeps the tail long enough
/// to be a change rather than an alarm.
const lastStretch = Duration(seconds: 30);

// ---------------------------------------------------------------------------
// View models — everything a screen may see, spoken in screen terms.
// ---------------------------------------------------------------------------

/// What today's page has to say about your moment. Five shapes, all drawn.
sealed class CaptureCall {
  const CaptureCall();
}

/// Nothing to ask of you here. Either this is not today, or today is not a
/// day of the plan, or its date is still open and a ping needs an instant.
class NoMomentHere extends CaptureCall {
  const NoMomentHere();
}

/// Your minute is somewhere in today and has not come yet.
///
/// It deliberately does not say when. See the file header.
class MomentAhead extends CaptureCall {
  const MomentAhead();
}

/// You have been pinged and the window is open.
class MomentOpen extends CaptureCall {
  /// The tail of the window (surface 10b), [lastStretch] long.
  final bool isLastStretch;

  /// When the window shuts. Carried rather than recomputed, because it is
  /// what the capture screen counts down to and what a retake returns to.
  final DateTime closesAt;

  const MomentOpen({required this.isLastStretch, required this.closesAt});
}

/// The window closed and the day did not (surface 10c). There is no lockout
/// and never will be; what you take now lands at the hour it is taken.
class MomentLate extends CaptureCall {
  /// When the window shut — in the past, by definition. Carried for the same
  /// reason [MomentOpen.closesAt] is: the capture screen opened from here is
  /// the same moment, and a retake inside it must find the same deadline.
  final DateTime closesAt;

  const MomentLate(this.closesAt);
}

/// You have already answered today, at this hour in the trip's own clock.
class MomentAnswered extends CaptureCall {
  /// `11:40`.
  final String hourLabel;

  const MomentAnswered(this.hourLabel);
}

/// Where the capture screen is.
sealed class CaptureState {
  const CaptureState();
}

/// Not capturing. The screen closes itself on this.
class CaptureClosed extends CaptureState {
  const CaptureClosed();
}

/// Ready to take one, or taking it.
class Framing extends CaptureState {
  /// When this moment's window shuts, and the *only* thing this state says
  /// about the window. Late, the last stretch and the countdown are all
  /// [windowStandingAt] over this instant, which is what makes a retake
  /// incapable of resetting any of them: there is one deadline and no copies.
  final DateTime closesAt;

  /// The shutter is open.
  final bool isTaking;

  const Framing({required this.closesAt, this.isTaking = false});
}

/// The breath before the flip (surface 10d): the frame taken, the line to
/// write on it, and a retake for as long as the window is open.
class TheBreath extends CaptureState {
  /// Where the back frame is, for the screen to show. This is the frame the
  /// day keeps.
  final String framePath;

  /// Where the front frame is, when the capture event took one, for the
  /// screen to draw as the inset. The source composes nothing — it delivers
  /// two files, and the inset's layout is the capture screen's
  /// (`lib/screens/capture_screen.dart`). Null on a source with one lens,
  /// and the breath simply has no inset then.
  final String? frontFramePath;

  /// When the shutter fired, in UTC.
  final DateTime takenAtUtc;

  /// `14:50` — the hour this will print beside, in the trip's clock. The
  /// word is anchored under it because that is where the book sets it.
  final String hourLabel;

  /// What is on the line right now. Empty is the usual.
  final String word;

  /// The moment's deadline, carried through unchanged from [Framing]. The
  /// breath is where a retake is decided, so it is where the person most
  /// needs to know how much of the window is left — and it is the same
  /// window, which is the whole of the rule.
  final DateTime closesAt;

  /// The write is in flight.
  final bool isKeeping;

  const TheBreath({
    required this.framePath,
    this.frontFramePath,
    required this.takenAtUtc,
    required this.hourLabel,
    this.word = '',
    required this.closesAt,
    this.isKeeping = false,
  });

  TheBreath _with({String? word, bool? isKeeping}) => TheBreath(
    framePath: framePath,
    frontFramePath: frontFramePath,
    takenAtUtc: takenAtUtc,
    hourLabel: hourLabel,
    word: word ?? this.word,
    closesAt: closesAt,
    isKeeping: isKeeping ?? this.isKeeping,
  );
}

/// What the window is doing at one instant, given the moment's own deadline.
///
/// One derivation for three things that have to agree — the countdown, the
/// last stretch and late — because they are the same fact read three ways and
/// a surface that computed any of them itself could contradict the other two
/// mid-second.
class WindowStanding {
  /// What is left of the window, floored at zero.
  final Duration remaining;

  /// The window has closed. There is no thread on a late capture — the timer
  /// simply is not there, so there is nothing to have failed (surface 10c).
  final bool isLate;

  /// Inside the tail (surface 10b).
  final bool isLastStretch;

  const WindowStanding._({
    required this.remaining,
    required this.isLate,
    required this.isLastStretch,
  });

  /// `1:07 left` — said once here rather than at each of the two surfaces
  /// that show it, so they cannot word the same window differently.
  ///
  /// Null once the window has shut, which is surface 10c's rule expressed in
  /// the type: a late capture is not handed a countdown to hide, it is handed
  /// nothing to show. Rounded *up*, so the last visible reading is `0:01` and
  /// never a `0:00` that lingers.
  String? get countdownLabel {
    if (isLate) return null;
    final seconds = (remaining.inMicroseconds / Duration.microsecondsPerSecond)
        .ceil();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} left';
  }
}

/// [WindowStanding] at [now], for a window that shuts at [closesAt].
///
/// The deadline is an input and never derived here, which is what lets a
/// retake hand back the very instant it was given. Time only runs forwards
/// and the instant never moves, so "late" derived this way is monotonic: a
/// moment that has gone late cannot come back, however many retakes follow,
/// and a window that shuts *during* the breath is honestly late rather than
/// frozen punctual.
WindowStanding windowStandingAt({
  required DateTime closesAt,
  required DateTime now,
}) {
  final remaining = closesAt.difference(now);
  // On the closing instant itself the window is shut, which is the edge
  // `captureCallFor` has always drawn (`now.isBefore(closes)`).
  if (remaining <= Duration.zero) {
    return const WindowStanding._(
      remaining: Duration.zero,
      isLate: true,
      isLastStretch: false,
    );
  }
  return WindowStanding._(
    remaining: remaining,
    isLate: false,
    isLastStretch: remaining <= lastStretch,
  );
}

/// The camera would not open, in words a person can read.
class CaptureRefusedState extends CaptureState {
  final String reason;

  const CaptureRefusedState(this.reason);
}

// ---------------------------------------------------------------------------
// Providers.
// ---------------------------------------------------------------------------

/// Which day of the plan today is, or null when today is not one of them.
///
/// Matched by date and never inferred from position, for the same reason the
/// day page matches by date: nothing in this app guesses a date.
final todaysPlanDayProvider = Provider<int?>((ref) {
  final today = ref.watch(todayProvider);
  final plan = ref.watch(savedItineraryProvider).value;
  if (plan == null) return null;
  for (final day in plan.days) {
    if (day.date == today) return day.number;
  }
  return null;
});

/// What the page for [date] says about your moment.
///
/// Only today ever has one. The late path runs to midnight and stops there:
/// a day that is over belongs to the whole party, and adding to it a week
/// later is a different feature (the import sweep), not this one.
final captureCallProvider = Provider.family<CaptureCall, DateTime>((ref, date) {
  if (date != ref.watch(todayProvider)) return const NoMomentHere();
  final dayNumber = ref.watch(todaysPlanDayProvider);
  if (dayNumber == null) return const NoMomentHere();
  return captureCallFor(
    ping: ref.watch(todaysPingProvider),
    now: ref.watch(nowProvider)(),
    answeredAt: _myPhotoToday(ref, dayNumber)?.ref.takenAt,
    utcOffset: ref.watch(tripUtcOffsetProvider),
    standing: ref.watch(tripStandingProvider),
  );
});

PooledPhoto? _myPhotoToday(Ref ref, int dayNumber) {
  // `tripPhotosProvider` is the app's one subscription to the pool — the same
  // one the Pool draws from. Capture asks it a different question (has *my*
  // moment today been answered?) and adds no second stream to ask it.
  final pool = ref.watch(tripPhotosProvider).value ?? const <PooledPhoto>[];
  for (final photo in pool) {
    if (photo.ref.dayNumber == dayNumber &&
        photo.ref.contributor.value == ref.watch(localMemberIdProvider)) {
      return photo;
    }
  }
  return null;
}

/// The derivation, kept a pure function so the window's edges can be read and
/// tested without a widget.
CaptureCall captureCallFor({
  required tm.Ping? ping,
  required DateTime now,
  required DateTime? answeredAt,
  required Duration utcOffset,
  required model.TripStanding standing,
}) {
  // Answered outranks everything, including a window that is still open: one
  // ping is one photograph, and the day is now open to you.
  if (answeredAt != null) {
    return MomentAnswered(clockLabel(answeredAt, utcOffset));
  }
  // A closed trip asks nothing of anybody. Not a refusal drawn on the page —
  // there is simply no moment here any more, which is the same shape as a
  // day that was never one of the plan's.
  if (!standing.takesPhotos) return const NoMomentHere();
  if (ping == null) return const NoMomentHere();
  if (now.isBefore(ping.at)) return const MomentAhead();
  final closes = ping.at.add(captureWindow);
  final window = windowStandingAt(closesAt: closes, now: now);
  if (window.isLate) return MomentLate(closes);
  return MomentOpen(isLastStretch: window.isLastStretch, closesAt: closes);
}

/// `14:50` — an instant read in the trip's own clock.
///
/// The day's clock is fixed where the day starts and never moves, so a photo
/// taken after an afternoon border crossing still reads at the hour that day
/// was on (`cairn_model.TripDay`, and the same rule in two other packages —
/// docs/architecture.md, invariant 1). One offset per trip is all this slice
/// has; when the trip clock lands, that is what changes.
String clockLabel(DateTime utcInstant, Duration utcOffset) {
  final local = utcInstant.add(utcOffset);
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

final captureFlowProvider = NotifierProvider<CaptureFlow, CaptureState>(
  CaptureFlow.new,
);

class CaptureFlow extends Notifier<CaptureState> {
  // No field here holds anything about the window, and that is deliberate.
  // The moment's deadline rides in the state itself ([Framing.closesAt],
  // [TheBreath.closesAt]) and is handed on unchanged at every hop, so there
  // is nothing for `open`, `shoot`, `onceMore` or a rebuild to re-derive or
  // reset. The count of retakes is not held either: it is nobody's business
  // but the person's, and the posted photograph never shows how many retakes
  // it took, so no count is kept in state, in the store, or anywhere else.

  @override
  CaptureState build() => const CaptureClosed();

  /// Opens the camera, if the moment is yours to answer.
  ///
  /// Refuses on any other call rather than opening a camera nobody asked
  /// for: the app interrupts once a day and never otherwise, and a capture
  /// screen that opens whenever it is tapped is a second interruption
  /// wearing a button.
  void open() {
    // The pool's own door, asked before the moment's. `captureCallProvider`
    // answers `NoMomentHere` on a closed trip too, so this is belt and
    // braces on purpose: `open()` is the one method a new screen would call,
    // and the write it leads to must never depend on which of the two
    // remembered.
    if (!ref.read(tripStandingProvider).takesPhotos) {
      state = const CaptureClosed();
      return;
    }
    final call = ref.read(captureCallProvider(ref.read(todayProvider)));
    // Both doors into the camera carry the same thing — when this moment's
    // window shuts — and the screen works the rest out from it.
    state = switch (call) {
      MomentOpen(:final closesAt) => Framing(closesAt: closesAt),
      MomentLate(:final closesAt) => Framing(closesAt: closesAt),
      _ => const CaptureClosed(),
    };
  }

  /// Takes the frame, and lands on the breath.
  Future<void> shoot() async {
    final framing = state;
    if (framing is! Framing || framing.isTaking) return;
    state = Framing(closesAt: framing.closesAt, isTaking: true);
    try {
      final frame = await ref.read(cameraSourceProvider).takeOne();
      state = TheBreath(
        framePath: frame.path,
        frontFramePath: frame.frontPath,
        takenAtUtc: frame.takenAtUtc,
        hourLabel: clockLabel(
          frame.takenAtUtc,
          ref.read(tripUtcOffsetProvider),
        ),
        closesAt: framing.closesAt,
      );
    } on CameraRefused catch (e) {
      state = CaptureRefusedState(e.reason);
    }
  }

  /// "Once more" — as many times as you like, for as long as the window
  /// lasts.
  ///
  /// There is no cap on retakes. The old cap of one had been the authenticity
  /// guard — one retake matches how people treat film — and what replaces it
  /// is the clock: two minutes is short enough that a photoshoot does not fit
  /// inside one, and the deadline below is the same deadline whichever retake
  /// this is. A count is *not* kept, here or anywhere the pool can see: the
  /// posted photograph never shows how many retakes it took, and a number
  /// rendered to the party would reinstate the very pressure the cap was
  /// removed to lift.
  Future<void> onceMore() async {
    final breath = state;
    if (breath is! TheBreath || breath.isKeeping) return;
    // Both halves of the capture event go: an attempt is one moment, and a
    // retake that kept its front frame would leave an orphan on disk.
    await _discard([breath.framePath, breath.frontFramePath]);
    // The same instant it came in with. A retake never re-opens a closed
    // window and never closes an open one — it is the same moment, so the
    // sheet it returns to is the sheet it left, still late if the moment was
    // late, and still counting down to the minute it was always counting
    // down to.
    state = Framing(closesAt: breath.closesAt);
  }

  /// Writes on the line. Stored exactly as typed — see the file header.
  void write(String word) {
    final breath = state;
    if (breath is! TheBreath) return;
    state = breath._with(word: word);
  }

  /// "Turn the day over": keeps the frame and whatever is on the line.
  ///
  /// The word is not a separate step and has no confirmation of its own —
  /// whatever is on the line when the day turns is what was written, so
  /// writing can be abandoned mid-word at no cost (round 10, `18b`).
  Future<void> turnTheDayOver() async {
    final breath = state;
    if (breath is! TheBreath || breath.isKeeping) return;
    // **The last gate before the pool, and the one that matters.** A frame
    // taken while the trip was still open cannot be kept into a trip that
    // has closed since — the archive is fixed, and a photograph landing in
    // it afterwards would change the record the book was made from. The
    // frame is discarded with it, because an unkept photograph is not a
    // photograph.
    if (!ref.read(tripStandingProvider).takesPhotos) {
      await abandon();
      return;
    }
    final dayNumber = ref.read(todaysPlanDayProvider);
    if (dayNumber == null) return;
    state = breath._with(isKeeping: true);
    await ref
        .read(photoStoreProvider)
        .keep(
          dayNumber: dayNumber,
          contributor: model.MemberId(ref.read(localMemberIdProvider)),
          takenAt: breath.takenAtUtc,
          origin: model.PhotoOrigin.pinged,
          filePath: breath.framePath,
          word: breath.word,
        );
    state = const CaptureClosed();
    // The kept photograph is the back frame alone, and the row above points
    // at that file where it lies. Nothing reads the front frame past the
    // review, so the day turning over is where its half of the event goes —
    // the same rule `onceMore` and `abandon` apply, at the one exit that
    // used to leak.
    await _discard([breath.frontFramePath]);
  }

  /// Leaves without keeping anything. The frame is thrown away with it —
  /// an unkept photograph is not a photograph.
  Future<void> abandon() async {
    final breath = state;
    state = const CaptureClosed();
    if (breath is TheBreath) {
      await _discard([breath.framePath, breath.frontFramePath]);
    }
  }

  /// The one spelling of "these files of the capture event go".
  ///
  /// Every path out of the breath ends here, because a capture event must
  /// leave no orphan on disk and three copies of that rule is how one of
  /// them comes to be forgotten. Nulls are skipped, so a one-lens source
  /// asks for nothing special.
  Future<void> _discard(Iterable<String?> paths) async {
    final camera = ref.read(cameraSourceProvider);
    for (final path in paths) {
      if (path != null) await camera.discard(path);
    }
  }
}
