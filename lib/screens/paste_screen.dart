// SCREENS band (docs/architecture.md): knows app state and nothing below it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/paste_flow.dart';
import 'join_screen.dart';

/// The paste box. Nothing clever, per the flow's design: a text area and a
/// parse action. Everything interesting happens on the screen after it.
class PasteScreen extends ConsumerStatefulWidget {
  const PasteScreen({super.key, this.initialText = ''});

  /// Refilled when the person comes back via "Paste something else" — the
  /// paste is kept, never thrown away.
  final String initialText;

  @override
  ConsumerState<PasteScreen> createState() => _PasteScreenState();
}

class _PasteScreenState extends ConsumerState<PasteScreen> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _read() {
    ref.read(pasteFlowProvider.notifier).parse(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Paste the plan.', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(
                'Out of Notes, a chat, an email — as it is. It is read right '
                'here on the phone; the plan never leaves it.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TextField(
                  key: const Key('paste-input'),
                  controller: _controller,
                  maxLines: null,
                  minLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    hintText: 'Day 1 - Tokyo\n- Senso-ji\n- 10:12 train to Kyoto…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('read-button'),
                onPressed: _read,
                child: const Text('Read it'),
              ),
              // The second of design surface 6a's two doors. Most people
              // arrive here holding a code somebody told them rather than a
              // plan to paste, so the other door is on this screen and not
              // buried — bare, until the first-launch screen itself exists.
              TextButton(
                key: const Key('join-door'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => const JoinScreen(),
                  ),
                ),
                child: const Text('I have an invite'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
