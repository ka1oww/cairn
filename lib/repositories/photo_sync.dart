// THE SEAM (docs/architecture.md): the only layer that knows storage backends
// exist. This file is the photographs' half of what `itinerary_sync.dart` is
// for the plan — the one place that reads the Drift store and speaks to the
// shared pool — and it is deliberately a sibling of `TripSync` rather than a
// lodger inside it: `TripSync`'s contract is narrow on purpose, and photos
// must not widen it.
//
// ---------------------------------------------------------------------------
// THE ORDERING RULE, and why the outbox is shaped the way it is
// ---------------------------------------------------------------------------
//
// **Bytes first, row second, never the reverse.** A crash between the two
// leaves an orphan object — invisible to every phone, reconcilable later —
// where the reverse ordering would leave a broken tile everyone can see. The
// rule is load-bearing twice over: `r2-upload-url` refuses to sign a photo id
// a `photos` row already claims, so the row is what closes an original to
// further writes, and a retry of an upload that never landed happens while no
// row exists and is still signed. An outbox that inserted the row first would
// refuse its own retry.
//
// The durable states are exactly the places a crash can leave you — `queued`,
// `uploaded`, `caption`, `refused` — and nothing else. An upload ticket is a
// bearer capability that lives five minutes: it is minted per attempt, never
// written anywhere, and **never re-minted once a PUT has returned 200**,
// because past that line the record insert may land at any moment and a row's
// existence is what makes the mint refuse.
//
// **The driver never watches `photos`.** Its trigger is the outbox table
// alone, so the pull half (when it is built) can write photo rows without
// re-triggering the push — the unbounded-loop lesson `itinerary_sync.dart`
// guards against is designed out here instead.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cairn_model/cairn_model.dart';

import '../storage/drift/app_database.dart';
import '../storage/remote/shared_facts.dart';

Duration _deviceOffset() => DateTime.now().timeZoneOffset;

/// Pushes this phone's photographs into the trip's shared pool, one at a
/// time, oldest first, and keeps trying until each has crossed or the server
/// has ruled.
///
/// Push half only. No standings stream, deliberately: the awaiting tile is
/// the status surface the design has, and a photo-transport surface is a
/// design decision nobody has made — reporting is not smuggled in ahead of
/// it.
class PhotoSync {
  PhotoSync({
    required this.database,
    required this.facts,
    this.now = DateTime.now,
    this.utcOffset = _deviceOffset,
    Random? jitter,
  }) : _jitter = jitter ?? Random();

  final AppDatabase database;
  final SharedFacts facts;

  /// This phone's reading of now: what decides an item is due, and where the
  /// backoff counts from. Injected so a test can stand anywhere in time.
  final DateTime Function() now;

  /// The trip's clock as an offset — the same acknowledged approximation
  /// `TripSync.utcOffset` names, feeding the same `tripEndsAtFrom` rule, so
  /// the trip cannot be archived to one sync and open to the other.
  final Duration Function() utcOffset;

  /// The backoff's spread. Eight phones share one hotel wifi; jitter is what
  /// keeps them from retrying in lockstep. Injected so a test can pin it.
  final Random _jitter;

  final _subscriptions = <StreamSubscription<void>>[];
  Timer? _poll;
  Future<void>? _inFlight;
  Future<void>? _queued;
  var _started = false;

  /// Starts pushing: once now, again whenever the outbox changes, and every
  /// [pollEvery] if one is given.
  ///
  /// The poll is what retries a backed-off item and what recovers from a
  /// tunnel; no websocket, for the reason `TripSync.start` gives. Defaults
  /// to no poll so nothing that merely constructs the app leaves a timer
  /// running.
  void start({Duration? pollEvery}) {
    if (_started) return;
    _started = true;
    _subscriptions.add(database.watchOutbox().listen((_) => syncSoon()));
    if (pollEvery != null) _poll = Timer.periodic(pollEvery, (_) => syncSoon());
  }

  /// Stops listening and waits for whatever is already running — a pass
  /// writes to Drift, and a database closed under one fails in a way that
  /// looks like a bug in the sync.
  Future<void> stop() async {
    _poll?.cancel();
    _poll = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _started = false;
    await _queued?.catchError((_) {});
    await _inFlight?.catchError((_) {});
  }

