import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../multicam/multicam_capability.dart';
import '../widgets/dual_camera_frame.dart';
import 'capture_sequencer.dart';
import 'moment_review_screen.dart';

enum _CapturePhase { live, capturingBack, switchingLens, capturingFront, error }

/// The live camera screen: a full-bleed back-camera preview, one shutter
/// button, and a corner placeholder where the front shot will land once it
/// exists.
///
/// There is deliberately no live front-camera preview here. The stock
/// `camera` plugin only ever supports one active `CameraController` at a
/// time -- opening a second while the first is still open breaks the first
/// (github.com/flutter/flutter/issues/119858, closed as a duplicate/not
/// planned by the Flutter team). This screen never fights that: it fully
/// disposes the back controller before creating the front one, which is
/// exactly the shape the framework supports, and is also exactly the
/// back-then-front *sequence* this spike is testing rather than working
/// around.
class MomentCameraScreen extends StatefulWidget {
  const MomentCameraScreen({super.key});

  @override
  State<MomentCameraScreen> createState() => _MomentCameraScreenState();
}

class _MomentCameraScreenState extends State<MomentCameraScreen> {
  late Future<_CameraSetup> _setup;
  late Future<MultiCamSupport> _multiCamProbe;
  CameraController? _controller;
  _CapturePhase _phase = _CapturePhase.live;
  String? _error;

  @override
  void initState() {
    super.initState();
    _multiCamProbe = MultiCamCapability.probe();
    _setup = _prepare();
  }

  Future<_CameraSetup> _prepare() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No cameras were reported on this device/browser.');
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    // On hardware with a genuine front+back pair (any phone), `back` and
    // `front` are different CameraDescriptions. On a machine with exactly
    // one camera (this spike's own dev machine has one built-in webcam and
    // no second lens for `camera`'s web/desktop backends to enumerate),
    // `identical`ly the same description comes back for both roles. That is
    // this spike's own honesty check, surfaced in the UI rather than hidden:
    // see the banner this triggers below.
    final singleCameraFallback = back.name == front.name;

    final controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false, // stills only -- no reason to ask for microphone access.
    );
    await controller.initialize();
    return _CameraSetup(
      cameras: cameras,
      back: back,
      front: front,
      singleCameraFallback: singleCameraFallback,
      controller: controller,
    );
  }

  Future<void> _capture(_CameraSetup setup) async {
    setState(() => _phase = _CapturePhase.capturingBack);
    final sequencer = CaptureSequencer(
      takeBackPhoto: () async {
        final file = await setup.controller.takePicture();
        return file.readAsBytes();
      },
      switchToFrontLens: () async {
        setState(() => _phase = _CapturePhase.switchingLens);
        // Fully dispose the back controller before opening the front one.
        // Holding both open at once is the unsupported shape; this is the
        // supported one.
        await setup.controller.dispose();
        final nextController = CameraController(
          setup.front,
          ResolutionPreset.medium,
          enableAudio: false,
        );
        await nextController.initialize();
        _controller = nextController;
        setState(() => _phase = _CapturePhase.capturingFront);
      },
      takeFrontPhoto: () async {
        final file = await _controller!.takePicture();
        return file.readAsBytes();
      },
    );

    try {
      final capture = await sequencer.capture();
      await _controller?.dispose();
      _controller = null;
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MomentReviewScreen(capture: capture)),
      );
      if (!mounted) return;
      setState(() {
        _phase = _CapturePhase.live;
        _setup = _prepare();
      });
    } catch (e) {
      // Whichever controller was mid-flight when this failed may already be
      // disposed (switchToFrontLens disposes the back controller before it
      // can throw while creating the front one) or left in an unknown
      // state -- rather than risk reusing it, tear down and re-prepare from
      // scratch so a retry gets a controller that's actually usable.
      await setup.controller.dispose();
      await _controller?.dispose();
      _controller = null;
      if (!mounted) return;
      setState(() {
        _phase = _CapturePhase.error;
        _error = '$e';
        _setup = _prepare();
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: FutureBuilder<_CameraSetup>(
          future: _setup,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.white),
              );
            }
            if (snapshot.hasError) {
              return _ErrorPane(message: '${snapshot.error}');
            }
            final setup = snapshot.data!;
            _controller ??= setup.controller;
            return Column(
              children: [
                _DiagnosticStrip(setup: setup, probe: _multiCamProbe),
                Expanded(
                  child: DualCameraFrame(
                    subject: (_phase == _CapturePhase.capturingFront ||
                            _phase == _CapturePhase.switchingLens) &&
                            _controller != null &&
                            _controller!.value.isInitialized
                        ? CameraPreview(_controller!)
                        : (setup.controller.value.isInitialized
                            ? CameraPreview(setup.controller)
                            : const ColoredBox(color: Colors.black)),
                    inset: _phase == _CapturePhase.live
                        ? const _PendingFrontInset()
                        : null,
                  ),
                ),
                _ShutterBar(
                  phase: _phase,
                  error: _error,
                  onShutter: () => _capture(setup),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CameraSetup {
  _CameraSetup({
    required this.cameras,
    required this.back,
    required this.front,
    required this.singleCameraFallback,
    required this.controller,
  });

  final List<CameraDescription> cameras;
  final CameraDescription back;
  final CameraDescription front;
  final bool singleCameraFallback;
  final CameraController controller;
}

class _PendingFrontInset extends StatelessWidget {
  const _PendingFrontInset();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Icon(Icons.face_retouching_off, color: Colors.white70, size: 28),
      ),
    );
  }
}

class _DiagnosticStrip extends StatelessWidget {
  const _DiagnosticStrip({required this.setup, required this.probe});

  final _CameraSetup setup;
  final Future<MultiCamSupport> probe;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${setup.cameras.length} camera(s) enumerated on this build.'
            '${setup.singleCameraFallback ? ' Only one lens found -- reusing it for both shots below.' : ''}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          FutureBuilder<MultiCamSupport>(
            future: probe,
            builder: (context, snapshot) {
              final label = switch (snapshot.data) {
                MultiCamSupport.supported =>
                  'isMultiCamSupported: true. This is a device-class flag, '
                      'not proof a live session works here -- it reads true '
                      'even on Simulator (see README). Only a real capture '
                      'attempt on a physical device is conclusive.',
                MultiCamSupport.unsupported =>
                  'isMultiCamSupported: false. This device/OS cannot run '
                      'true simultaneous capture.',
                MultiCamSupport.notProbedOnThisPlatform || null =>
                  'True simultaneous capture: not probed on this platform (see README).',
              };
              return Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ShutterBar extends StatelessWidget {
  const _ShutterBar({required this.phase, required this.error, required this.onShutter});

  final _CapturePhase phase;
  final String? error;
  final VoidCallback onShutter;

  @override
  Widget build(BuildContext context) {
    final label = switch (phase) {
      _CapturePhase.live => 'Tap to take the moment',
      _CapturePhase.capturingBack => 'Taking the back shot…',
      _CapturePhase.switchingLens => 'Switching to the front camera…',
      _CapturePhase.capturingFront => 'Taking the front shot…',
      _CapturePhase.error => 'Something went wrong -- see below',
    };
    final busy = phase != _CapturePhase.live && phase != _CapturePhase.error;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (phase == _CapturePhase.error && error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          Text(label, style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 12),
          IconButton(
            iconSize: 64,
            color: Colors.white,
            onPressed: busy ? null : onShutter,
            icon: Icon(busy ? Icons.hourglass_top : Icons.camera),
          ),
        ],
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Could not start the camera:\n$message',
          style: const TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
