// STORAGE band: the other half of the Supabase adapter — who the phone is.
//
// `postgrest_shared_facts.dart` speaks to PostgREST and needs a bearer token
// to speak with at all; this file is where that token comes from. Same
// transport for the same reason: GoTrue is an ordinary REST API, and pulling
// in `supabase_flutter` to call three endpoints would put a second opinion
// about the schema — and a Podfile's worth of native dependencies — in the
// repository.
//
// ---------------------------------------------------------------------------
// WHY THE ACCOUNT IS ANONYMOUS, AND WHAT REPLACES IT
// ---------------------------------------------------------------------------
//
// Sign in with Apple is the first *real* auth route and is not built
// (docs/architecture.md, "Platform edges"). Every table in
// `supabase/migrations/` is behind row-level security keyed on `auth.uid()`,
// so until something signs in, the hosted project answers zero rows to
// everything and none of the shared facts can be exercised at all.
//
// A GoTrue anonymous account closes that gap without inventing a login: it is
// a real `auth.users` row, so `handle_new_user` mints the profile every policy
// compares against, and `auth.uid()` is a real uuid rather than a stand-in.
// What it is not is an *identity a person owns* — nobody can sign in to it
// from a second phone. That is exactly the line Apple sign-in crosses, and
// when it lands this class grows a second route rather than being replaced:
// GoTrue links an anonymous user to a real provider in place, keeping the
// uuid, which is what keeps the trips and photos already credited to it.
//
// **The refresh token is why this persists.** An anonymous account that is
// re-minted every cold start would orphan the trip it created the launch
// before — `trips.created_by` would point at yesterday's user, RLS would
// filter the trip to zero rows, and the phone would try to create a trip whose
// id already exists and be refused forever. So the refresh token is kept in a
// [SessionVault] and the same account comes back — and the account's *id* is
// kept beside it, because that is what lets a phone with no signal still know
// who it is (`bootstrap.dart`, `resolveMemberId`).
import 'dart:convert';
import 'dart:io';

import 'package:cairn_model/cairn_model.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'shared_facts.dart';

/// What a launch remembers about the account it signed in as.
///
/// The id is here for the same reason the token is, and it is the half that
/// matters when there is no network: the account's id *is* this phone's member
/// id, so a phone that knows only its refresh token has to reach the server
/// before it can say who it is, and a phone that cannot reach one would fall
/// back to the `me` stand-in and start crediting photographs to somebody the
/// roster it already holds does not contain. The two travel together and are
/// written together — a refused token is dropped with its id in the same
/// write, so the vault never names an account whose token belongs to another.
class StoredSession {
  const StoredSession({required this.userId, required this.refreshToken});

  final String userId;
  final String refreshToken;
}

/// Where the account lives between launches.
///
/// An interface because a test must not touch the device's filesystem, and
/// because real file I/O inside `testWidgets` hangs silently under the faked
/// clock (AGENTS.md).
abstract interface class SessionVault {
  Future<StoredSession?> read();
  Future<void> write(StoredSession? session);
}

/// Keeps nothing. A build with no backend, and every test that does not care.
class NoVault implements SessionVault {
  const NoVault();

  @override
  Future<StoredSession?> read() async => null;

  @override
  Future<void> write(StoredSession? session) async {}
}

/// One small file in the app's support directory.
///
/// Not the documents directory, where the photographs are: this is not the
/// person's data, it is a credential, and the support directory is the one iOS
/// excludes from the user's own file browsing.
class FileSessionVault implements SessionVault {
  FileSessionVault({this.fileName = 'cairn_session.json'});

  final String fileName;
  File? _file;

  Future<File> _resolve() async => _file ??= File(
    '${(await getApplicationSupportDirectory()).path}/$fileName',
  );

