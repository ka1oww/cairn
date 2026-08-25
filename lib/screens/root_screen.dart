// SCREENS band (docs/architecture.md): knows app state and nothing below it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/paste_flow.dart';
import '../app_state/trip_providers.dart';
import 'confirm_screen.dart';
import 'paste_screen.dart';
import 'trip_shell.dart';

/// The launch surface's one decision: a phone with a saved itinerary opens on
/// the trip — its tabs, on Today; a phone without one opens on the paste box.
/// Because this watches a stream, accepting a confirmation lands here on its
/// own — no navigation call carries the person across.
///
/// `repasteRequestedProvider` is the temporary exception, and the only route
/// back to the paste box once a plan is saved. It now hangs off the Trail's
/// title (`trip_shell.dart`), where trip-level actions belong.
class RootScreen extends ConsumerWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedItineraryProvider);
    final repasting = ref.watch(repasteRequestedProvider);
    return switch (saved) {
      AsyncData(value: null) => const _PasteFlow(),
      AsyncData() when repasting => const _PasteFlow(),
      AsyncData() => const TripShell(),
      AsyncError(:final error) => Scaffold(
        body: Center(child: Text('Failed to read: $error')),
      ),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}

/// The paste-and-confirm flow, switched by its own state: the paste box,
/// then the screen after the paste.
class _PasteFlow extends ConsumerWidget {
  const _PasteFlow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pasteFlowProvider);
    return switch (state) {
      PasteEditing(:final initialText) => PasteScreen(initialText: initialText),
      PasteReview(:final review) => ConfirmScreen(review: review),
    };
  }
}
