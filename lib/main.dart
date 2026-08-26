import 'package:flutter/widgets.dart';

import 'bootstrap.dart';

/// Works out who this phone is, then builds the app.
///
/// The order matters and is the one thing this file says. The account's id is
/// this phone's member id: it is what a trip is started under, what a photo is
/// credited to, and what the roster the server hands back names. Building the
/// app first and letting the id arrive afterwards would credit whatever
/// happened in between to the local stand-in, and those rows would then belong
/// to somebody the trip does not hold.
///
/// What it does *not* do is wait on a network to find that out. A phone that
/// has signed in before reads its id out of the vault, which is a local file;
/// only a first-ever launch has an account to mint, and even that one has a
/// short budget (`resolveMemberId`) rather than the full request timeout.
///
/// A phone that cannot reach the server, on a launch that has nothing stored,
/// gets null here and runs entirely locally under that stand-in, which is what
/// being on a plane looks like.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final vault = deviceVault();
  final sessions = deviceSessions(vault: vault);
  final memberId = await resolveMemberId(sessions, vault);
  runApp(bootstrapApp(sessions: sessions, memberId: memberId));
}
