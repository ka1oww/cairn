// The wire itself: what the phone actually sends to PostgREST, and what it
// makes of what comes back.
//
// Mocked at the HTTP client, which is as low as this can honestly go — the
// adapter's whole job is composing a request and reading a response, and a
// double any higher would be testing a stub. `package:http`'s own MockClient
// is the tool for it; nothing else in the repository needs a mocking package
// and this does not either.
//
// **The payload's spelling is the thing under test.** The Dart half and the
// SQL half of `sync_trip_itinerary` are written independently and have to
// agree key for key; `supabase/tests/rls_probe.py` pins the SQL half against
// a real Postgres, and the literals here are that same shape. A key renamed
// on one side and not the other is exactly the bug that would otherwise be
// found on a phone in another country.
import 'dart:convert';
import 'dart:io';

import 'package:cairn_model/cairn_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cairn/storage/remote/postgrest_shared_facts.dart';
import 'package:cairn/storage/remote/shared_facts.dart';

const config = SharedFactsConfig(
  url: 'https://example.supabase.co',
  anonKey: 'publishable-anon-key',
);

final trip = TripId('7d3f2a10-0000-4000-8000-00000000000a');
const anna = 'a0000000-0000-4000-8000-000000000001';

class OneSession implements SessionSource {
  const OneSession();
  @override
  Future<SharedFactsSession?> current() async =>
      SharedFactsSession(accessToken: 'jwt-for-anna', userId: MemberId(anna));
}

class NobodySignedIn implements SessionSource {
  const NobodySignedIn();
  @override
  Future<SharedFactsSession?> current() async => null;
}

/// The RPC's answer, spelled as `sync_trip_itinerary` spells it.
const mergedPlan = {
  'plan_revised_at': '2027-06-03T00:00:00+00:00',
  'pocket_revised_at': '-infinity',
  'days': [
    {
      'day_number': 1,
      'day_date': '2027-06-14',
      'place': 'Oslo',
      'revised_at': '2027-06-03T00:00:00+00:00',
      'stops': [
        {'position': 0, 'stop_text': 'Vigeland', 'time_of_day': null},
        {'position': 1, 'stop_text': 'Opera', 'time_of_day': '10:12:00'},
      ],
    },
    {
      'day_number': 2,
      'day_date': null,
      'place': 'Bergen',
      'revised_at': '2027-06-02T00:00:00+00:00',
      'stops': <Map<String, Object?>>[],
    },
  ],
  'set_asides': [
    {
      'position': 0,
      'source_line_number': 9,
      'line_text': 'book the cabin',
      'explanation': 'no day named',
    },
  ],
};

PostgrestSharedFacts facts(
  MockClient client, {
  SessionSource sessions = const OneSession(),
}) => PostgrestSharedFacts(config: config, sessions: sessions, client: client);

