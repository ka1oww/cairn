// Proves the photo pipe end to end, against a scratch project, with no app.
//
//     dart run tool/photo_pipe_probe.dart \
//       --url https://<scratch ref>.supabase.co \
//       --anon-key <the scratch project's publishable anon key>
//
// or the same two values as CAIRN_PROBE_URL / CAIRN_PROBE_ANON_KEY.
//
// ---------------------------------------------------------------------------
// THIS SCRIPT HAS NEVER BEEN RUN
// ---------------------------------------------------------------------------
//
// There is no scratch project yet. Every line below is written from the
// schema, the two edge functions and the R2 documentation, and not one of its
// checks has ever been observed passing or failing. Nothing about it should be
// read as evidence until a transcript exists. It compiles and it analyzes; a
// script that compiles proves that it compiles.
//
// ---------------------------------------------------------------------------
// WHAT IT IS FOR
// ---------------------------------------------------------------------------
//
// The standing gap in this repository is named in `supabase/tests/README.md`
// and in `supabase/README.md`: **no RLS refusal has ever been observed against
// a hosted project**, only permitted paths, because exactly one account has
// ever touched one. `supabase/tests/rls_probe.py` closes that against a
// throwaway Postgres, which has no GoTrue, no PostgREST and no real
// `auth.uid()`; `test/hosted_smoke_test.dart` closes the other half with one
// account, which cannot pose as an adversary.
//
// This script is the third thing: **three real accounts over the real stack**
// -- a contributor, a co-member and a stranger -- watching every refusal in
// the transport plan actually happen before any of it guards a real
// photograph. It is not throwaway and it is not CI (it needs the network,
// a project and a bucket). It is run by hand and its transcript is pasted
// into the pull request of whichever slice it is proving, exactly as
// `rls_probe.py` is run by hand against a throwaway cluster.
//
// It grows a section per slice. Today it carries S0 (the pipe) and S3 (the
// download function's adversarial checklist). S1's outbox and S2's pull add
// their own.
//
// ---------------------------------------------------------------------------
// THE GUARD
// ---------------------------------------------------------------------------
//
// This script creates trips, uploads bytes, deletes memberships and leaves
// orphaned objects in a bucket. It must never do any of that to the project a
// person's photographs are in, so "point it at scratch" is enforced in code
// rather than in prose: it refuses to start if the URL it was handed is
// `SharedFactsConfig.hostedUrl`, or if the key it was handed is the hosted
// project's own. That is a guard against a slip, not against malice -- there
// is no way for a script to know that some third project is precious -- so
// read the URL you are about to pass.
//
// ---------------------------------------------------------------------------
// WHAT IT STILL CANNOT PROVE
// ---------------------------------------------------------------------------
//
// A green transcript says the pipe works for these three accounts on this
// project on this day. It says nothing about iOS suspending a transfer
// mid-PUT, nothing about camera or OCR quality (device-judged, AGENTS.md),
// and nothing about a fourth account, a real trip's worth of concurrency, or
// a phone with a wrong clock.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cairn/storage/remote/shared_facts.dart';
import 'package:cairn_model/cairn_model.dart';
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// What the probe knows about the two functions it is driving
// ---------------------------------------------------------------------------

/// `r2-upload-url`'s `UPLOAD_URL_TTL_SECONDS`. Read here so the expiry wait is
/// the real one and not a guess; if that constant moves, this moves with it.
const _uploadTtlSeconds = 300;

/// `r2-download-url`'s `DOWNLOAD_URL_TTL_SECONDS` -- the short end of the
/// window the captain settled on 2026-08-28.
const _downloadTtlSeconds = 900;

/// `r2-download-url`'s `MAX_BATCH`.
const _maxBatch = 64;

/// A plausible original. The measured JPEG median is 3.08 MB
/// (`docs/storage-and-cost.md`), and a probe that PUTs a hundred bytes proves
/// nothing about a real transfer.
const _originalBytes = 3080000;

const _usage =
    '''
Proves the Cairn photo pipe against a scratch Supabase project + R2 bucket.

  dart run tool/photo_pipe_probe.dart --url <URL> --anon-key <KEY> [options]

  --url       the scratch project's URL      (or CAIRN_PROBE_URL)
  --anon-key  its publishable anon key       (or CAIRN_PROBE_ANON_KEY)
  --fast      skip every expiry wait
  --slow      also wait out the download ticket ($_downloadTtlSeconds s)
  --help      this

Both edge functions must already be deployed to that project, and its
R2 secrets set. The script refuses to run against the hosted project.
''';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  final config = _Config.read(args);
  if (config == null) {
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }

  final refusal = _liveProjectRefusal(config);
  if (refusal != null) {
    stderr.writeln('REFUSED TO RUN\n\n$refusal');
    exitCode = 2;
    return;
  }

  final probe = _Probe(config);
  try {
    await probe.run();
  } finally {
    probe.close();
  }
  exitCode = probe.transcript.report();
}

// ---------------------------------------------------------------------------
// Configuration, and the guard over it
// ---------------------------------------------------------------------------

class _Config {
  _Config({
    required this.url,
    required this.anonKey,
    required this.waitForUploadExpiry,
    required this.waitForDownloadExpiry,
  });

  /// No trailing slash: every path below is concatenated onto it.
  final String url;
  final String anonKey;
  final bool waitForUploadExpiry;
  final bool waitForDownloadExpiry;

