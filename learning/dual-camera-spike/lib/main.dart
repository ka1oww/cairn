import 'package:flutter/material.dart';

import 'moment/moment_camera_screen.dart';
import 'multicam/multicam_capability.dart';

void main() {
  runApp(const DualCameraSpikeApp());
}

class DualCameraSpikeApp extends StatelessWidget {
  const DualCameraSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dual camera spike',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

/// This is a throwaway spike, not a prototype of Cairn's real camera screen.
/// Its only job is to answer one question with running code: does Cairn's
/// "back camera + small front inset" moment need true hardware-simultaneous
/// dual capture, or does a fast back-then-front sequence deliver the same
/// effect? Read `README.md` for the full findings; this screen just gets you
/// to the code that produced them.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dual camera spike')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This build captures back-then-front, in fast sequence, and '
              'times the gap between the two shots. See README.md for why '
              'that -- not true simultaneous hardware capture -- is what '
              'this spike recommends, and for what BeReal itself appears to '
              'actually do.',
            ),
            const SizedBox(height: 16),
            FutureBuilder<MultiCamSupport>(
              future: MultiCamCapability.probe(),
              builder: (context, snapshot) {
                final text = switch (snapshot.data) {
                  MultiCamSupport.supported =>
                    'AVCaptureMultiCamSession.isMultiCamSupported: true on '
                        'this build -- but that flag alone is not proof a '
                        'live session works (it reads true on Simulator '
                        'too). See README.',
                  MultiCamSupport.unsupported =>
                    'This device does not support true AVCaptureMultiCamSession capture.',
                  MultiCamSupport.notProbedOnThisPlatform || null =>
                    'True-simultaneous-capture probe: not wired up for this '
                        'platform in this spike (iOS only -- see README).',
                };
                return Text(text, style: Theme.of(context).textTheme.bodySmall);
              },
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.camera_alt),
              label: const Text('Open the moment camera'),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MomentCameraScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