  /// Asks for a pass without waiting for it. The enqueue transaction fires
  /// the outbox stream more than once; a pass per emission would race
  /// itself.
  void syncSoon() => unawaited(syncNow());

  /// One pass, start to finish: every due item, one at a time.
  ///
  /// Serialized and **collapsed** exactly as [TripSync.syncNow] is: while
  /// one pass runs, every further call joins a single queued follow-up, so a
  /// burst of captures costs at most two passes — and the second is
  /// guaranteed to have seen everything. A pass that finds nothing due
  /// writes nothing, which is what lets the pass-triggers-stream-triggers-
  /// pass cycle settle instead of spin.
  Future<void> syncNow() {
    if (_inFlight == null) return _run();
    return _queued ??= _inFlight!.then<void>((_) {}, onError: (_) {}).then((_) {
      _queued = null;
      return _run();
    });
  }

  Future<void> _run() {
    final started = _pass().whenComplete(() => _inFlight = null);
    _inFlight = started;
    return started;
  }

  Future<void> _pass() async {
    final SharedFactsSession? auth;
    try {
      auth = await facts.session();
    } on SharedFactsUnavailable {
      return;
    }
    if (auth == null) return;

    final trip = await database.readTripFacts();
    if (trip == null) return;
    final tripId = TripId(trip.tripId);

    // The trip's standing, before any round trip — with the one deliberate
    // asymmetry the ending wrote down: the 72-hour grace still *takes
    // photographs* (`docs/decisions/2026-08-26-the-ending.md`), so the
    // outbox keeps pushing through it and only an archived trip stops the
    // pass cold. The server enforces the same line with its own clock, and
    // where the two disagree the server rules — relayed as `refused`.
    final standing = tripStandingAt(now: now().toUtc(), endsAt: await _endsAt());
    if (!standing.takesPhotos) return;

    final work = await database.readOutboxWork();
    if (work.isEmpty) return;
    final nowIso = now().toUtc().toIso8601String();
    final dayDates = {
      for (final day in await database.readItineraryDays())
        day.number: day.dateIso,
    };

    for (final item in work) {
      // Due-ness is the item's own; a backed-off photo waits without holding
      // up the one behind it.
      if (item.outbox.nextAttemptAtUtcIso.compareTo(nowIso) > 0) continue;
      try {
        await _pushOne(tripId, item, dayDates);
      } on SharedFactsUnavailable {
        // The offline rule: the server could not be reached, so the whole
        // pass stops and **no item is penalised** — a tunnel is not the
        // photograph's fault, and whatever durable progress this item made
        // (an `uploaded` mark) is already written. The poll retries.
        return;
      } on UploadTicketRejected catch (e) {
        // The ticket died, not the photograph: back to `queued`, ticket
        // discarded, one attempt on the meter. A persistent rejection
        // climbs the backoff to its ceiling, visible in `lastError`,
        // rather than terminating wrongly.
        final attempts = item.outbox.attempts + 1;
        await database.delayOutboxRetry(
          photoId: item.outbox.photoId,
          attempts: attempts,
          nextAttemptAtUtcIso: _backedOff(attempts),
          lastError: e.reason,
        );
      } on SharedFactsRefused catch (e) {
        // The server understood and said no — not a member, the trip closed
        // past its grace, the id claimed. Terminal; retrying changes
        // nothing, so nothing here does.
        await database.markOutboxRefused(
          photoId: item.outbox.photoId,
          lastError: e.reason,
        );
      }
    }
  }

