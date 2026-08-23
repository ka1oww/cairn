// SCREENS band (docs/architecture.md): knows app state and nothing below it.
// No repository, no store, no SQL — that rule is what this file's imports
// are checked against.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/trip_providers.dart';

/// Deliberately minimal: one value read from Drift through a Riverpod
/// provider, and one write back. This screen is the scaffold's proof that
/// the stack is wired end to end, not the first screen of the design —
/// the Trail is the front door, and it is a later slice.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    await ref.read(tripRepositoryProvider).saveTripName(name);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final tripName = ref.watch(tripNameProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Cairn')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Scaffold: a value read from Drift through Riverpod, '
              'and written back.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            switch (tripName) {
              AsyncData(:final value) => Text(
                  value ?? 'No trip yet.',
                  key: const Key('trip-name'),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              AsyncError(:final error) => Text('Failed to read: $error'),
              _ => const Center(child: CircularProgressIndicator()),
            },
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Name the trip',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
