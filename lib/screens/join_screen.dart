// SCREENS band (docs/architecture.md): knows app state and nothing below it.
//
// The second door (design surfaces 6a and 6d): "What did they tell you?", a
// box for three words, and one action. Any order, any spelling that is close
// — the forgiveness is the domain's, and this screen only asks.
//
// The answer is always written out, including the honest one: a code that
// reads perfectly but belongs to a trip on somebody else's phone cannot be
// redeemed yet, and this says so rather than spinning or pretending. See
// app_state/join_flow.dart, which is where that state and its Phase 2 seam
// are explained.
//
// Deliberately absent: the link half of joining ("Links skip this screen
// entirely" — no deep link is registered, so there is nothing to skip yet),
// and any preview of the trip behind the code, which this phone cannot see.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/join_flow.dart';

class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key});

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<JoinScreen> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(joinFlowProvider).typed);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final answer = ref.watch(joinFlowProvider).answer;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'What did they tell you?',
                key: const Key('join-headline'),
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('join-input'),
                controller: _controller,
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
                decoration: const InputDecoration(
                  hintText: 'otter maple 42',
                  border: OutlineInputBorder(),
                ),
                onChanged: (text) =>
                    ref.read(joinFlowProvider.notifier).type(text),
                onSubmitted: (_) =>
                    ref.read(joinFlowProvider.notifier).submit(),
              ),
              const SizedBox(height: 8),
              Text(
                'Any order, any spelling that is close.',
                key: const Key('join-hint'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (answer != null) ...[
                const SizedBox(height: 16),
                Text(
                  answer.line,
                  key: const Key('join-answer'),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('join-button'),
                onPressed: () => ref.read(joinFlowProvider.notifier).submit(),
                child: const Text('Join the trip'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
