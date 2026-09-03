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
import 'dart:typed_data';

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

class AbortObservingClient extends http.BaseClient {
  http.AbortableRequest? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.AbortableRequest;
    this.request = abortable;
    await abortable.abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
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
        {
          'position': 0,
          'stop_text': 'Vigeland',
          'time_of_day': null,
          'kind': 'place',
          'area_text': 'Frogner',
          'area_source': 'human',
        },
        {
          'position': 1,
          'stop_text': 'Opera',
          'time_of_day': '10:12:00',
          'kind': 'place',
          'area_text': null,
          'area_source': null,
        },
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
  http.Client client, {
  SessionSource sessions = const OneSession(),
  Duration timeout = const Duration(seconds: 10),
}) => PostgrestSharedFacts(
  config: config,
  sessions: sessions,
  client: client,
  timeout: timeout,
);

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
              RemoteStop(
                position: 0,
                text: 'Vigeland',
                kind: 'place',
                areaText: 'Frogner',
                areaSource: 'human',
              ),
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
      // The tap-to-Maps columns, spelled as `sync_trip_itinerary` reads them
      // since migration 0013. A stop carrying no area still sends all three
      // keys: the SQL half coalesces a missing `kind` to 'place', but an
      // area cannot be *cleared* on another phone by a key that is absent.
      expect(stops.first['kind'], 'place');
      expect(stops.first['area_text'], 'Frogner');
      expect(stops.first['area_source'], 'human');
      expect(stops.last['area_text'], isNull);
      expect(stops.last.containsKey('area_source'), isTrue);
      expect(
        stops.last['kind'],
        isNull,
        reason:
            "a stop the phone has no kind for sends null, and the function's "
            "coalesce is what makes it 'place' in the table",
      );

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
      expect(merged.days.first.stops.first.areaText, 'Frogner');
      expect(merged.days.first.stops.first.areaSource, 'human');
      expect(
        merged.days.first.stops.map((s) => s.carriesAreas),
        [true, true],
        reason:
            'the function emits all three keys even when they are null, and '
            "the key's presence is what says the server knows about areas",
      );
      expect(merged.days.first.dateIso, '2027-06-14');
      expect(merged.days.last.dateIso, isNull);
      expect(merged.days.last.revisedAt, DateTime.utc(2027, 6, 2));
      expect(merged.setAside.single.text, 'book the cabin');
    });

    test(
      'a server without migration 0013 says nothing, not "no area"',
      () async {
        // The whole reason 0013 exists: until it is applied,
        // `sync_trip_itinerary` returns the pre-0012 column set, so a stop
        // comes back with no `area_text` key at all. That is "this server does
        // not know", never "this stop has no area" -- reading it as the latter
        // would null every hand-made correction on the phone.
        const oldServer = {
          'plan_revised_at': '2027-06-03T00:00:00+00:00',
          'pocket_revised_at': '2027-06-03T00:00:00+00:00',
          'days': [
            {
              'day_number': 1,
              'day_date': '2027-06-14',
              'place': 'Oslo',
              'revised_at': '2027-06-03T00:00:00+00:00',
              'stops': [
                {'position': 0, 'stop_text': 'Vigeland', 'time_of_day': null},
              ],
            },
          ],
          'set_asides': <Map<String, Object?>>[],
        };
        final sync = facts(
          MockClient((_) async => http.Response(jsonEncode(oldServer), 200)),
        );

        final merged = await sync.syncItinerary(
          tripId: trip,
          planRevisedAt: DateTime.utc(1970),
          days: const [],
          pocketRevisedAt: DateTime.utc(1970),
          setAside: const [],
        );

        expect(merged.days.single.stops.single.carriesAreas, isFalse);
      },
    );
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
                {
                  'name': 'Norway',
                  'name_revised_at': '2027-06-13T00:00:00+00:00',
                  'created_by': anna,
                },
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
      expect(shared.nameRevisedAt, DateTime.utc(2027, 6, 13));
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
          nameRevisedAt: DateTime.utc(2027, 6, 13),
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
      expect(body['name_revised_at'], '2027-06-13T00:00:00.000Z');
      expect(body['timezone'], 'Europe/Oslo');
      expect(body['start_date'], '2027-06-14');
    });

    test('a rename goes through the clocked name RPC', () async {
      late http.Request seen;
      final sync = facts(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'name': 'Norway, June',
              'name_revised_at': '2027-06-15T09:30:00+00:00',
            }),
            200,
          );
        }),
      );

      final answer = await sync.syncTripName(
        tripId: trip,
        name: 'Norway, June',
        revisedAt: DateTime.utc(2027, 6, 15, 9, 30),
      );

      expect(seen.url.path, '/rest/v1/rpc/sync_trip_name');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['p_trip_id'], trip.value);
      expect(body['p_name'], 'Norway, June');
      expect(body['p_name_revised_at'], '2027-06-15T09:30:00.000Z');
      expect(answer.name, 'Norway, June');
      expect(answer.revisedAt, DateTime.utc(2027, 6, 15, 9, 30));
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

  group('the upload ticket is minted at the function, as the caller', () {
    test('the mint carries the session and every field the handler '
        'demands', () async {
      // `r2-upload-url/handler.ts` requires all four, and signs the content
      // length into the URL — a mint without it produces a ticket no PUT can
      // honour. These key spellings are the handler's, letter for letter.
      late http.Request seen;
      final sync = facts(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'uploadUrl':
                  'https://r2.example/trips/${trip.value}/photos/photo-9/original.jpg?X-Amz-Signature=abc',
              'objectKey': 'trips/${trip.value}/photos/photo-9/original.jpg',
              'expiresInSeconds': 300,
            }),
            200,
          );
        }),
      );

      final before = DateTime.now().toUtc();
      final ticket = await sync.photoUploadTicket(
        tripId: trip,
        photoId: 'photo-9',
        contentType: 'image/jpeg',
        byteSize: 12345,
      );

      expect(seen.url.path, '/functions/v1/r2-upload-url');
      expect(seen.method, 'POST');
      expect(seen.headers['apikey'], 'publishable-anon-key');
      expect(seen.headers['Authorization'], 'Bearer jwt-for-anna');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body, {
        'tripId': trip.value,
        'photoId': 'photo-9',
        'contentType': 'image/jpeg',
        'contentLength': 12345,
      });
      expect(
        ticket.objectKey,
        'trips/${trip.value}/photos/photo-9/original.jpg',
      );
      expect(ticket.uploadUrl.queryParameters, contains('X-Amz-Signature'));
      expect(ticket.contentType, 'image/jpeg');
      expect(ticket.byteSize, 12345);
      expect(
        ticket.expiresAt.difference(before).inSeconds,
        inInclusiveRange(295, 305),
        reason: 'expiresInSeconds: 300, counted from the mint',
      );
    });

    test('a 403 at the mint is no, and terminal', () async {
      final sync = facts(
        MockClient(
          (_) async => http.Response('{"error":"trip is closed"}', 403),
        ),
      );

      await expectLater(
        sync.photoUploadTicket(
          tripId: trip,
          photoId: 'photo-9',
          contentType: 'image/jpeg',
          byteSize: 1,
        ),
        throwsA(isA<SharedFactsRefused>()),
      );
    });

    test('a gateway 404 at the mint is retryable, not a refusal', () async {
      final sync = facts(
        MockClient((_) async => http.Response('{"code":"NOT_FOUND"}', 404)),
      );

      await expectLater(
        sync.photoUploadTicket(
          tripId: trip,
          photoId: 'photo-9',
          contentType: 'image/jpeg',
          byteSize: 1,
        ),
        throwsA(isA<UploadTicketRejected>()),
      );
    });

    test('the function\'s own 400 validation error is terminal', () async {
      final sync = facts(
        MockClient((_) async => http.Response('unsupported content type', 400)),
      );

      await expectLater(
        sync.photoUploadTicket(
          tripId: trip,
          photoId: 'photo-9',
          contentType: 'image/gif',
          byteSize: 1,
        ),
        throwsA(isA<SharedFactsRefused>()),
      );
    });
  });

  group('the PUT is the other transport, and shares nothing', () {
    final ticket = RemoteUploadTicket(
      uploadUrl: Uri.parse(
        'https://r2.example/trips/t/photos/p/original.jpg?X-Amz-Signature=abc',
      ),
      objectKey: 'trips/t/photos/p/original.jpg',
      contentType: 'image/jpeg',
      byteSize: 4,
      expiresAt: DateTime.utc(2027, 6, 15, 12, 5),
    );
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    test('signed URL, exact content type, whole body — and no Supabase '
        'headers at all', () async {
      // The URL's query signature *is* the authorization; an S3-dialect
      // store refuses a request carrying an Authorization header besides.
      // And aws4fetch signed the exact Content-Type and Content-Length into
      // that signature, so both must be what was minted, byte for byte.
      late http.Request seen;
      final sync = facts(
        MockClient((request) async {
          seen = request;
          return http.Response('', 200);
        }),
      );

      await sync.putPhotoBytes(ticket, bytes);

      expect(seen.method, 'PUT');
      expect(seen.url, ticket.uploadUrl);
      expect(seen.headers.containsKey('apikey'), isFalse);
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(seen.headers['Content-Type'], 'image/jpeg');
      expect(seen.bodyBytes, bytes);
      expect(seen.contentLength, bytes.length);
    });

    test('a 4xx at the PUT kills the ticket, not the photograph', () async {
      final sync = facts(
        MockClient((_) async => http.Response('SignatureDoesNotMatch', 403)),
      );

      await expectLater(
        sync.putPhotoBytes(ticket, bytes),
        throwsA(
          isA<UploadTicketRejected>().having(
            (e) => e.reason,
            'reason',
            contains('SignatureDoesNotMatch'),
          ),
        ),
        reason:
            'expired signature or clock skew: mint afresh and retry, '
            'never refuse the photo',
      );
    });

    test('a 5xx at the store is later', () async {
      final sync = facts(
        MockClient((_) async => http.Response('InternalError', 500)),
      );

      await expectLater(
        sync.putPhotoBytes(ticket, bytes),
        throwsA(isA<SharedFactsUnavailable>()),
      );
    });

    test('no route to the store is later too', () async {
      final sync = facts(
        MockClient((_) async => throw const SocketException('no route')),
      );

      await expectLater(
        sync.putPhotoBytes(ticket, bytes),
        throwsA(isA<SharedFactsUnavailable>()),
      );
    });

    test('a size-budget timeout aborts the underlying PUT', () async {
      final client = AbortObservingClient();
      final sync = facts(client, timeout: Duration.zero);

      await expectLater(
        sync.putPhotoBytes(ticket, bytes),
        throwsA(isA<UploadTicketRejected>()),
      );
      expect(client.request, isNotNull);
      expect(client.request!.abortTrigger, completes);
    });
  });

  group('the photo row is spelled the way the table reads it', () {
    RemotePhoto photo({String contributor = anna}) => RemotePhoto(
      id: 'photo-9',
      tripId: trip.value,
      contributorId: contributor,
      r2ObjectKey: 'trips/${trip.value}/photos/photo-9/original.jpg',
      contentType: 'image/jpeg',
      byteSize: 12345,
      capturedAtIso: '2027-06-14T09:00:00.000Z',
      dayNumber: 1,
      tripDayIso: '2027-06-14',
      caption: 'first light',
      updatedAtIso: '2027-06-15T12:00:00.000Z',
    );

    test('an idempotent insert: on_conflict, ignore-duplicates, and the '
        'column spellings', () async {
      late http.Request seen;
      final sync = facts(
        MockClient((request) async {
          seen = request;
          return http.Response('', 201);
        }),
      );

      await sync.recordPhoto(photo());

      expect(seen.url.path, '/rest/v1/photos');
      expect(seen.url.queryParameters['on_conflict'], 'id');
      expect(
        seen.headers['Prefer'],
        'resolution=ignore-duplicates,return=minimal',
      );
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['id'], 'photo-9');
      expect(body['trip_id'], trip.value);
      expect(body['contributor_id'], anna);
      expect(
        body['r2_object_key'],
        'trips/${trip.value}/photos/photo-9/original.jpg',
      );
      expect(body['content_type'], 'image/jpeg');
      expect(body['byte_size'], 12345);
      expect(body['captured_at'], '2027-06-14T09:00:00.000Z');
      expect(body['day_number'], 1);
      expect(body['trip_day'], '2027-06-14');
      expect(body['caption'], 'first light');
      expect(
        body.containsKey('updated_at'),
        isFalse,
        reason: "the server's touch trigger owns updated_at",
      );
      expect(
        body.containsKey('width'),
        isFalse,
        reason: 'an absent dimension is absent, not null',
      );
    });

    test('a refused insert whose row turns out to be mine is a silent '
        'success', () async {
      // The replay that ignore-duplicates could not swallow: the row landed,
      // the ack was lost, and the retry's insert bounced. One read-back
      // settles it.
      final paths = <String>[];
      final sync = facts(
        MockClient((request) async {
          paths.add('${request.method} ${request.url.path}');
          if (request.method == 'POST') {
            return http.Response('{"message":"duplicate key"}', 409);
          }
          expect(request.url.queryParameters['id'], 'eq.photo-9');
          return http.Response(
            jsonEncode([
              {'id': 'photo-9', 'contributor_id': anna},
            ]),
            200,
          );
        }),
      );

      await sync.recordPhoto(photo());

      expect(paths, ['POST /rest/v1/photos', 'GET /rest/v1/photos']);
    });

    test("a refused insert over somebody else's row stays refused", () async {
      final sync = facts(
        MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response('{"message":"duplicate key"}', 409);
          }
          return http.Response(
            jsonEncode([
              {
                'id': 'photo-9',
                'contributor_id': 'b0000000-0000-4000-8000-000000000002',
              },
            ]),
            200,
          );
        }),
      );

      await expectLater(
        sync.recordPhoto(photo()),
        throwsA(isA<SharedFactsRefused>()),
        reason:
            'the id is claimed and the claim is not this phone\'s; '
            'no retry changes that',
      );
    });

    test('a PGRST schema-cache error is retryable', () async {
      final sync = facts(
        MockClient(
          (_) async => http.Response(
            '{"code":"PGRST204","message":"column is not in schema cache"}',
            400,
          ),
        ),
      );

      await expectLater(
        sync.recordPhoto(photo()),
        throwsA(isA<UploadTicketRejected>()),
      );
    });
  });

  group('the caption is a patch on the caller\'s own row', () {
    test('both filters, the one column, and no row asked back', () async {
      late http.Request seen;
      final sync = facts(
        MockClient((request) async {
          seen = request;
          return http.Response('', 204);
        }),
      );

      await sync.writePhotoCaption(
        tripId: trip,
        photoId: 'photo-9',
        caption: 'hindsight',
      );

      expect(seen.method, 'PATCH');
      expect(seen.url.path, '/rest/v1/photos');
      expect(seen.url.queryParameters['id'], 'eq.photo-9');
      expect(seen.url.queryParameters['trip_id'], 'eq.${trip.value}');
      expect(seen.headers['Prefer'], 'return=minimal');
      expect(jsonDecode(seen.body), {'caption': 'hindsight'});
    });

    test('clearing the word sends an explicit null, not an empty '
        'patch', () async {
      late http.Request seen;
      final sync = facts(
        MockClient((request) async {
          seen = request;
          return http.Response('', 204);
        }),
      );

      await sync.writePhotoCaption(
        tripId: trip,
        photoId: 'photo-9',
        caption: null,
      );

      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body.containsKey('caption'), isTrue);
      expect(body['caption'], isNull);
    });
  });
}