  static _Config? read(List<String> args) {
    String? valueOf(String flag) {
      final i = args.indexOf(flag);
      return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
    }

    final env = Platform.environment;
    final url = (valueOf('--url') ?? env['CAIRN_PROBE_URL'] ?? '').trim();
    final key = (valueOf('--anon-key') ?? env['CAIRN_PROBE_ANON_KEY'] ?? '')
        .trim();
    if (url.isEmpty || key.isEmpty) return null;

    final fast = args.contains('--fast');
    return _Config(
      url: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
      anonKey: key,
      waitForUploadExpiry: !fast,
      waitForDownloadExpiry: !fast && args.contains('--slow'),
    );
  }
}

/// Why this script must not start, or null if it may.
///
/// Both halves matter. A URL check alone would let somebody point a scratch
/// hostname at the hosted key; a key check alone would miss a project reached
/// by a custom domain. Neither can recognise a *third* project somebody cares
/// about, which is why the header says to read the URL before passing it.
String? _liveProjectRefusal(_Config config) {
  String? hostOf(String url) => Uri.tryParse(url)?.host.toLowerCase();

  final asked = hostOf(config.url);
  final hosted = hostOf(SharedFactsConfig.hostedUrl);
  if (asked != null && hosted != null && asked == hosted) {
    return 'That is the hosted project (${SharedFactsConfig.hostedUrl}).\n'
        'This script creates trips, uploads bytes and deletes membership '
        'rows.\nPoint it at a scratch project.';
  }
  if (config.anonKey == SharedFactsConfig.hostedAnonKey) {
    return 'That is the hosted project\'s anon key, whatever the URL says.\n'
        'Pass the scratch project\'s own key.';
  }
  return null;
}

// ---------------------------------------------------------------------------
// The transcript
// ---------------------------------------------------------------------------

enum _Verdict { pass, fail, skip }

/// A numbered pass/fail transcript, printed as it happens.
///
/// Printed as it happens rather than collected and dumped, because the run
/// takes minutes and a probe that goes silent for five of them looks hung.
class _Transcript {
  int _n = 0;
  int _failed = 0;
  int _skipped = 0;
  int _passed = 0;

  void section(String title) {
    stdout.writeln('');
    stdout.writeln('---- $title');
  }

  void check(String what, bool ok, {String? detail}) =>
      _record(ok ? _Verdict.pass : _Verdict.fail, what, detail);

  void pass(String what, {String? detail}) =>
      _record(_Verdict.pass, what, detail);

  void fail(String what, {String? detail}) =>
      _record(_Verdict.fail, what, detail);

  /// Recorded, numbered and counted like any other line: a check that did not
  /// run is a hole in the evidence, and a transcript that hid it would read
  /// like a complete one.
  void skip(String what, String why) => _record(_Verdict.skip, what, why);

  void note(String text) => stdout.writeln('      $text');

  void _record(_Verdict verdict, String what, String? detail) {
    _n++;
    final tag = switch (verdict) {
      _Verdict.pass => 'PASS',
      _Verdict.fail => 'FAIL',
      _Verdict.skip => 'SKIP',
    };
    switch (verdict) {
      case _Verdict.pass:
        _passed++;
      case _Verdict.fail:
        _failed++;
      case _Verdict.skip:
        _skipped++;
    }
    stdout.writeln('${_n.toString().padLeft(3)}. $tag  $what');
    if (detail != null && detail.isNotEmpty) {
      for (final line in detail.split('\n')) {
        stdout.writeln('           $line');
      }
    }
  }

  /// The process exit code: nonzero if anything failed. A skip does not fail
  /// the run -- it is a check the operator chose not to pay for -- but it is
  /// counted on its own line so nobody reads "0 failed" as "all observed".
  int report() {
    stdout.writeln('');
    stdout.writeln('---- $_passed passed, $_failed failed, $_skipped skipped');
    return _failed == 0 ? 0 : 1;
  }
}

