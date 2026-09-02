import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/camera_source.dart';
import 'package:cairn/app_state/stand_in_frame.dart';

const _backCamera = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

const _frontCamera = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

class FakeCameraEdge implements CameraCaptureEdge {
  FakeCameraEdge(
    this.directory, {
    this.cameras = const [_backCamera, _frontCamera],
  });

  final Directory directory;
  final List<CameraDescription> cameras;
  final List<CameraLensDirection> requestedLenses = [];
  int captureCount = 0;
  int? failOnCapture;

  @override
  Future<List<CameraDescription>> listCameras() async => cameras;

  @override
  Future<String> capture(CameraDescription camera) async {
    requestedLenses.add(camera.lensDirection);
    captureCount += 1;
    if (captureCount == failOnCapture) {
      throw CameraException('capture', 'permission denied');
    }
    final path = '${directory.path}/temporary-$captureCount.png';
    File(path).writeAsBytesSync(standInFrameBytes(captureCount));
    return path;
  }
}

void main() {
  late Directory temporary;
  late Directory frames;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('cairn_camera_edge');
    frames = Directory.systemTemp.createTempSync('cairn_camera_frames');
  });

  tearDown(() {
    temporary.deleteSync(recursive: true);
    frames.deleteSync(recursive: true);
  });

  BackCameraSource source(FakeCameraEdge edge) =>
      BackCameraSource(camera: edge, directoryProvider: () async => frames);

  test('takes and identifies back then front sequentially', () async {
    final edge = FakeCameraEdge(temporary);

    final frame = await source(edge).takeOne();

    expect(edge.requestedLenses, [
      CameraLensDirection.back,
      CameraLensDirection.front,
    ]);
    expect(frame.path, frame.backPath);
    expect(
      frame.backPath,
      endsWith('/back-${frame.takenAtUtc.microsecondsSinceEpoch}.jpg'),
    );
    expect(frame.frontPath, isNotNull);
    expect(frame.frontPath, contains('/front-'));
    expect(frame.hasFrontFrame, isTrue);
    expect(File(frame.backPath).readAsBytesSync(), standInFrameBytes(1));
    expect(File(frame.frontPath!).readAsBytesSync(), standInFrameBytes(2));

    await source(edge).discard(frame.backPath);
    await source(edge).discard(frame.frontPath!);
  });

  test('refuses before capturing when there is no front camera', () async {
    final edge = FakeCameraEdge(temporary, cameras: const [_backCamera]);

    await expectLater(
      source(edge).takeOne(),
      throwsA(
        isA<CameraRefused>().having(
          (e) => e.reason,
          'reason',
          'This device has no front camera.',
        ),
      ),
    );
    expect(edge.requestedLenses, isEmpty);
    expect(frames.listSync(), isEmpty);
  });

  test('discards the back copy when the front capture fails', () async {
    final edge = FakeCameraEdge(temporary)..failOnCapture = 2;

    await expectLater(
      source(edge).takeOne(),
      throwsA(
        isA<CameraRefused>().having(
          (e) => e.reason,
          'reason',
          'permission denied',
        ),
      ),
    );

    expect(edge.requestedLenses, [
      CameraLensDirection.back,
      CameraLensDirection.front,
    ]);
    expect(frames.listSync(), isEmpty);
  });
}