  // Nothing below lets anything out. Resolving the directory is a platform
  // channel call and can fail on its own, a half-written file decodes to a
  // FormatException, and this is read on the boot path: an absent vault is a
  // first launch, which the phone already knows how to be.
  @override
  Future<StoredSession?> read() async {
    try {
      final file = await _resolve();
      if (!file.existsSync()) return null;
      final body = jsonDecode(await file.readAsString());
      if (body is! Map) return null;
      final token = body['refresh_token'];
      final id = body['user_id'];
      if (token is! String || token.isEmpty) return null;
      if (id is! String || id.isEmpty) return null;
      return StoredSession(userId: id, refreshToken: token);
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> write(StoredSession? session) async {
    // A phone that cannot write here still works for this launch; it just
    // mints a new account on the next one. Failing the sign-in outright would
    // be worse.
    File? temporary;
    try {
      final file = await _resolve();
      if (session == null) {
        if (file.existsSync()) {
          await file.delete();
        }
        return;
      }
      await file.parent.create(recursive: true);
      temporary = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.tmp',
      );
      await temporary.writeAsString(
        jsonEncode({
          'user_id': session.userId,
          'refresh_token': session.refreshToken,
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } on Exception {
      try {
        if (temporary?.existsSync() ?? false) await temporary!.delete();
      } on Exception {
        // The credential target was never replaced; a stale temp file is not
        // allowed to turn that recoverable outcome into a launch failure.
      }
      return;
    }
  }
}

/// A session from GoTrue, held for as long as it is good for.
///
/// [current] is the whole interface and it is deliberately cheap to call: the
/// sync asks on every reconcile, which is every two minutes and every local
/// write. It answers from memory unless the token is close to expiring.
class GotrueSessions implements SessionSource {
  GotrueSessions({
    required this.config,
    this.vault = const NoVault(),
    http.Client? client,
    this.now = DateTime.now,
    this.timeout = const Duration(seconds: 10),
    this.mintAnonymously = true,
  }) : _client = client ?? http.Client();

  final SharedFactsConfig config;
  final SessionVault vault;
  final http.Client _client;
  final DateTime Function() now;
  final Duration timeout;

  /// Whether an absent account may be created. False is "use the account you
  /// have or none at all", which is what a build that wants to observe the
  /// dormant path asks for.
  final bool mintAnonymously;

  /// A token is refreshed this far before it actually expires, so a request
  /// that takes a moment does not set out with a token that dies in flight.
  static const _margin = Duration(minutes: 2);

  SharedFactsSession? _held;
  DateTime? _heldUntil;
  Future<SharedFactsSession?>? _inFlight;

  @override
  Future<SharedFactsSession?> current() {
    if (!config.isConfigured) return Future.value(null);
    final held = _held;
    final until = _heldUntil;
    if (held != null &&
        until != null &&
        now().isBefore(until.subtract(_margin))) {
      return Future.value(held);
    }
    // Serialized: the sync collapses its own calls, but a first launch can
    // still ask twice at once, and two anonymous sign-ups is two accounts.
    return _inFlight ??= _acquire().whenComplete(() => _inFlight = null);
  }

  Future<SharedFactsSession?> _acquire() async {
    final saved = await vault.read();
    if (saved != null) {
      final refreshed = await _post('/auth/v1/token?grant_type=refresh_token', {
        'refresh_token': saved.refreshToken,
      });
      if (refreshed == _unreachable) return null;
      if (refreshed != null) return _keep(refreshed);
      // The server answered and said no: the token was revoked, or the
      // account was deleted. Drop it rather than retrying it forever.
      await vault.write(null);
    }
    if (!mintAnonymously) return null;
    final minted = await _post('/auth/v1/signup', const {});
    if (minted == null || minted == _unreachable) return null;
    return _keep(minted);
  }

  Future<SharedFactsSession?> _keep(Map<String, dynamic> body) async {
    final token = body['access_token'];
    final id = (body['user'] as Map?)?['id'];
    if (token is! String || id is! String) return null;
    final seconds = (body['expires_in'] as num?)?.toInt() ?? 3600;
    final refresh = body['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) {
      // A rotated refresh token becomes the only way back to this account.
      // Persist it before exposing the access token, so a process exit after
      // [current] completes cannot leave the vault naming the spent token.
      await vault.write(StoredSession(userId: id, refreshToken: refresh));
    }
    _held = SharedFactsSession(accessToken: token, userId: MemberId(id));
    _heldUntil = now().add(Duration(seconds: seconds));
    return _held;
  }

  /// The sentinel for "could not reach the server", which is a different
  /// answer from "the server said no" — the first must not spend the saved
  /// refresh token, and the second must.
  static const _unreachable = <String, dynamic>{'__unreachable': true};

  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    // Nothing escapes this method, on purpose. The contract [SessionSource]
    // documents is "answer null rather than throw when the phone cannot reach
    // the server", and `main` signs in on the boot path, so an exception here
    // is an app that never renders a frame. A timeout, a dead socket and a
    // refused TLS handshake are all the same answer, and so is the captive
    // portal that answers 200 with a page of HTML: `jsonDecode` throws a
    // FormatException on it, which is *still* "the server was not reached" and
    // must not spend the saved refresh token. Hence one net around the send
    // and the decode together, rather than one more exception type each time
    // a network turns out to have another way of lying.
    try {
      final response = await _client
          .post(
            Uri.parse('${config.url}$path'),
            headers: {
              'apikey': config.anonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (response.statusCode >= 500) return _unreachable;
      if (response.statusCode >= 400) {
        // Only GoTrue's explicit dead-refresh-token verdict spends the saved
        // account. A gateway 401, rate limit, bad request unrelated to the
        // token, or any other 4xx is an unreachable auth service, not proof
        // that this person no longer owns the stored account.
        return _isDeadRefreshToken(response) ? null : _unreachable;
      }
      final decoded = jsonDecode(response.body);
      // A 2xx whose body decodes to something other than a map is a proxy
      // or portal answering in the server's place, not a verdict on the
      // token — the same lie the FormatException net below catches.
      return decoded is Map<String, dynamic> ? decoded : _unreachable;
    } on Exception {
      return _unreachable;
    }
  }

  static bool _isDeadRefreshToken(http.Response response) {
    if (response.statusCode != 400) return false;
    final lower = response.body.toLowerCase();
    return const {
      'invalid_grant',
      'refresh_token_not_found',
      'refresh_token_already_used',
    }.any(lower.contains);
  }
}
