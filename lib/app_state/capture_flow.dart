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
//  - **Thirty minutes, and late is always allowed**
//    (docs/decisions/2026-08-22-design-calls.md §7). There is no lockout: a
//    photo taken at 23:40 carries its real hour and is visibly late, which is
//    the only pressure the system applies and is enough.
//  - **The pause** is surface 10d, the breath before the flip: the frame, one
//    retake and only one, and a primary action that names the payoff.
//  - **The word** is design round 10's `18a`: one line on that sheet, under
//    the hour it will print beside, skippable by construction. Blank is the
//    usual. Nothing is corrected into tidiness — no autocapitalise, no full
//    stop added, no second line, because the book never prints one.
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
import 'trip_providers.dart';

/// How long the moment stays open after the ping (design-calls §7).
const captureWindow = Duration(minutes: 30);

/// The tail of that window the design calls "last stretch" (surface 10b).
/// Change, not alarm: nothing blinks and nothing counts.
const lastStretch = Duration(minutes: 2);

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
  /// The last two minutes (surface 10b).
  final bool isLastStretch;

  const MomentOpen({required this.isLastStretch});
}

/// The window closed and the day did not (surface 10c). There is no lockout
/// and never will be; what you take now lands at the hour it is taken.
class MomentLate extends CaptureCall {
  const MomentLate();
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
  /// The last two minutes of the window.
  final bool isLastStretch;

  /// The window has closed. There is no thread on a late capture — the timer
  /// simply is not there, so there is nothing to have failed (surface 10c).
  final bool isLate;

  /// The shutter is open.
  final bool isTaking;

  const Framing({
    required this.isLastStretch,
    required this.isLate,
    this.isTaking = false,
  });
}

/// The breath before the flip (surface 10d): the frame taken, the line to
/// write on it, and one retake if it has not been spent.
class TheBreath extends CaptureState {
  /// Where the frame is, for the screen to show.
  final String framePath;

  /// When the shutter fired, in UTC.
  final DateTime takenAtUtc;

  /// `14:50` — the hour this will print beside, in the trip's clock. The
  /// word is anchored under it because that is where the book sets it.
  final String hourLabel;

  /// What is on the line right now. Empty is the usual.
  final String word;

  /// The one retake has been used. After that the control is not there —
  /// not disabled, absent (surface 10d).
  final bool isRetakeSpent;

  /// The write is in flight.
  final bool isKeeping;

  const TheBreath({
    required this.framePath,
    required this.takenAtUtc,
    required this.hourLabel,
    this.word = '',
    required this.isRetakeSpent,
    this.isKeeping = false,
  });

