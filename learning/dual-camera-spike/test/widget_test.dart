// A basic smoke test for the home screen. It deliberately never opens the
// camera screen -- `flutter test` runs on a host with no camera plugin
// implementation wired up for photo capture, so that part of this spike can
// only be exercised by actually running the app (see README.md).

import 'package:flutter_test/flutter_test.dart';

import 'package:dual_camera_spike/main.dart';

void main() {
  testWidgets('home screen explains the spike and offers to open the camera', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DualCameraSpikeApp());
    await tester.pumpAndSettle();

    expect(find.text('Dual camera spike'), findsWidgets);
    expect(find.text('Open the moment camera'), findsOneWidget);

    // On this test host (not iOS, not web) the multicam probe should resolve
    // to "not probed on this platform" rather than hang or throw.
    expect(
      find.textContaining('not wired up for this platform'),
      findsOneWidget,
    );
  });
}
