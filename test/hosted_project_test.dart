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
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  MemoryVault({this.stored});

  StoredSession? stored;

  String? get token => stored?.refreshToken;

  @override
  Future<StoredSession?> read() async => stored;
  @override
  Future<void> write(StoredSession? session) async => stored = session;
}

class BlockingVault extends MemoryVault {
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<void> write(StoredSession? session) async {
    writeStarted.complete();
    await releaseWrite.future;
    await super.write(session);
  }
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
      expect(deviceSessions(config: off), isA<NoSession>());
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
      final vault = MemoryVault(
        stored: const StoredSession(
          userId: 'user-a',
          refreshToken: 'saved-refresh',
        ),
      );
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

    test(
      'does not expose a rotated session before its token is saved',
      () async {
        final vault = BlockingVault();
        final sessions = GotrueSessions(
          config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
          vault: vault,
          client: MockClient(
            (_) async => http.Response(sessionBody('user-a'), 200),
          ),
        );
        var completed = false;

        final acquiring = sessions.current().then((session) {
          completed = true;
          return session;
        });
        await vault.writeStarted.future;
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        vault.releaseWrite.complete();
        expect((await acquiring)!.userId.value, 'user-a');
        expect(vault.token, 'refresh-1');
      },
    );

    test('a refused refresh token is dropped, not retried forever', () async {
      final vault = MemoryVault(
        stored: const StoredSession(userId: 'user-a', refreshToken: 'revoked'),
      );
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
      // The id was replaced in the same write. A vault naming the old account
      // beside the new account's token would have this phone introduce itself
      // as somebody it can no longer speak as.
      expect(vault.stored!.userId, 'user-b');
    });

    test(
      'a non-token 4xx keeps the stored account and does not mint',
      () async {
        final saved = const StoredSession(
          userId: 'user-a',
          refreshToken: 'saved-refresh',
        );
        final vault = MemoryVault(stored: saved);
        var calls = 0;
        final sessions = GotrueSessions(
          config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
          vault: vault,
          client: MockClient((request) async {
            calls++;
            return http.Response('{"error":"captcha_failed"}', 400);
          }),
        );

        expect(await sessions.current(), isNull);
        expect(
          calls,
          1,
          reason: 'an auth gateway error must not mint a stranger',
        );
        expect(vault.stored, same(saved));
      },
    );

    test('a server that cannot be reached keeps the saved token', () async {
      final vault = MemoryVault(
        stored: const StoredSession(
          userId: 'user-a',
          refreshToken: 'saved-refresh',
        ),
      );
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

    test('a captive portal answering HTML is unreachable, not a refusal', () async {
      final vault = MemoryVault(
        stored: const StoredSession(
          userId: 'user-a',
          refreshToken: 'saved-refresh',
        ),
      );
      var calls = 0;
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        vault: vault,
        client: MockClient((request) async {
          calls++;
          return http.Response('<html>sign in to the wifi</html>', 200);
        }),
      );

      // Not an exception: `main` signs in on the boot path, so a throw here is
      // an app that never renders a frame.
      expect(await sessions.current(), isNull);
      expect(calls, 1);
      expect(vault.token, 'saved-refresh');
    });

    test('a 2xx whose JSON is not a map is unreachable, not a verdict '
        'on the token', () async {
      final vault = MemoryVault(
        stored: const StoredSession(
          userId: 'user-a',
          refreshToken: 'saved-refresh',
        ),
      );
      var calls = 0;
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        vault: vault,
        client: MockClient((request) async {
          calls++;
          return http.Response('["a proxy answering in the wrong shape"]', 200);
        }),
      );

      // Only GoTrue's explicit dead-refresh-token verdict may spend the
      // saved account; a lying intermediary is a tunnel, not a refusal.
      expect(await sessions.current(), isNull);
      expect(calls, 1);
      expect(vault.token, 'saved-refresh');
    });

    test('a refused handshake is unreachable too', () async {
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        client: MockClient((request) async {
          throw const HandshakeException('interception');
        }),
      );
      expect(await sessions.current(), isNull);
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

  group('who the phone is on the boot path', () {
    test('comes off the vault, with no network in it', () async {
      var calls = 0;
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        client: MockClient((request) async {
          calls++;
          return http.Response(sessionBody('user-a'), 200);
        }),
      );

      final id = await resolveMemberId(
        sessions,
        MemoryVault(
          stored: const StoredSession(userId: 'user-a', refreshToken: 'r'),
        ),
      );
      expect(id, 'user-a');
      expect(calls, 0, reason: 'the boot path must not wait on a server');
    });

    test('a first launch that is too slow runs as the stand-in', () async {
      final sessions = GotrueSessions(
        config: const SharedFactsConfig(url: 'https://p.test', anonKey: 'k'),
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response(sessionBody('user-a'), 200);
        }),
      );

      expect(
        await resolveMemberId(
          sessions,
          MemoryVault(),
          budget: const Duration(milliseconds: 20),
        ),
        isNull,
      );
    });

    test('a build with no backend asks the vault nothing', () async {
      expect(await resolveMemberId(const NoSession(), MemoryVault()), isNull);
    });
  });
}
