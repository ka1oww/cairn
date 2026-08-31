// SCREENS band (docs/architecture.md): knows app state and nothing below it.
// No repository, no store, no SQL — every line here comes from
// app_state/trip_settings.dart.
//
// The trip's own surface, which design surfaces 6e and 15c hang off the
// Trail's title and never off a fourth tab: faces first (who is on the trip
// is the state people actually check), then the code, then the destructive
// things at the bottom, guarded by a confirmation rather than by hiding.
//
// **Structure and states only.** The house treatment — paper, ink, coral, the
// stacked serif code on its card — arrives with design round ten. This uses
// the theme's own colours, which is why nothing here names one.
//
// Deliberately absent, and each for a reason rather than for time: no "Share"
// or "Send the link instead" (no link exists to send — no deep link is
// registered, and a button that copies nothing is a lie), no "Leave this
// trip" (a party of one leaving would leave the trip with nobody on it, and
// nothing propagates a departure anywhere yet), no removing anyone (there is
// nobody else on this phone's roster to remove), and no badge or title
// anywhere: "started it" is a fact beside a name, never a rank.
//
// Absent for a different reason: **"Paste a different plan" is gone.** It was
// the only way to change a running trip's plan and it did so by throwing the
// trip away. Design round 4's screen 3 replaces it with the two entries above
// the deletion — edit the plan, or re-paste its text — and neither destroys
// anything. Deleting stays, as a choice rather than as the only path to a
// change. Re-introducing a destructive re-paste is the thing to refuse in
// review.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/device_prefs.dart';
import '../app_state/paste_flow.dart';
import '../app_state/trip_providers.dart';
import '../app_state/trip_settings.dart';
import '../logic/maps_handoff.dart';

/// Slides the trip's sheet over whatever is behind it.
Future<void> showTripSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => const TripSheet(),
);

class TripSheet extends ConsumerWidget {
  const TripSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(tripSettingsProvider);
    return SafeArea(
      child: switch (settings) {
        AsyncData(value: final TripSettingsView view) => _Sheet(view: view),
        AsyncData() => const SizedBox.shrink(),
        AsyncError(:final error) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Failed to read: $error'),
        ),
        _ => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      },
    );
  }
}

class _Sheet extends ConsumerWidget {
  const _Sheet({required this.view});

