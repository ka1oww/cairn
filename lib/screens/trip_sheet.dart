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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/paste_flow.dart';
import '../app_state/trip_settings.dart';

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

            const SizedBox(height: 20),
            _Code(view: view),

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

            const Divider(height: 32),
            // **Temporary**, and the last of what the overflow menu held: the
            // one route back to the paste box. It goes when a trip can be
            // re-read without being thrown away.
            TextButton(
              key: const Key('start-over'),
              onPressed: () {
                Navigator.of(context).pop();
                ref.read(pasteFlowProvider.notifier).pasteAnother();
              },
              child: const Text('Paste a different plan'),
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
        if (code == null)
          Text(
            'No code to say. Make new words and anyone you tell them to can '
            'join.',
            key: const Key('trip-code-none'),
            style: theme.textTheme.bodyMedium,
          )
        else ...[
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
