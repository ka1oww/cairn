// STORAGE band: the real [SharedFacts], spoken over PostgREST.
//
// Plain HTTP rather than `supabase_flutter`, deliberately. Three shared facts
// move — a trip row, a roster and one function call — and PostgREST is an
// ordinary REST API over the schema in `supabase/migrations/`. The package
// would bring GoTrue, Realtime, Storage and a Podfile's worth of native
// dependencies to save a hundred lines of JSON, and it would put a second
// opinion about the schema in the repository. When Sign in with Apple lands
// it is `session()` that grows, not this file's transport.
//
// **No key is written here.** Both the project URL and the publishable anon
// key arrive from [SharedFactsConfig], which reads `--dart-define`s.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cairn_model/cairn_model.dart';
import 'package:http/http.dart' as http;

import 'shared_facts.dart';

class PostgrestSharedFacts implements SharedFacts {
  PostgrestSharedFacts({
    required this.config,
    required this.sessions,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final SharedFactsConfig config;
  final SessionSource sessions;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<SharedFactsSession?> session() => sessions.current();

  @override
  Future<RemoteTrip?> readTrip(TripId tripId) async {
    final auth = await _demand();
    final trip = await _get(
      '/rest/v1/trips?id=eq.${tripId.value}&select=name,created_by&limit=1',
      auth,
    );
    final rows = _rows(trip);
    // Zero rows is two answers at once and they are not distinguishable
    // here: this server has never heard of the trip, or it has and this
    // phone is not on it. Row-level security refuses by filtering, never by
    // raising (`supabase/README.md`). Both mean the same thing to the
    // caller — there is nothing here to reconcile with.
    if (rows.isEmpty) return null;

    final roster = _rows(
      await _get(
        '/rest/v1/trip_roster?trip_id=eq.${tripId.value}'
        '&select=user_id,display_name,joined_at&order=joined_at.asc',
        auth,
      ),
    );
    return RemoteTrip(
      id: tripId,
      name: rows.first['name'] as String?,
      startedBy: MemberId(rows.first['created_by'] as String),
      members: [
        for (final row in roster)
          RemoteMember(
            id: MemberId(row['user_id'] as String),
            displayName: row['display_name'] as String? ?? '',
            joinedAt: _instant(row['joined_at']),
          ),
      ],
    );
  }

  @override
  Future<void> createTrip(RemoteTripDraft draft) async {
    final auth = await _demand();
    await _send(
      'POST',
      '/rest/v1/trips',
      auth,
      body: {
        'id': draft.id.value,
        'name': draft.name,
        'created_by': draft.createdBy.value,
        'timezone': draft.timeZone,
        if (draft.country != null) 'country': draft.country,
        if (draft.city != null) 'city': draft.city,
        'start_date': draft.startDateIso,
        'end_date': draft.endDateIso,
      },
      // No `resolution=merge-duplicates`: a trip that already exists must
      // come back as a refusal, not be quietly overwritten with this
      // phone's idea of it.
      headers: const {'Prefer': 'return=minimal'},
    );
  }

  @override
  Future<RemoteItinerary> syncItinerary({
    required TripId tripId,
    required DateTime planRevisedAt,
    required List<RemoteDay> days,
    required DateTime pocketRevisedAt,
    required List<RemoteSetAside> setAside,
  }) async {
    final auth = await _demand();
    final response = await _send(
      'POST',
      '/rest/v1/rpc/sync_trip_itinerary',
      auth,
      body: {
        'p_trip_id': tripId.value,
        'p_plan_revised_at': planRevisedAt.toUtc().toIso8601String(),
        'p_days': [
          for (final day in days)
            {
              'day_number': day.number,
              'day_date': day.dateIso,
              'place': day.place,
              'revised_at': day.revisedAt.toUtc().toIso8601String(),
              'stops': [
                for (final stop in day.stops)
                  {
                    'position': stop.position,
                    'stop_text': stop.text,
                    'time_of_day': stop.timeIso,
                  },
              ],
            },
        ],
        'p_pocket_revised_at': pocketRevisedAt.toUtc().toIso8601String(),
        'p_pocket': [
          for (final line in setAside)
            {
              'position': line.position,
              'source_line_number': line.sourceLineNumber,
              'line_text': line.text,
              'explanation': line.explanation,
            },
        ],
      },
    );
    return parseItinerary(response);
  }

  /// The function's return value, as the phone reads it.
  ///
  /// Public because it is the half of the wire contract a test can pin
  /// against a literal captured from `supabase/tests/rls_probe.py`, which is
  /// the only thing that keeps the two spellings of this payload honest.
  static RemoteItinerary parseItinerary(Object? payload) {
    final body = payload is Map<String, dynamic>
        ? payload
        : throw SharedFactsRefused('sync returned ${payload.runtimeType}');
    return RemoteItinerary(
      planRevisedAt: _instant(body['plan_revised_at']),
      pocketRevisedAt: _instant(body['pocket_revised_at']),
      days: [
        for (final day in (body['days'] as List? ?? const []).cast<Map>())
          RemoteDay(
            number: (day['day_number'] as num).toInt(),
            dateIso: day['day_date'] as String?,
            place: day['place'] as String?,
            revisedAt: _instant(day['revised_at']),
            stops: [
              for (final stop
                  in (day['stops'] as List? ?? const []).cast<Map>())
                RemoteStop(
                  position: (stop['position'] as num).toInt(),
                  text: stop['stop_text'] as String,
                  // Postgres spells a `time` as `HH:MM:SS`; the phone keeps
                  // `HH:MM` (`cairn_model.ClockTime`). Trimming here rather
                  // than in the seam keeps the wire's dialect in the band
                  // that speaks it.
                  timeIso: _clock(stop['time_of_day'] as String?),
                ),
            ],
          ),
      ],
      setAside: [
        for (final line
            in (body['set_asides'] as List? ?? const []).cast<Map>())
          RemoteSetAside(
            position: (line['position'] as num).toInt(),
            sourceLineNumber: (line['source_line_number'] as num).toInt(),
            text: line['line_text'] as String,
            explanation: line['explanation'] as String? ?? '',
          ),
      ],
    );
  }

  Future<SharedFactsSession> _demand() async {
    if (!config.isConfigured) {
      throw const SharedFactsUnavailable('no backend is configured');
    }
    final auth = await sessions.current();
    if (auth == null) {
      throw const SharedFactsUnavailable('nobody is signed in');
    }
    return auth;
  }

  Map<String, String> _headers(SharedFactsSession auth) => {
    'apikey': config.anonKey,
    'Authorization': 'Bearer ${auth.accessToken}',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Future<Object?> _get(String path, SharedFactsSession auth) =>
      _send('GET', path, auth);

  Future<Object?> _send(
    String method,
    String path,
    SharedFactsSession auth, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request(method, Uri.parse('${config.url}$path'))
      ..headers.addAll({..._headers(auth), ...headers});
    if (body != null) request.body = jsonEncode(body);

    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const SharedFactsUnavailable('the server did not answer in time');
    } on SocketException catch (e) {
      throw SharedFactsUnavailable('no route to the server: ${e.message}');
    } on http.ClientException catch (e) {
      throw SharedFactsUnavailable(
        'the request did not complete: ${e.message}',
      );
    }

    // 5xx is "later" and 4xx is "no" — the distinction the whole offline
    // story rests on. A caller retries the first and must never retry the
    // second: `insufficient_privilege` from `sync_trip_itinerary` arrives as
    // a 403 and means this phone is not on the trip, which no amount of
    // waiting fixes.
    if (response.statusCode >= 500) {
      throw SharedFactsUnavailable(
        'the server answered ${response.statusCode}',
      );
    }
    if (response.statusCode >= 400) {
      throw SharedFactsRefused(_message(response));
    }
    if (response.body.isEmpty) return null;
    return jsonDecode(response.body);
  }

  static String _message(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['message'] is String) {
        return '${response.statusCode}: ${body['message']}';
      }
    } on FormatException {
      // PostgREST answers JSON, but a gateway in front of it may not.
    }
    return '${response.statusCode}: ${response.body}';
  }

  static List<Map<String, dynamic>> _rows(Object? payload) => switch (payload) {
    final List rows => rows.cast<Map<String, dynamic>>(),
    final Map<String, dynamic> row => [row],
    _ => const [],
  };

  static DateTime _instant(Object? raw) {
    if (raw is! String) return DateTime.utc(1970);
    // `-infinity` is what a trip that has never been revised carries, and
    // `DateTime.parse` cannot read it. It means the same thing the epoch
    // does here: older than anything anyone has actually said.
    if (raw.endsWith('infinity')) {
      return raw.startsWith('-') ? DateTime.utc(1970) : DateTime.utc(9999);
    }
    return DateTime.parse(raw).toUtc();
  }

  static String? _clock(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : raw;
  }
}