  Future<void> _pushOne(
    TripId tripId,
    OutboxItem item,
    Map<int, String?> dayDates,
  ) async {
    if (item.outbox.state == 'caption') {
      await facts.writePhotoCaption(
        tripId: tripId,
        photoId: item.outbox.photoId,
        caption: item.photo.word,
      );
      await database.settleOutboxPushed(
        photoId: item.outbox.photoId,
        sentWord: item.photo.word,
        nowUtcIso: now().toUtc().toIso8601String(),
      );
      return;
    }

    // `image/jpeg` is what `package:camera` writes and the only way a row
    // predating the content-type column can exist at all.
    final contentType = item.photo.contentType ?? 'image/jpeg';
    var objectKey = item.outbox.r2ObjectKey;
    var byteSize = item.outbox.uploadedByteSize;

    final needsBytes =
        item.outbox.state == 'queued' ||
        // An `uploaded` row missing its key or size cannot be built by any
        // write path here, but a state that cannot be recorded must not
        // wedge forever: no `photos` row exists (the record never ran), so
        // a fresh mint is still signed and a re-PUT of the same bytes is
        // idempotent. Falling back to the full attempt self-heals it.
        objectKey == null ||
        byteSize == null;

    if (needsBytes) {
      final path = item.photo.filePath;
      final frame = path == null ? null : File(path);
      if (frame == null || !frame.existsSync()) {
        // The bytes are gone from this device before they ever crossed.
        // Nothing on any server can fix that, so it is terminal — and
        // recorded rather than deleted, because a photograph that silently
        // never crossed should at least be queryable.
        await database.markOutboxRefused(
          photoId: item.outbox.photoId,
          lastError: 'the frame file is missing at ${path ?? '(no path)'}',
        );
        return;
      }
      final bytes = await frame.readAsBytes();
      final ticket = await facts.photoUploadTicket(
        tripId: tripId,
        photoId: item.outbox.photoId,
        contentType: contentType,
        byteSize: bytes.length,
      );
      await facts.putPhotoBytes(ticket, bytes);
      // The 200 makes the bytes a durable remote fact, and this write makes
      // the *knowledge* of it durable: recovery from here goes straight to
      // the record and never mints again.
      objectKey = ticket.objectKey;
      byteSize = bytes.length;
      await database.markOutboxUploaded(
        photoId: item.outbox.photoId,
        r2ObjectKey: objectKey,
        byteSize: byteSize,
      );
    }

    // The word is read at record time — [item.photo] was read this pass, and
    // an edit landing mid-flight is caught by the settle below, which turns
    // the row into a caption debt instead of deleting it.
    await facts.recordPhoto(
      RemotePhoto(
        id: item.outbox.photoId,
        tripId: tripId.value,
        contributorId: item.photo.contributorId,
        r2ObjectKey: objectKey,
        contentType: contentType,
        byteSize: byteSize,
        capturedAtIso: item.photo.takenAtUtcIso,
        dayNumber: item.photo.dayNumber,
        tripDayIso: dayDates[item.photo.dayNumber],
        caption: item.photo.word,
        updatedAtIso: now().toUtc().toIso8601String(),
      ),
    );
    await database.settleOutboxPushed(
      photoId: item.outbox.photoId,
      sentWord: item.photo.word,
      nowUtcIso: now().toUtc().toIso8601String(),
    );
  }

  /// `now + min(1h, 30s × 2^attempts)`, spread ±20%.
  ///
  /// The cap keeps a phone that has been wrong for a day trying hourly; the
  /// meter never terminates anything, because the real deadline is the
  /// server's own close-plus-grace check, relayed as `refused` when passed.
  String _backedOff(int attempts) {
    final ceiling = min(3600.0, 30.0 * pow(2, attempts).toDouble());
    final spread = ceiling * (0.8 + 0.4 * _jitter.nextDouble());
    return now()
        .toUtc()
        .add(Duration(milliseconds: (spread * 1000).round()))
        .toIso8601String();
  }

  /// The instant this phone's plan ends, on the trip's clock, or null while
  /// its last day's date is still open. The same read `TripSync._endsAt`
  /// makes, feeding the same `tripEndsAtFrom` — the rule lives in
  /// `cairn_model` and is not restated by either caller.
  Future<DateTime?> _endsAt() async {
    final days = (await database.readItineraryDays()).toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    return tripEndsAtFrom(
      dayDatesInPlanOrder: [
        for (final day in days)
          if (day.dateIso case final iso?)
            DateTime.parse('${iso}T00:00:00Z').toUtc()
          else
            null,
      ],
      utcOffset: utcOffset(),
    );
  }
}
