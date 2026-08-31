// Temporary evidence-capture test — not part of the suite, deleted after the
// screenshot is taken. Renders the container's skinned tab bar to PNG.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
''';

void main() {
  testWidgets('capture the skinned tab bar', (tester) async {
    final db = AppDatabase(
      DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
    );
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final repaintKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: repaintKey,
        child: bootstrapApp(database: db, today: DateTime.utc(2027, 6, 14)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('paste-input')), tripPaste);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    Future<void> shoot(String name) async {
      final boundary =
          repaintKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory(
        '/var/folders/7_/lggsc0tn1b9cgt1yxvmkhqz00000gn/T/no-mistakes-evidence/01M1BAWF3QZ8SMERD8S0P5TFMP',
      );
      dir.createSync(recursive: true);
      File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    await shoot('tab_bar_today');

    await tester.tap(find.byKey(const Key('tab-pool')));
    await tester.pumpAndSettle();
    await shoot('tab_bar_pool');

    await db.close();
  });
}