  final TripSettingsView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        view.headline,
                        key: const Key('trip-name'),
                        style: theme.textTheme.headlineSmall,
                      ),
                      if (view.span != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          view.span!,
                          key: const Key('trip-span'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (view.canRename)
                  TextButton(
                    key: const Key('trip-rename'),
                    onPressed: () => _rename(context, ref),
                    child: const Text('Rename'),
                  ),
              ],
            ),
            // Where the trip's ending stands, said once and said plainly.
            // It sits under the name because it is a fact about the trip
            // rather than about any control below it.
            if (view.ending != null) ...[
              const SizedBox(height: 10),
              Text(
                view.ending!,
                key: const Key('trip-ending'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            const SizedBox(height: 16),

            // Faces first. There are no faces yet — no photo of anybody is
            // attached to a member — so this is the row without its portrait,
            // not a placeholder circle standing in for one.
            for (final (index, person) in view.people.indexed)
              Padding(
                key: Key('trip-person-$index'),
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        person.name,
                        key: Key('trip-person-$index-name'),
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    if (person.note != null)
                      Text(
                        person.note!,
                        key: Key('trip-person-$index-note'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            if (view.aloneNote != null) ...[
              const SizedBox(height: 6),
              Text(
                view.aloneNote!,
                key: const Key('trip-alone'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            // Where the plan itself stands, right under who can see it,
            // because it is the same question asked of the plan instead of
            // the people. Absent — not blank, and never a spinner — while
            // nothing has said, which is the only honest thing to draw when
            // this phone does not know. The sentence is `trip_settings.dart`'s
            // and this screen only places it.
            if (view.sharing case final PlanSharing sharing) ...[
              const SizedBox(height: 6),
              Text(
                sharing.line,
                key: const Key('trip-sharing'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            const SizedBox(height: 20),
            _Code(view: view),

            // Screen 3's two entries. They exist only over an accepted trip:
            // with no plan saved there is nothing to edit and nothing to say
            // back, and the paste box is already the whole screen.
            //
            // They stay on a *closed* trip, and that is deliberate: the paste
            // box behind them is also the join door, and shutting it would
            // lock somebody out of ever joining another trip because their
            // last one ended. What an archived trip refuses is the write at
            // the end of the route — `PasteFlow.accept` returns without
            // saving and the read-back says so in words
            // (`docs/decisions/2026-08-26-the-ending.md`).
            if (ref.watch(savedItineraryProvider).value != null) ...[
              const Divider(height: 32),
              _PlanEntry(
                buttonKey: const Key('trip-edit-plan'),
                label: 'Edit the whole plan',
                caption:
                    'Opens the editor over the trip as it stands. Nothing '
                    'changes until you save, and days you leave alone keep '
                    'their photos.',
                onPressed: () {
                  Navigator.of(context).pop();
                  ref.read(pasteFlowProvider.notifier).editLivePlan();
                },
              ),
              const SizedBox(height: 8),
              _PlanEntry(
                buttonKey: const Key('trip-repaste'),
                label: 'Re-paste the plan text',
                caption:
                    'Reopens the paste box holding this plan as text. Edit '
                    'it, read it again, and the change is merged in — nothing '
                    'is thrown away.',
                onPressed: () {
                  Navigator.of(context).pop();
                  ref.read(pasteFlowProvider.notifier).editLivePlan();
                  ref.read(pasteFlowProvider.notifier).repasteCurrentPlan();
                },
              ),
            ],
            const Divider(height: 32),
            const _MapsAppEntry(),

            const SizedBox(height: 20),
            Text(
              view.deletion.line,
              key: const Key('trip-delete-line'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (view.deletion.allowed)
              TextButton(
                key: const Key('trip-delete'),
                onPressed: () => _delete(context, ref),
                child: const Text('Delete this trip'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(name: view.name),
    );
    if (name == null) return;
    await ref.read(tripActionsProvider).rename(name);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(view.deletion.line),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            key: const Key('trip-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // The sheet closes before the trip goes: the surface it is standing on
    // is about to stop existing.
    if (context.mounted) Navigator.of(context).pop();
    await ref.read(tripActionsProvider).deleteTrip();
  }
}

/// One of screen 3's two plan entries: a quiet full-width button with the
/// sentence that says what it will and will not do underneath it. The
/// sentence is the point — both of these change a trip that is already
/// running, and neither may look like it might destroy it.
class _PlanEntry extends StatelessWidget {
  const _PlanEntry({
    required this.buttonKey,
    required this.label,
    required this.caption,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final String caption;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          key: buttonKey,
          onPressed: onPressed,
          child: Text(label),
        ),
        const SizedBox(height: 4),
        Text(
          caption,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Renaming, which anybody on the trip may do.
///
/// A widget of its own because the field's controller has to outlive the
/// dialog's own exit animation, and a controller disposed the moment the
/// dialog pops is used again on the way out.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.name});

  final String? name;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.name ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    content: TextField(
      key: const Key('trip-name-input'),
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(hintText: 'Japan, June'),
    ),
    actions: [
      TextButton(
        key: const Key('trip-name-save'),
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Save'),
      ),
    ],
  );
}

/// The three words, and what they can do.
class _Code extends ConsumerWidget {
  const _Code({required this.view});

  final TripSettingsView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final code = view.code;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Absent on a closed trip: it tells you to make new words, and on
        // an archive there are none to make. What is left to say there is
        // `codeNote`, below, which says it.
        if (code == null && view.canMintCode)
          Text(
            'No code to say. Make new words and anyone you tell them to can '
            'join.',
            key: const Key('trip-code-none'),
            style: theme.textTheme.bodyMedium,
          )
        else if (code != null) ...[
          // Stacked, as the design draws them: three lines read like
          // something you say, one line reads like a serial number.
          Text(
            code.words.join('\n'),
            key: const Key('trip-code'),
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            code.expiry,
            key: const Key('trip-code-expiry'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          view.codeNote,
          key: const Key('trip-code-note'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // Absent on a closed trip, where new words would open nothing.
        if (view.canMintCode)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('trip-code-new'),
              onPressed: () => ref.read(tripActionsProvider).newCode(),
              child: Text(code == null ? 'Make new words' : 'New words'),
            ),
          ),
      ],
    );
  }
}

/// Which maps app a tapped stop opens in.
///
/// It sits among the plan entries because it is shaped like them, but it is
/// not a fact about the trip: the choice is this phone's alone and never
/// leaves it. All three are keyless https searches, so a phone without the
/// app opens the web page and picking Waze without Waze is safe by
/// construction — there is nothing to detect and nothing to grey out.
class _MapsAppEntry extends ConsumerWidget {
  const _MapsAppEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chosen = ref.watch(mapsAppProvider).value ?? MapsApp.google;
    return ListTile(
      key: const Key('maps-app-entry'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.map_outlined),
      title: const Text('Open places in'),
      trailing: Text(
        '${mapsAppName(chosen)} \u203a',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => _chooseMapsApp(context, ref, chosen),
    );
  }
}

Future<void> _chooseMapsApp(
  BuildContext context,
  WidgetRef ref,
  MapsApp chosen,
) async {
  final theme = Theme.of(context);
  final choice = await showModalBottomSheet<MapsApp>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              'Open places in',
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'serif',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Every tap composes a search for the app you pick.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final app in MapsApp.values)
            ListTile(
              key: Key('maps-app-${app.name}'),
              title: Text(mapsAppName(app)),
              trailing: app == chosen ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(sheet).pop(app),
            ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
  if (choice == null) return;
  await ref.read(devicePrefsRepositoryProvider).writeMapsApp(choice);
}