/// Stops the run. Later checks depend on earlier state -- there is no photo to
/// refuse a stranger if the upload never happened -- so a broken precondition
/// ends the transcript rather than cascading into a screenful of noise.
class _Halt implements Exception {
  _Halt(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// The probe
// ---------------------------------------------------------------------------

class _Account {
  _Account(this.who, this.id, this.token);
  final String who;
  final String id;
  final String token;
}

class _Probe {
  _Probe(this.config) : _client = http.Client();

  final _Config config;
  final http.Client _client;
  final transcript = _Transcript();
  final _random = Random.secure();

  late _Account _contributor;
  late _Account _coMember;
  late _Account _stranger;

  /// The trip everything happens on: it started two days ago and ends in
  /// three, so day 1 is walked, day 2 is the day in progress and day 3 is
  /// still ahead.
  late TripId _trip;
  late TripId _closedTrip;
  late TripId _strangerTrip;

  late PhotoId _walkedDayPhoto;
  late PhotoId _futureDayPhoto;
  late PhotoId _strangerPhoto;
  late Uint8List _frame;

  static const _walkedDay = 1;
  static const _futureDay = 3;

  void close() => _client.close();

  Future<void> run() async {
    stdout.writeln('Cairn photo pipe probe');
    stdout.writeln('  project  ${Uri.parse(config.url).host}');
    stdout.writeln('  date     ${DateTime.now().toUtc().toIso8601String()}');
    try {
      await _accountsAndTrip();
      await _theItinerary();
      await _theUpload();
      await _whoCanSeeTheRow();
      await _theSignedHeaders();
      await _theFixedFunctionsRefusals();
      await _theOrphan();
      await _theDownloadChecklist();
    } on _Halt catch (halt) {
      transcript.fail('the run stopped here', detail: halt.message);
    } on Object catch (error) {
      // A probe that dies with a stack trace has produced no transcript, and
      // the transcript is the artifact. A dead socket, a project that is not
      // there, a function that was never deployed: all of them end the run,
      // and all of them belong on a numbered line saying so.
      transcript.fail(
        'the run stopped on something unexpected',
        detail: '$error',
      );
    }
  }

  // -------------------------------------------------------------------------
  // S0: three accounts, one trip, one invite
  // -------------------------------------------------------------------------

  Future<void> _accountsAndTrip() async {
    transcript.section('S0 - three accounts, one trip, one invite');

    _contributor = await _signUp('the contributor');
    _coMember = await _signUp('the co-member');
    _stranger = await _signUp('the stranger');
    transcript.check(
      'three anonymous accounts sign in, with three distinct uids',
      {_contributor.id, _coMember.id, _stranger.id}.length == 3,
      detail:
          'contributor ${_contributor.id}\n'
          'co-member   ${_coMember.id}\n'
          'stranger    ${_stranger.id}',
    );

    // The phone mints the trip's id and the server keeps it
    // (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md). Minting it
    // here with the domain's own formatter is also the only place the two
    // spellings of a uuid get compared over the wire.
    _trip = TripId.mint(_bytes(16));
    final created = await _rest(
      'POST',
      '/trips',
      _contributor,
      body: {
        'id': _trip.value,
        'name': 'photo pipe probe',
        'created_by': _contributor.id,
        // UTC deliberately: `day_page_is_open` reads "today" in the trip's own
        // zone, and a probe whose machine is not in that zone would compute
        // different day dates than the database does and fail for a reason
        // that has nothing to do with the gate.
        'timezone': 'UTC',
        'start_date': _dayDate(-2),
        'end_date': _dayDate(3),
      },
      prefer: 'return=representation',
    );
    if (created.statusCode != 201) {
      throw _Halt('the trip would not insert: ${_say(created)}');
    }
    transcript.pass(
      'the contributor creates the trip, keeping the minted id',
      detail: _trip.value,
    );

    final invite = await _rest(
      'POST',
      '/trip_invites',
      _contributor,
      body: {'trip_id': _trip.value, 'created_by': _contributor.id},
      prefer: 'return=representation',
    );
    final code = _firstRow(invite)?['code'] as String?;
    if (code == null) {
      throw _Halt('no invite code came back: ${_say(invite)}');
    }
    transcript.check(
      'the invite is three spoken words',
      code.trim().split(RegExp(r'\s+')).length == 3,
      detail: code,
    );

    final redeemed = await _rest(
      'POST',
      '/rpc/redeem_trip_invite',
      _coMember,
      body: {'p_code': code},
    );
    transcript.check(
      'the co-member redeems it and is answered the trip id',
      redeemed.statusCode == 200 && _decode(redeemed) == _trip.value,
      detail: _say(redeemed),
    );

    final roster = await _rest(
      'GET',
      '/trip_members?trip_id=eq.${_trip.value}&select=user_id',
      _coMember,
    );
    final members = _rows(roster).map((r) => r['user_id']).toSet();
    transcript.check(
      'the roster is the two of them and not the stranger',
      members.length == 2 &&
          members.contains(_contributor.id) &&
          members.contains(_coMember.id),
      detail: 'roster $members',
    );

    _closedTrip = TripId.mint(_bytes(16));
    final closed = await _rest(
      'POST',
      '/trips',
      _contributor,
      body: {
        'id': _closedTrip.value,
        'name': 'a trip that has closed',
        'created_by': _contributor.id,
        'timezone': 'UTC',
        'start_date': _dayDate(-10),
        'end_date': _dayDate(-9),
      },
      prefer: 'return=representation',
    );
    if (closed.statusCode != 201) {
      throw _Halt('the closed trip would not insert: ${_say(closed)}');
    }
    transcript.pass(
      'a second trip exists whose end plus the grace is already past',
      detail: 'ended ${_dayDate(-9)}, so it closed ${_dayDate(-6)}',
    );
  }

  // -------------------------------------------------------------------------
  // S0: the itinerary, because the gate reads days out of it
  // -------------------------------------------------------------------------

  Future<void> _theItinerary() async {
    transcript.section('S0 - the itinerary the gate resolves days through');

    final now = DateTime.now().toUtc().toIso8601String();
    final pushed = await _rest(
      'POST',
      '/rpc/sync_trip_itinerary',
      _contributor,
      body: {
        'p_trip_id': _trip.value,
        'p_plan_revised_at': now,
        'p_days': [
          {
            'day_number': _walkedDay,
            'day_date': _dayDate(-2),
            'place': 'the day already walked',
            'revised_at': now,
            'stops': [
              {
                'position': 0,
                'stop_text': 'Fushimi Inari',
                'time_of_day': '08:30',
              },
            ],
          },
          {
            'day_number': 2,
            'day_date': _dayDate(0),
            'place': 'the day in progress',
            'revised_at': now,
            'stops': const <Object>[],
          },
          {
            'day_number': _futureDay,
            'day_date': _dayDate(1),
            'place': 'a day still ahead',
            'revised_at': now,
            'stops': const <Object>[],
          },
          {
            // The rule the migration mirrors from `day_gate.dart`: a day with
            // no date has been walked, so it is open. Uploading to it must
            // work too -- day number is the photograph's identity and a date
            // is not required to have one.
            'day_number': 4,
            'day_date': null,
            'place': 'a day whose date is still open',
            'revised_at': now,
            'stops': const <Object>[],
          },
        ],
        'p_pocket_revised_at': now,
        'p_pocket': const <Object>[],
      },
    );
    if (pushed.statusCode != 200) {
      throw _Halt('the itinerary would not sync: ${_say(pushed)}');
    }

    final days = await _rest(
      'GET',
      '/trip_itinerary_days?trip_id=eq.${_trip.value}'
          '&select=day_number,day_date&order=day_number',
      _coMember,
    );
    final stored = _rows(days);
    transcript.check(
      'four days reach the server, one of them deliberately undated',
      stored.length == 4 && stored.last['day_date'] == null,
      detail: stored
          .map((r) => '${r['day_number']}: ${r['day_date']}')
          .join(', '),
    );
  }

  // -------------------------------------------------------------------------
  // S0: the ticket, the PUT, the row
  // -------------------------------------------------------------------------

  Future<void> _theUpload() async {
    transcript.section('S0 - ticket, PUT, row');

    _frame = _plausibleOriginal();
    _walkedDayPhoto = PhotoId.mint(_bytes(16));

    final ticket = await _ticketFor(
      _contributor,
      _trip,
      _walkedDayPhoto,
      contentLength: _frame.length,
    );
    final url = _ticketUrl(ticket);
    if (url == null) {
      throw _Halt('no upload ticket: ${_say(ticket)}');
    }
    transcript.pass(
      'a ticket is minted for a ${(_frame.length / 1e6).toStringAsFixed(2)} MB original',
      detail:
          'key ${_body(ticket)?['objectKey']}\n'
          'expires in ${_body(ticket)?['expiresInSeconds']}s',
    );

    final put = await _putOriginal(url, _frame, 'image/jpeg');
    transcript.check(
      'R2 accepts the signed PUT',
      put.statusCode == 200 || put.statusCode == 201,
      detail: _say(put),
    );

    final row = await _insertPhoto(
      _contributor,
      _trip,
      _walkedDayPhoto,
      dayNumber: _walkedDay,
      objectKey: _body(ticket)?['objectKey'] as String,
      byteSize: _frame.length,
      caption: 'the contributor\'s own word',
    );
    transcript.check(
      'the photos row inserts, keyed on the day number',
      row.statusCode == 201,
      detail: _say(row),
    );

    // `r2-download-url` signs the row's own stored key, so what may be stored
    // is the whole of that promise. `0011`'s
    // `photos_object_key_own_prefix_check` is what makes it true, and the
    // shape it refuses is the one the finding named: a day page's key, which
    // lives in another table under another unique index and which no
    // constraint on `photos` would otherwise have caught. Watched here rather
    // than assumed, because the local probe drives SQL and this drives
    // PostgREST -- a constraint the API layer swallowed would look identical
    // to one that held.
    final foreign = await _insertPhoto(
      _contributor,
      _trip,
      PhotoId.mint(_bytes(16)),
      dayNumber: _walkedDay,
      objectKey:
          'trips/${_trip.value}/pages/${PhotoId.mint(_bytes(16)).value}'
          '.jpg',
      byteSize: _frame.length,
    );
    transcript.check(
      'and a row claiming a key outside its own folder is refused',
      foreign.statusCode != 201 &&
          foreign.body.contains('photos_object_key_own_prefix_check'),
      detail: _say(foreign),
    );

    // A second photograph, on a day still ahead, so a batch can hold one of
    // each and the gate has something to refuse.
    _futureDayPhoto = PhotoId.mint(_bytes(16));
    final second = await _ticketFor(
      _contributor,
      _trip,
      _futureDayPhoto,
      contentLength: _frame.length,
    );
    final secondUrl = _ticketUrl(second);
    if (secondUrl == null) {
      throw _Halt('no ticket for the second photograph: ${_say(second)}');
    }
    await _putOriginal(secondUrl, _frame, 'image/jpeg');
    final secondRow = await _insertPhoto(
      _contributor,
      _trip,
      _futureDayPhoto,
      dayNumber: _futureDay,
      objectKey: _body(second)?['objectKey'] as String,
      byteSize: _frame.length,
    );
    transcript.check(
      'a second photograph lands on a day that is still ahead',
      secondRow.statusCode == 201,
      detail: _say(secondRow),
    );

    final unlocks = await _rest(
      'GET',
      '/day_unlocks?trip_id=eq.${_trip.value}&select=day_number,user_id'
          '&order=day_number',
      _contributor,
    );
    final opened = _rows(unlocks)
        .where((r) => r['user_id'] == _contributor.id)
        .map((r) => r['day_number'])
        .toSet();
    transcript.check(
      'contributing opened both days for the contributor, by day number',
      opened.containsAll(<Object?>[_walkedDay, _futureDay]),
      detail: 'unlocks $opened',
    );
  }

  // -------------------------------------------------------------------------
  // S0: who can see the row
  // -------------------------------------------------------------------------

  Future<void> _whoCanSeeTheRow() async {
    transcript.section('S0 - the row, seen and not seen');

    final asCoMember = await _rest(
      'GET',
      '/photos?trip_id=eq.${_trip.value}&select=id,day_number,caption',
      _coMember,
    );
    transcript.check(
      'the co-member reads both rows',
      _rows(asCoMember).length == 2,
      detail: _say(asCoMember),
    );

    final asStranger = await _rest(
      'GET',
      '/photos?trip_id=eq.${_trip.value}&select=id',
      _stranger,
    );
    transcript.check(
      'the stranger reads zero rows, and is not told why',
      asStranger.statusCode == 200 && _rows(asStranger).isEmpty,
      detail: _say(asStranger),
    );

    final refusedTicket = await _ticketFor(
      _stranger,
      _trip,
      PhotoId.mint(_bytes(16)),
      contentLength: _frame.length,
    );
    transcript.check(
      'the stranger is refused a ticket',
      refusedTicket.statusCode == 403,
      detail: _say(refusedTicket),
    );
  }

  // -------------------------------------------------------------------------
  // S0: the two things the desk could not check
  // -------------------------------------------------------------------------

  Future<void> _theSignedHeaders() async {
    transcript.section('S0 - what the signature actually covers');

    // The signed-header footgun (`r2-upload-url/index.ts`, `allHeaders: true`).
    // Without that flag the URL constrains only the method and the key: any
    // content type, any number of bytes. This is the check that proves the
    // flag is doing what its comment claims.
    final photo = PhotoId.mint(_bytes(16));
    final ticket = await _ticketFor(
      _contributor,
      _trip,
      photo,
      contentLength: _frame.length,
    );
    final url = _ticketUrl(ticket);
    if (url == null) {
      throw _Halt('no ticket for the content-type check: ${_say(ticket)}');
    }

    final wrongType = await _putOriginal(url, _frame, 'image/png');
    transcript.check(
      'a PUT declaring a content type the ticket did not sign is rejected',
      wrongType.statusCode == 403,
      detail: _say(wrongType),
    );

    final wrongLength = await _putOriginal(
      url,
      Uint8List.sublistView(_frame, 0, _frame.length - 1),
      'image/jpeg',
    );
    transcript.check(
      'a PUT of a different number of bytes than the ticket signed is rejected',
      wrongLength.statusCode == 403,
      detail: _say(wrongLength),
    );

    if (!config.waitForUploadExpiry) {
      transcript.skip(
        'X-Amz-Expires is honoured on an upload ticket',
        'skipped by --fast; it costs a ${_uploadTtlSeconds}s wait',
      );
      return;
    }
    transcript.note(
      'waiting ${_uploadTtlSeconds + 20}s for the ticket to lapse '
      '(--fast skips this)',
    );
    await Future<void>.delayed(Duration(seconds: _uploadTtlSeconds + 20));
    final lapsed = await _putOriginal(url, _frame, 'image/jpeg');
    transcript.check(
      'X-Amz-Expires is honoured: the lapsed ticket is rejected by R2',
      lapsed.statusCode == 403,
      detail: _say(lapsed),
    );
  }

  // -------------------------------------------------------------------------
  // S0: the fixed upload function's own refusals, watched from outside
  // -------------------------------------------------------------------------

  Future<void> _theFixedFunctionsRefusals() async {
    transcript.section('S0 - the fixed upload function refuses');

    final claimed = await _ticketFor(
      _contributor,
      _trip,
      _walkedDayPhoto,
      contentLength: _frame.length,
    );
    transcript.check(
      'a photo id a row already claims is refused a second ticket',
      claimed.statusCode == 409,
      detail: _say(claimed),
    );

    final closed = await _ticketFor(
      _contributor,
      _closedTrip,
      PhotoId.mint(_bytes(16)),
      contentLength: _frame.length,
    );
    transcript.check(
      'a closed trip is refused a ticket, so no byte lands that no row could claim',
      closed.statusCode == 403,
      detail: _say(closed),
    );

    final tooBig = await _ticketFor(
      _contributor,
      _trip,
      PhotoId.mint(_bytes(16)),
      contentLength: 64 * 1024 * 1024 + 1,
    );
    transcript.check(
      'an upload past the ceiling is refused before anything is signed',
      tooBig.statusCode == 400,
      detail: _say(tooBig),
    );
  }

  // -------------------------------------------------------------------------
  // S0: the orphan, shown rather than asserted
  // -------------------------------------------------------------------------

  Future<void> _theOrphan() async {
    transcript.section('S0 - bytes with no row are invisible debris');

    final before = _rows(
      await _rest(
        'GET',
        '/photos?trip_id=eq.${_trip.value}&select=id',
        _coMember,
      ),
    ).length;

    final orphan = PhotoId.mint(_bytes(16));
    final ticket = await _ticketFor(
      _contributor,
      _trip,
      orphan,
      contentLength: _frame.length,
    );
    final url = _ticketUrl(ticket);
    if (url == null) {
      throw _Halt('no ticket for the orphan: ${_say(ticket)}');
    }
    final put = await _putOriginal(url, _frame, 'image/jpeg');
    // Bytes first, row second (docs/architecture.md). This is the crash
    // window made deliberate: the object is in the bucket and no row names it.
    final after = _rows(
      await _rest(
        'GET',
        '/photos?trip_id=eq.${_trip.value}&select=id',
        _coMember,
      ),
    ).length;

    transcript.check(
      'an object with no row is in the bucket and in nobody\'s pool',
      (put.statusCode == 200 || put.statusCode == 201) && after == before,
      detail:
          'key ${_body(ticket)?['objectKey']}\n'
          'the co-member saw $before rows before and $after after',
    );
    transcript.note(
      'that object is now debris in the scratch bucket, on purpose. '
      'The S4 sweeper is what removes it, and it is not built.',
    );
  }

  // -------------------------------------------------------------------------
  // S3: the download function's adversarial checklist (plan §7.3)
  // -------------------------------------------------------------------------

  Future<void> _theDownloadChecklist() async {
    transcript.section('S3 - r2-download-url, the §7.3 checklist');

    // §7.3.9, and the one item that needs no project at all: the function must
    // never reach for the service-role key, because reading as the caller is
    // what makes RLS a second wall instead of a bypassed one.
    final source = File.fromUri(
      Platform.script.resolve('../supabase/functions/r2-download-url/index.ts'),
    );
    if (source.existsSync()) {
      final text = source.readAsStringSync();
      transcript.check(
        '§7.3.9 the function never reaches for a service-role key',
        !text.contains('SERVICE_ROLE') && text.contains('SUPABASE_ANON_KEY'),
        detail: source.path,
      );
    } else {
      transcript.skip(
        '§7.3.9 the function never reaches for a service-role key',
        'run from the repository, so ${source.path} can be read',
      );
    }

    // The happy path first, so every refusal below is measured against a
    // request that is known to work.
    final open = await _downloadBatch(_coMember, _trip, [_walkedDayPhoto]);
    final openUrls = _urlsOf(open);
    transcript.check(
      'a walked day is signed for the co-member who never contributed to it',
      open.statusCode == 200 && openUrls.containsKey(_walkedDayPhoto.value),
      detail: _say(open),
    );

    final fetched = openUrls[_walkedDayPhoto.value] == null
        ? null
        : await _client.get(Uri.parse(openUrls[_walkedDayPhoto.value]!));
    transcript.check(
      'the signed GET returns the original, byte for byte',
      fetched != null &&
          fetched.statusCode == 200 &&
          fetched.bodyBytes.length == _frame.length,
      detail: fetched == null
          ? 'no URL to fetch'
          : '${fetched.statusCode}, ${fetched.bodyBytes.length} bytes '
                '(sent ${_frame.length})',
    );

    // §7.3.1
    final toStranger = await _downloadBatch(_stranger, _trip, [
      _walkedDayPhoto,
    ]);
    final nonexistent = PhotoId.mint(_bytes(16));
    final toStrangerMissing = await _downloadBatch(_stranger, _trip, [
      nonexistent,
    ]);
    transcript.check(
      '§7.3.1 a non-member is refused, indistinguishably from nonexistent',
      toStranger.statusCode == 200 &&
          _urlsOf(toStranger).isEmpty &&
          toStranger.body ==
              toStrangerMissing.body.replaceAll(
                nonexistent.value,
                _walkedDayPhoto.value,
              ),
      detail:
          'refused:   ${toStranger.body}\n'
          'missing:   ${toStrangerMissing.body}',
    );

    // §7.3.2 -- the cross-trip leak. Keys are derivable from ids the sync
    // already hands out (`supabase/README.md`), so a function that signed a
    // key it was handed would leak the whole corpus.
    await _aStrangersOwnPhoto();
    final crossTrip = await _downloadBatch(_coMember, _strangerTrip, [
      _strangerPhoto,
    ]);
    final crossTripDeclaredAsOurs = await _downloadBatch(_coMember, _trip, [
      _strangerPhoto,
    ]);
    transcript.check(
      '§7.3.2 another trip\'s photograph is refused, whichever trip is declared',
      _urlsOf(crossTrip).isEmpty && _urlsOf(crossTripDeclaredAsOurs).isEmpty,
      detail:
          'as its own trip: ${crossTrip.body}\n'
          'as ours:         ${crossTripDeclaredAsOurs.body}',
    );

    // §7.3.3 -- the gate is inside the per-id loop, so one batch splits.
    final mixed = await _downloadBatch(_coMember, _trip, [
      _walkedDayPhoto,
      _futureDayPhoto,
    ]);
    final mixedUrls = _urlsOf(mixed);
    transcript.check(
      '§7.3.3 a shut day is refused inside a batch whose open day succeeds',
      mixedUrls.containsKey(_walkedDayPhoto.value) &&
          !mixedUrls.containsKey(_futureDayPhoto.value) &&
          _refusedOf(mixed).contains(_futureDayPhoto.value),
      detail: _say(mixed),
    );

    final contributorsOwn = await _downloadBatch(_contributor, _trip, [
      _futureDayPhoto,
    ]);
    transcript.check(
      '§7.3.3 and the contributor, who opened that day, is signed for it',
      _urlsOf(contributorsOwn).containsKey(_futureDayPhoto.value),
      detail: _say(contributorsOwn),
    );

    // §7.3.4 -- nothing the caller says chooses the day or the key.
    final lying = await _downloadRaw(_coMember, {
      'tripId': _trip.value,
      'photoIds': [_futureDayPhoto.value],
      'dayNumber': _walkedDay,
      'r2ObjectKey':
          'trips/${_strangerTrip.value}/photos/anything/original.jpg',
      'userId': _contributor.id,
    });
    transcript.check(
      '§7.3.4 a day, a key and a uid in the body change nothing',
      _urlsOf(lying).isEmpty &&
          _refusedOf(lying).contains(_futureDayPhoto.value),
      detail: _say(lying),
    );

    // §7.3.5
    final malformed = await _downloadRaw(_coMember, {
      'tripId': _trip.value,
      'photoIds': ['../../etc/passwd', _walkedDayPhoto.value],
    });
    transcript.check(
      '§7.3.5 a malformed id is refused while the well-formed one beside it is signed',
      _refusedOf(malformed).contains('../../etc/passwd') &&
          _urlsOf(malformed).containsKey(_walkedDayPhoto.value),
      detail: _say(malformed),
    );

    final oversize = await _downloadRaw(_coMember, {
      'tripId': _trip.value,
      'photoIds': List<String>.generate(
        _maxBatch + 1,
        (_) => PhotoId.mint(_bytes(16)).value,
      ),
    });
    transcript.check(
      '§7.3.5 an oversize batch is refused whole, and the refusal names no row',
      oversize.statusCode == 400 &&
          !oversize.body.contains(_walkedDayPhoto.value),
      detail: _say(oversize),
    );

    // §7.3.6
    if (!config.waitForDownloadExpiry) {
      transcript.skip(
        '§7.3.6 X-Amz-Expires is honoured on a download URL',
        'skipped unless --slow; it costs a ${_downloadTtlSeconds}s wait. The '
            'same mechanism is observed on the upload ticket above.',
      );
    } else {
      transcript.note(
        'waiting ${_downloadTtlSeconds + 20}s for the download URL to lapse',
      );
      await Future<void>.delayed(Duration(seconds: _downloadTtlSeconds + 20));
      final replayed = await _client.get(
        Uri.parse(openUrls[_walkedDayPhoto.value]!),
      );
      transcript.check(
        '§7.3.6 a lapsed download URL is rejected by R2',
        replayed.statusCode == 403,
        detail: '${replayed.statusCode} ${replayed.reasonPhrase}',
      );
    }

    // §7.3.8 -- single-owner captions. RLS refuses by filtering, so this is
    // asserted on the state of the row and never on a thrown error.
    final patched = await _rest(
      'PATCH',
      '/photos?id=eq.${_walkedDayPhoto.value}',
      _coMember,
      body: {'caption': 'not the co-member\'s to write'},
      prefer: 'return=representation',
    );
    final reread = await _rest(
      'GET',
      '/photos?id=eq.${_walkedDayPhoto.value}&select=caption',
      _coMember,
    );
    transcript.check(
      '§7.3.8 a co-member cannot write another contributor\'s caption',
      _rows(patched).isEmpty &&
          _firstRow(reread)?['caption'] == 'the contributor\'s own word',
      detail:
          'patch returned ${_say(patched)}\n'
          'the row still says ${_firstRow(reread)?['caption']}',
    );

    // §7.3.7 -- LAST, because it takes the co-member off the trip. Every
    // read decision routes through `may_read_trip_photos`, which today only
    // answers `is_trip_member`; when leave/remove land, flipping that one
    // function body is provably the whole change.
    final left = await _rest(
      'DELETE',
      '/trip_members?trip_id=eq.${_trip.value}&user_id=eq.${_coMember.id}',
      _coMember,
      prefer: 'return=representation',
    );
    if (_rows(left).isEmpty) {
      transcript.skip(
        '§7.3.7 access decisions route through may_read_trip_photos',
        'the membership row would not delete (${_say(left)}); run the delete '
            'by hand in SQL and re-run this section',
      );
      return;
    }
    final afterLeaving = await _downloadBatch(_coMember, _trip, [
      _walkedDayPhoto,
    ]);
    transcript.check(
      '§7.3.7 removing the membership row refuses the very next batch',
      _urlsOf(afterLeaving).isEmpty &&
          _refusedOf(afterLeaving).contains(_walkedDayPhoto.value),
      detail: _say(afterLeaving),
    );
    transcript.note(
      'the other half of §6.3 -- keeping access on departure -- is not '
      'testable until a departure can be recorded. Nothing records one yet.',
    );
  }

  /// A photograph in a trip the co-member has never heard of, for §7.3.2.
  ///
  /// No bytes are uploaded for it: the check is that the function refuses, and
  /// a refusal never reaches R2.
  Future<void> _aStrangersOwnPhoto() async {
    _strangerTrip = TripId.mint(_bytes(16));
    final created = await _rest(
      'POST',
      '/trips',
      _stranger,
      body: {
        'id': _strangerTrip.value,
        'name': 'somebody else\'s trip',
        'created_by': _stranger.id,
        'timezone': 'UTC',
        'start_date': _dayDate(-2),
        'end_date': _dayDate(3),
      },
      prefer: 'return=representation',
    );
    if (created.statusCode != 201) {
      throw _Halt('the stranger\'s trip would not insert: ${_say(created)}');
    }
    _strangerPhoto = PhotoId.mint(_bytes(16));
    final row = await _insertPhoto(
      _stranger,
      _strangerTrip,
      _strangerPhoto,
      dayNumber: 1,
      objectKey:
          'trips/${_strangerTrip.value}/photos/${_strangerPhoto.value}/original.jpg',
      byteSize: _frame.length,
    );
    if (row.statusCode != 201) {
      throw _Halt('the stranger\'s photo row would not insert: ${_say(row)}');
    }
  }

  // -------------------------------------------------------------------------
  // Transport
  // -------------------------------------------------------------------------

  Future<_Account> _signUp(String who) async {
    final response = await _client.post(
      Uri.parse('${config.url}/auth/v1/signup'),
      headers: {'apikey': config.anonKey, 'Content-Type': 'application/json'},
      body: '{}',
    );
    final body = _body(response);
    final id = (body?['user'] as Map?)?['id'];
    final token = body?['access_token'];
    if (id is! String || token is! String) {
      throw _Halt(
        'could not sign $who in anonymously: ${_say(response)}\n'
        'Anonymous sign-ins must be enabled on the scratch project.',
      );
    }
    return _Account(who, id, token);
  }

  Map<String, String> _headers(_Account account) => {
    'apikey': config.anonKey,
    'Authorization': 'Bearer ${account.token}',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Future<http.Response> _rest(
    String method,
    String path,
    _Account account, {
    Object? body,
    String? prefer,
  }) async {
    final request = http.Request(
      method,
      Uri.parse('${config.url}/rest/v1$path'),
    )..headers.addAll({..._headers(account), 'Prefer': ?prefer});
    if (body != null) request.body = jsonEncode(body);
    return http.Response.fromStream(await _client.send(request));
  }

  Future<http.Response> _function(
    String name,
    _Account account,
    Map<String, Object?> body,
  ) => _client.post(
    Uri.parse('${config.url}/functions/v1/$name'),
    headers: _headers(account),
    body: jsonEncode(body),
  );

  Future<http.Response> _ticketFor(
    _Account account,
    TripId trip,
    PhotoId photo, {
    required int contentLength,
    String contentType = 'image/jpeg',
  }) => _function('r2-upload-url', account, {
    'tripId': trip.value,
    'photoId': photo.value,
    'contentType': contentType,
    'contentLength': contentLength,
  });

  Future<http.Response> _downloadBatch(
    _Account account,
    TripId trip,
    List<PhotoId> photos,
  ) => _downloadRaw(account, {
    'tripId': trip.value,
    'photoIds': photos.map((p) => p.value).toList(),
  });

  Future<http.Response> _downloadRaw(
    _Account account,
    Map<String, Object?> body,
  ) => _function('r2-download-url', account, body);

  Future<http.Response> _putOriginal(
    String url,
    Uint8List bytes,
    String contentType,
  ) => _client.put(
    Uri.parse(url),
    // `allHeaders: true` on the signing side means R2 verifies both of
    // these against the signature, so they are sent exactly and never
    // left to the client to default.
    headers: {'content-type': contentType, 'content-length': '${bytes.length}'},
    body: bytes,
  );

  Future<http.Response> _insertPhoto(
    _Account account,
    TripId trip,
    PhotoId photo, {
    required int dayNumber,
    required String objectKey,
    required int byteSize,
    String? caption,
  }) => _rest(
    'POST',
    '/photos',
    account,
    body: {
      'id': photo.value,
      'trip_id': trip.value,
      'contributor_id': account.id,
      'r2_object_key': objectKey,
      'content_type': 'image/jpeg',
      'byte_size': byteSize,
      'day_number': dayNumber,
      'captured_at': DateTime.now().toUtc().toIso8601String(),
      'caption': ?caption,
    },
    prefer: 'return=representation',
  );

  // -------------------------------------------------------------------------
  // Reading answers
  // -------------------------------------------------------------------------

  Object? _decode(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic>? _body(http.Response response) {
    final decoded = _decode(response);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  List<Map<String, dynamic>> _rows(http.Response response) {
    final decoded = _decode(response);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  Map<String, dynamic>? _firstRow(http.Response response) {
    final rows = _rows(response);
    return rows.isEmpty ? null : rows.first;
  }

  String? _ticketUrl(http.Response response) =>
      _body(response)?['uploadUrl'] as String?;

  Map<String, String> _urlsOf(http.Response response) {
    final urls = _body(response)?['urls'];
    if (urls is! Map) return const {};
    return urls.map((k, v) => MapEntry('$k', '$v'));
  }

  List<String> _refusedOf(http.Response response) {
    final refused = _body(response)?['refused'];
    if (refused is! List) return const [];
    return refused.map((r) => '$r').toList();
  }

  /// A response, short enough for a transcript line. Bodies are truncated:
  /// R2's XML errors run to several hundred characters and the status is the
  /// part being asserted on.
  String _say(http.Response response) {
    final body = response.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final short = body.length > 220 ? '${body.substring(0, 220)}...' : body;
    return '${response.statusCode} $short';
  }

  // -------------------------------------------------------------------------
  // Small things
  // -------------------------------------------------------------------------

  List<int> _bytes(int count) =>
      List<int>.generate(count, (_) => _random.nextInt(256));

  /// A calendar date [offset] days from today, in UTC, which is the trip's
  /// zone here on purpose (see `_accountsAndTrip`).
  String _dayDate(int offset) {
    final day = DateTime.now().toUtc().add(Duration(days: offset));
    final month = day.month.toString().padLeft(2, '0');
    final date = day.day.toString().padLeft(2, '0');
    return '${day.year}-$month-$date';
  }

  /// Something the size and shape of a real original.
  ///
  /// Not random bytes: three megabytes out of `Random.secure()` is slow enough
  /// to notice, and nothing downstream cares what the bytes are. It opens with
  /// a JPEG SOI so anything sniffing the object sees what its content type
  /// claims.
  Uint8List _plausibleOriginal() {
    final frame = Uint8List(_originalBytes);
    frame[0] = 0xFF;
    frame[1] = 0xD8;
    frame[2] = 0xFF;
    frame[3] = 0xE0;
    for (var i = 4; i < frame.length; i++) {
      frame[i] = i & 0xFF;
    }
    return frame;
  }
}
