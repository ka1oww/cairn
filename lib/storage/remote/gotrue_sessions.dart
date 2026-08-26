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
// [SessionVault] and the same account comes back.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cairn_model/cairn_model.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'shared_facts.dart';

/// Where the refresh token lives between launches.
///
/// An interface because a test must not touch the device's filesystem, and
/// because real file I/O inside `testWidgets` hangs silently under the faked
/// clock (AGENTS.md).
abstract interface class SessionVault {
  Future<String?> read();
  Future<void> write(String? refreshToken);
}

/// Keeps nothing. A build with no backend, and every test that does not care.
class NoVault implements SessionVault {
  const NoVault();

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String? refreshToken) async {}
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

  @override
  Future<String?> read() async {
    try {
      final file = await _resolve();
      if (!file.existsSync()) return null;
      final body = jsonDecode(await file.readAsString());
      final token = body is Map ? body['refresh_token'] : null;
      return token is String && token.isNotEmpty ? token : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      // A truncated write from a launch that was killed mid-save. Minting a
      // fresh account is worse than nothing here, but it is the only thing
      // left to do, and it is what an absent file does too.
      return null;
    }
  }

  @override
  Future<void> write(String? refreshToken) async {
    final file = await _resolve();
    try {
      if (refreshToken == null) {
        if (file.existsSync()) {
          await file.delete();
        }
        return;
      }
      await file.writeAsString(jsonEncode({'refresh_token': refreshToken}));
    } on FileSystemException {
      // A phone that cannot write here still works for this launch; it just
      // mints a new account on the next one. Failing the sign-in outright
      // would be worse.
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
        'refresh_token': saved,
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

  SharedFactsSession? _keep(Map<String, dynamic> body) {
    final token = body['access_token'];
    final id = (body['user'] as Map?)?['id'];
    if (token is! String || id is! String) return null;
    final seconds = (body['expires_in'] as num?)?.toInt() ?? 3600;
    _held = SharedFactsSession(accessToken: token, userId: MemberId(id));
    _heldUntil = now().add(Duration(seconds: seconds));
    final refresh = body['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) {
      unawaited(vault.write(refresh));
    }
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
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('${config.url}$path'),
            headers: {
              'apikey': config.anonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      return _unreachable;
    } on SocketException {
      return _unreachable;
    } on http.ClientException {
      return _unreachable;
    }
    if (response.statusCode >= 500) return _unreachable;
    if (response.statusCode >= 400) return null;
    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}
