// What a build is pointed at, and how it signs in.
//
// Two halves, and only the first runs by default.
//
//  1. The config the app ships with. No client, no double: it reads the same
//     compile-time constant `bootstrap.dart` reads, and asserts it names the
//     hosted project and carries a key that is the *publishable* one. A
//     service-role key pasted in by accident would fail here, which is the
//     point — it is the one class of mistake in this file that matters.
//  2. `GotrueSessions`, mocked at the HTTP client the way
//     `postgrest_adapter_test.dart` is, because the same reasoning applies:
//     the class's whole job is composing three requests and remembering what
//     came back.
//
// The *live* round trip against the hosted project is `hosted_smoke_test.dart`
// and is skipped unless asked for. See `supabase/README.md`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/remote/gotrue_sessions.dart';
import 'package:cairn/storage/remote/shared_facts.dart';

/// The claims of a Supabase key, without verifying its signature — this is
/// reading a label, not trusting one.
Map<String, dynamic> claims(String jwt) {
  final payload = jwt.split('.')[1];
  return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))))
      as Map<String, dynamic>;
}

class MemoryVault implements SessionVault {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String? refreshToken) async => token = refreshToken;
}

/// A GoTrue answer, spelled the way GoTrue spells one.
String sessionBody(String userId, {String refresh = 'refresh-1'}) =>
    jsonEncode({
      'access_token': 'jwt-$userId',
      'refresh_token': refresh,
      'expires_in': 3600,
      'token_type': 'bearer',
      'user': {'id': userId, 'is_anonymous': true},
    });

void main() {
  group('the build is pointed at the hosted project', () {
    test('by default, with nothing passed', () {
      const config = SharedFactsConfig.fromEnvironment;
      expect(config.isConfigured, isTrue);
      expect(config.url, SharedFactsConfig.hostedUrl);
      expect(config.url, startsWith('https://'));
    });

    test('the shipped key is the publishable one, for this project', () {
      final key = claims(SharedFactsConfig.hostedAnonKey);
      // `anon` is the role that ships in a client. `service_role` bypasses
      // every policy in supabase/migrations/ and must never be here.
      expect(key['role'], 'anon');
      expect(key['iss'], 'supabase');
      expect(SharedFactsConfig.hostedUrl, contains(key['ref'] as String));
    });

    test('an empty URL is how a build asks for no backend at all', () {
      const off = SharedFactsConfig(url: '', anonKey: 'anything');
      expect(off.isConfigured, isFalse);
      expect(deviceSessions(), isA<GotrueSessions>());
    });
  });

  group('GotrueSessions', () {
    test('mints one anonymous account and keeps the refresh token', () async {
      final vault = MemoryVault();
      var signUps = 0;
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        vault: vault,
        client: MockClient((request) async {
          expect(request.url.path, '/auth/v1/signup');
          expect(request.headers['apikey'], 'k');
          expect(jsonDecode(request.body), isEmpty);
          signUps++;
          return http.Response(sessionBody('user-a'), 200);
        }),
      );

      final first = await sessions.current();
      expect(first!.userId.value, 'user-a');
      expect(first.accessToken, 'jwt-user-a');
      expect(vault.token, 'refresh-1');

      // Held, not re-minted: the sync asks on every reconcile.
      expect((await sessions.current())!.userId.value, 'user-a');
      expect(signUps, 1);
    });

    test('comes back as the same account it was last launch', () async {
      final vault = MemoryVault()..token = 'saved-refresh';
      final paths = <String>[];
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        vault: vault,
        client: MockClient((request) async {
          paths.add(request.url.path);
          expect(jsonDecode(request.body), {'refresh_token': 'saved-refresh'});
          return http.Response(
            sessionBody('user-a', refresh: 'refresh-2'),
            200,
          );
        }),
      );

      expect((await sessions.current())!.userId.value, 'user-a');
      expect(paths, ['/auth/v1/token']);
      expect(vault.token, 'refresh-2');
    });

    test('a refused refresh token is dropped, not retried forever', () async {
      final vault = MemoryVault()..token = 'revoked';
      final paths = <String>[];
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        vault: vault,
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/auth/v1/token') {
            return http.Response('{"error":"invalid_grant"}', 400);
          }
          return http.Response(sessionBody('user-b'), 200);
        }),
      );

      expect((await sessions.current())!.userId.value, 'user-b');
      expect(paths, ['/auth/v1/token', '/auth/v1/signup']);
      expect(vault.token, 'refresh-1');
    });

    test('a server that cannot be reached keeps the saved token', () async {
      final vault = MemoryVault()..token = 'saved-refresh';
      var calls = 0;
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        vault: vault,
        client: MockClient((request) async {
          calls++;
          return http.Response('upstream is down', 503);
        }),
      );

      // Null, not an exception: the sync reads this as dormant and leaves the
      // local copy alone, which is what a train tunnel looks like.
      expect(await sessions.current(), isNull);
      // And it did not go on to mint a second account for a phone that
      // already has one.
      expect(calls, 1);
      expect(vault.token, 'saved-refresh');
    });

    test('no backend configured is no session and no request', () async {
      var calls = 0;
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: '', anonKey: ''),
        client: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      expect(await sessions.current(), isNull);
      expect(calls, 0);
    });
  });
}
