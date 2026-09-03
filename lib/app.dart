// The shell: MaterialApp and the route to the one screen, and the one place
// the app asks the clock again. Sits with the SCREENS band (it knows screens;
// nothing below).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_state/ping_schedule.dart';
import 'screens/root_screen.dart';

/// The app, and the app's second hand.
///
/// **Every verdict the app draws from the clock is recomputed here, together
/// or not at all.** `nowProvider` is live at every ask but pushes nothing
/// (ping_schedule.dart says why), so a provider that asked it once holds that
/// answer until something invalidates it — and the things derived from it are
/// exactly the things a person notices going stale: whether your minute is
/// ahead, open, in its last stretch or gone; whether the trip is underway, in
/// its grace or archived; whether an invite code is still live; and, through
/// `todayProvider`, which day of the trip it even is, which is the only thing
/// that shuts the late door at midnight. Invalidating the clock is what moves
/// all of them, so it is done in one place rather than each screen growing a
/// refresh of its own and drifting from the next — and everything that turns
/// time into a verdict hangs off this one provider so that it can be.
///
/// It is done twice over, because the two ways of losing time are different.
/// A resume is the one instant no tick of the app's own announces — iOS
/// suspends a backgrounded app's timers wholesale, so a phone away in a
/// pocket comes back with a clock the app has not asked in minutes. And a
/// [clockRefresh] cadence covers what a lifecycle event never fires for: the
/// app that was already open and in front of you when your minute arrived.
/// Neither alone is enough — a resume-only answer never notices a ping that
/// arrives while you are looking at the trip, and a cadence alone would leave
/// the first ten seconds after a resume wrong.
class CairnApp extends ConsumerStatefulWidget {
  const CairnApp({super.key});

  @override
  ConsumerState<CairnApp> createState() => _CairnAppState();
}

class _CairnAppState extends ConsumerState<CairnApp>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(clockRefresh, (_) => _askTheClockAgain());
  }

  void _askTheClockAgain() => ref.invalidate(nowProvider);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _askTheClockAgain();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cairn',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6B705C)),
      ),
      home: const RootScreen(),
    );
  }
}