void main() {
  group('a request carries the key and the session, and nothing else', () {
    test('the anon key and the bearer token both go up', () async {
      late http.BaseRequest seen;
      final sync = facts(
        MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode(mergedPlan), 200);
        }),
      );

      await sync.syncItinerary(
        tripId: trip,
        planRevisedAt: DateTime.utc(2027, 6, 3),
        days: const [],
        pocketRevisedAt: DateTime.utc(1970),
        setAside: const [],
      );

      expect(seen.headers['apikey'], 'publishable-anon-key');
      expect(seen.headers['Authorization'], 'Bearer jwt-for-anna');
      expect(seen.url.path, '/rest/v1/rpc/sync_trip_itinerary');
      expect(seen.method, 'POST');
    });

    test('with no backend configured nothing is sent at all', () async {
      var calls = 0;
      final sync = PostgrestSharedFacts(
        config: const SharedFactsConfig(url: '', anonKey: ''),
        sessions: const OneSession(),
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        sync.readTrip(trip),
        throwsA(isA<SharedFactsUnavailable>()),
      );
      expect(calls, 0);
    });

    test('with nobody signed in nothing is sent either', () async {
      var calls = 0;
      final sync = facts(
        MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
        sessions: const NobodySignedIn(),
      );

      await expectLater(
        sync.readTrip(trip),
        throwsA(isA<SharedFactsUnavailable>()),
      );
      expect(calls, 0);
    });
  });

  group('the push is spelled the way the function reads it', () {
    test('every argument the RPC declares, and the stops nested', () async {
      late Map<String, dynamic> body;
      final sync = facts(
        MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode(mergedPlan), 200);
        }),
      );

      await sync.syncItinerary(
        tripId: trip,
        planRevisedAt: DateTime.utc(2027, 6, 3),
        days: [
          RemoteDay(
            number: 1,
            dateIso: '2027-06-14',
            place: 'Oslo',
            revisedAt: DateTime.utc(2027, 6, 3),
            stops: const [
              RemoteStop(position: 0, text: 'Vigeland'),
              RemoteStop(position: 1, text: 'Opera', timeIso: '10:12'),
            ],
          ),
        ],
        pocketRevisedAt: DateTime.utc(2027, 6, 2),
        setAside: const [
          RemoteSetAside(
            position: 0,
            sourceLineNumber: 9,
            text: 'book the cabin',
            explanation: 'no day named',
          ),
        ],
      );

      expect(
        body.keys,
        containsAll(<String>[
          'p_trip_id',
          'p_plan_revised_at',
          'p_days',
          'p_pocket_revised_at',
          'p_pocket',
        ]),
      );
      expect(body['p_trip_id'], trip.value);
      expect(body['p_plan_revised_at'], '2027-06-03T00:00:00.000Z');

      final day = (body['p_days'] as List).single as Map<String, dynamic>;
      expect(day['day_number'], 1);
      expect(day['day_date'], '2027-06-14');
      expect(day['place'], 'Oslo');
      expect(day['revised_at'], '2027-06-03T00:00:00.000Z');
      final stops = (day['stops'] as List).cast<Map<String, dynamic>>();
      expect(stops.map((s) => s['stop_text']), ['Vigeland', 'Opera']);
      expect(stops.last['time_of_day'], '10:12');

      final line = (body['p_pocket'] as List).single as Map<String, dynamic>;
      expect(line['source_line_number'], 9);
      expect(line['line_text'], 'book the cabin');
    });

    test('the answer is read back whole, in order, with the clocks', () async {
      final sync = facts(
        MockClient((_) async => http.Response(jsonEncode(mergedPlan), 200)),
      );

      final merged = await sync.syncItinerary(
        tripId: trip,
        planRevisedAt: DateTime.utc(1970),
        days: const [],
        pocketRevisedAt: DateTime.utc(1970),
        setAside: const [],
      );

      expect(merged.planRevisedAt, DateTime.utc(2027, 6, 3));
      expect(
        merged.pocketRevisedAt,
        DateTime.utc(1970),
        reason:
            "'-infinity' is a timestamp DateTime.parse cannot read, and "
            'it means what the epoch means here',
      );
      expect(merged.days.map((d) => d.number), [1, 2]);
      expect(merged.days.first.stops.map((s) => s.text), ['Vigeland', 'Opera']);
      expect(
        merged.days.first.stops.last.timeIso,
        '10:12',
        reason: "Postgres spells a time HH:MM:SS; the phone keeps HH:MM",
      );
      expect(merged.days.first.dateIso, '2027-06-14');
      expect(merged.days.last.dateIso, isNull);
      expect(merged.days.last.revisedAt, DateTime.utc(2027, 6, 2));
      expect(merged.setAside.single.text, 'book the cabin');
    });
  });

  group('the trip row and the roster', () {
    test(
      'a trip nobody has shared reads as nothing, not as an error',
      () async {
        // Row-level security refuses by filtering to zero rows. "Never heard of
        // it" and "not yours" are the same answer here, and both mean there is
        // nothing to reconcile with.
        final sync = facts(MockClient((_) async => http.Response('[]', 200)));

        expect(await sync.readTrip(trip), isNull);
      },
    );

    test('the roster comes back from the view, joined_at and all', () async {
      final paths = <String>[];
      final sync = facts(
        MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/rest/v1/trips') {
            return http.Response(
              jsonEncode([
                {'name': 'Norway', 'created_by': anna},
              ]),
              200,
            );
          }
          return http.Response(
            jsonEncode([
              {
                'user_id': anna,
                'display_name': 'Anna',
                'joined_at': '2027-06-14T08:00:00+00:00',
              },
            ]),
            200,
          );
        }),
      );

      final shared = await sync.readTrip(trip);

      expect(paths, ['/rest/v1/trips', '/rest/v1/trip_roster']);
      expect(shared!.name, 'Norway');
      expect(shared.startedBy, MemberId(anna));
      expect(shared.members.single.displayName, 'Anna');
      expect(shared.members.single.joinedAt, DateTime.utc(2027, 6, 14, 8));
    });

    test('creating the trip row is an insert and never a merge', () async {
      // Two parties' trips merged into one is what `on conflict do update`
      // would buy; an insert raises instead, which is the honest answer to
      // "make this".
      late http.BaseRequest seen;
      final sync = facts(
        MockClient((request) async {
          seen = request;
          return http.Response('', 201);
        }),
      );

      await sync.createTrip(
        RemoteTripDraft(
          id: trip,
          name: 'Norway',
          createdBy: MemberId(anna),
          timeZone: 'Europe/Oslo',
          startDateIso: '2027-06-14',
          endDateIso: '2027-06-18',
        ),
      );

      expect(seen.url.path, '/rest/v1/trips');
      expect(seen.headers['Prefer'], isNot(contains('merge-duplicates')));
      final body =
          jsonDecode((seen as http.Request).body) as Map<String, dynamic>;
      expect(body['id'], trip.value);
      expect(body['timezone'], 'Europe/Oslo');
      expect(body['start_date'], '2027-06-14');
    });
  });

  group('later and no are not the same answer', () {
    Future<void> answering(int status, Matcher matcher) async {
      final sync = facts(
        MockClient((_) async => http.Response('{"message":"nope"}', status)),
      );
      await expectLater(sync.readTrip(trip), throwsA(matcher));
    }

    test('a 5xx is later, so the caller may try again', () async {
      // A free-tier project resuming from its pause answers exactly this.
      await answering(503, isA<SharedFactsUnavailable>());
    });

    test('a 403 is no, and retrying it changes nothing', () async {
      // `insufficient_privilege` from `sync_trip_itinerary`: this phone is
      // not on the trip. No amount of waiting fixes that.
      await answering(403, isA<SharedFactsRefused>());
    });

    test('a 409 is no as well — the trip row already exists', () async {
      await answering(409, isA<SharedFactsRefused>());
    });

    test(
      'no route to the host is later, not an error to show anyone',
      () async {
        final sync = facts(
          MockClient((_) async => throw const SocketException('no route')),
        );

        await expectLater(
          sync.readTrip(trip),
          throwsA(isA<SharedFactsUnavailable>()),
        );
      },
    );
  });
}
