// One trivial smoke test, kept mainly to show that a ProviderScope-wrapped,
// Drift-backed widget tree is testable at all with the ordinary Flutter
// testing tools — no special harness required. This is not meant as
// coverage; see the README for what testing this demo skips.
//
// It only asserts on content that renders on the very first frame,
// deliberately not on anything that depends on the Drift database resolving
// (e.g. the seeded stop names): opening a native SQLite connection inside
// `flutter test`'s host process isn't guaranteed to finish within a fixed
// number of pumps the way it does in a real app run, so asserting on it here
// would make this test flaky for reasons that have nothing to do with the
// app being wrong.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:riverpod_drift_demo/main.dart';

void main() {
  testWidgets('Today tab renders its title and add-photo button', (
    tester,
  ) async {
    // TripApp assumes a ProviderScope ancestor (main() supplies one at the
    // real app's root) — tests have to provide their own, same as any other
    // InheritedWidget dependency a widget under test relies on.
    await tester.pumpWidget(const ProviderScope(child: TripApp()));
    await tester.pump();

    expect(find.text('Today — Day 1'), findsOneWidget);
    expect(find.text('Simulate a photo arriving'), findsOneWidget);

    // The trip-tip card (see TripTipCard in today_screen.dart) starts a
    // 2-second delayed Future as soon as it builds. Flutter's test harness
    // fails the test if a Timer is still pending when it tears down the
    // widget tree, so this pump has to outlast that delay even though
    // nothing here asserts on the tip text itself.
    await tester.pump(const Duration(seconds: 3));
  });
}
