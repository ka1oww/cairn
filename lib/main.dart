import 'package:flutter/widgets.dart';

import 'bootstrap.dart';

/// Signs in first, then builds the app.
///
/// The order matters and is the one thing this file says. The account's id is
/// this phone's member id: it is what a trip is started under, what a photo is
/// credited to, and what the roster the server hands back names. Building the
/// app first and letting the id arrive afterwards would credit whatever
/// happened in between to the local stand-in, and those rows would then belong
/// to somebody the trip does not hold.
///
/// A phone that cannot reach the server gets null here and runs entirely
/// locally under that stand-in, which is what being on a plane looks like.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sessions = deviceSessions();
  final session = await signIn(sessions);
  runApp(bootstrapApp(sessions: sessions, memberId: session?.userId.value));
}