  TheBreath _with({String? word, bool? isKeeping}) => TheBreath(
        framePath: framePath,
        takenAtUtc: takenAtUtc,
        hourLabel: hourLabel,
        word: word ?? this.word,
        isRetakeSpent: isRetakeSpent,
        isKeeping: isKeeping ?? this.isKeeping,
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
final captureCallProvider = Provider.family<CaptureCall, DateTime>(
  (ref, date) {
    if (date != ref.watch(todayProvider)) return const NoMomentHere();
    final dayNumber = ref.watch(todaysPlanDayProvider);
    if (dayNumber == null) return const NoMomentHere();
    return captureCallFor(
      ping: ref.watch(todaysPingProvider),
      now: ref.watch(nowProvider),
      answeredAt: _myPhotoToday(ref, dayNumber)?.ref.takenAt,
      utcOffset: ref.watch(tripUtcOffsetProvider),
    );
  },
);

PooledPhoto? _myPhotoToday(Ref ref, int dayNumber) {
  // `tripPhotosProvider` is the app's one subscription to the pool — the same
  // one the Pool draws from. Capture asks it a different question (has *my*
  // moment today been answered?) and adds no second stream to ask it.
  final pool = ref.watch(tripPhotosProvider).value ?? const <PooledPhoto>[];
  for (final photo in pool) {
    if (photo.ref.dayNumber == dayNumber &&
        photo.ref.contributor.value == localMemberId) {
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
}) {
  // Answered outranks everything, including a window that is still open: one
  // ping is one photograph, and the day is now open to you.
  if (answeredAt != null) return MomentAnswered(clockLabel(answeredAt, utcOffset));
  if (ping == null) return const NoMomentHere();
  if (now.isBefore(ping.at)) return const MomentAhead();
  final closes = ping.at.add(captureWindow);
  if (now.isBefore(closes)) {
    return MomentOpen(
      isLastStretch: !now.isBefore(closes.subtract(lastStretch)),
    );
  }
  return const MomentLate();
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

final captureFlowProvider =
    NotifierProvider<CaptureFlow, CaptureState>(CaptureFlow.new);

class CaptureFlow extends Notifier<CaptureState> {
  /// Survives the trip back through [Framing], which is the whole point: the
  /// mulligan is one per moment, not one per sheet.
  bool _retakeSpent = false;

  @override
  CaptureState build() => const CaptureClosed();

  /// Opens the camera, if the moment is yours to answer.
  ///
  /// Refuses on any other call rather than opening a camera nobody asked
  /// for: the app interrupts once a day and never otherwise, and a capture
  /// screen that opens whenever it is tapped is a second interruption
  /// wearing a button.
  void open() {
    final call = ref.read(captureCallProvider(ref.read(todayProvider)));
    state = switch (call) {
      MomentOpen(:final isLastStretch) =>
        Framing(isLastStretch: isLastStretch, isLate: false),
      MomentLate() => const Framing(isLastStretch: false, isLate: true),
      _ => const CaptureClosed(),
    };
    if (state is Framing) _retakeSpent = false;
  }

  /// Takes the frame, and lands on the breath.
  Future<void> shoot() async {
    final framing = state;
    if (framing is! Framing || framing.isTaking) return;
    state = Framing(
      isLastStretch: framing.isLastStretch,
      isLate: framing.isLate,
      isTaking: true,
    );
    try {
      final frame = await ref.read(cameraSourceProvider).takeOne();
      state = TheBreath(
        framePath: frame.path,
        takenAtUtc: frame.takenAtUtc,
        hourLabel: clockLabel(frame.takenAtUtc, ref.read(tripUtcOffsetProvider)),
        isRetakeSpent: _retakeSpent,
      );
    } on CameraRefused catch (e) {
      state = CaptureRefusedState(e.reason);
    }
  }

  /// "Once more" — the single mulligan. One retake matches how people treat
  /// film: zero punishes the thumb-over-lens frame and makes the ping feel
  /// like a trap; unlimited turns a candid into a photoshoot.
  Future<void> onceMore() async {
    final breath = state;
    if (breath is! TheBreath || breath.isRetakeSpent || breath.isKeeping) {
      return;
    }
    _retakeSpent = true;
    await ref.read(cameraSourceProvider).discard(breath.framePath);
    state = Framing(
      isLastStretch: false,
      // A retake never re-opens a closed window and never closes an open one;
      // it is the same moment, so the sheet it returns to is the same sheet.
      isLate: false,
    );
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
    final dayNumber = ref.read(todaysPlanDayProvider);
    if (dayNumber == null) return;
    state = breath._with(isKeeping: true);
    await ref.read(photoStoreProvider).keep(
          dayNumber: dayNumber,
          contributor: model.MemberId(localMemberId),
          takenAt: breath.takenAtUtc,
          origin: model.PhotoOrigin.pinged,
          filePath: breath.framePath,
          word: breath.word,
        );
    _retakeSpent = false;
    state = const CaptureClosed();
  }

  /// Leaves without keeping anything. The frame is thrown away with it —
  /// an unkept photograph is not a photograph.
  Future<void> abandon() async {
    final breath = state;
    _retakeSpent = false;
    state = const CaptureClosed();
    if (breath is TheBreath) {
      await ref.read(cameraSourceProvider).discard(breath.framePath);
    }
  }
}
