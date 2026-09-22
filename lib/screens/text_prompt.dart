// SCREENS band (docs/architecture.md): knows app state and nothing below it.
//
// The one-field text prompt both add-area doors share: the confirm screen's
// "+ Add an area" (and its rename prompts) and the day page's. One dialog,
// one behaviour — the plan's own areas as one-tap answers above the field,
// the field itself for somewhere the plan never names — because a second
// copy of this dialog is the thing to refuse in review. Keys are passed in
// by each caller so each door's tests can find it; the dialog itself draws
// exactly the same either way.
import 'package:flutter/material.dart';

/// Shows the shared text prompt and answers with what the person submitted,
/// or null when they cancelled. Empty and whitespace-only submissions are
/// the caller's to judge, not this dialog's.
///
/// [candidates] are one-tap answers drawn above the field. Only an
/// add-area fallback passes any; every other prompt keeps the blank field it
/// has always had.
Future<String?> askForText(
  BuildContext context, {
  required String title,
  required String hint,
  required String action,
  required Key fieldKey,
  required Key saveKey,
  String initial = '',
  List<String> candidates = const [],
  String candidateKeyPrefix = 'area-choice',
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _TextPrompt(
      title: title,
      hint: hint,
      action: action,
      fieldKey: fieldKey,
      saveKey: saveKey,
      initial: initial,
      candidates: candidates,
      candidateKeyPrefix: candidateKeyPrefix,
    ),
  );
}

/// Stateful because the dialog's exit animation rebuilds this after the
/// pop, and a controller disposed at the pop is a controller used after
/// disposal.
class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.hint,
    required this.action,
    required this.fieldKey,
    required this.saveKey,
    required this.initial,
    this.candidates = const [],
    this.candidateKeyPrefix = 'area-choice',
  });

  final String title;
  final String hint;
  final String action;
  final Key fieldKey;
  final Key saveKey;
  final String initial;
  final List<String> candidates;
  final String candidateKeyPrefix;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Scrollable because the candidate list is the plan's own areas and a
      // long plan names many: without it the field below them is clipped
      // away, and that field is the only way to name somewhere the plan
      // never does.
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The plan's own areas, nearest first: tapping one answers with
          // it directly, which is the whole fallback. The field below stays
          // for somewhere the plan never names.
          for (final candidate in widget.candidates)
            TextButton(
              key: Key('${widget.candidateKeyPrefix}-$candidate'),
              onPressed: () => Navigator.of(context).pop(candidate),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(candidate),
              ),
            ),
          TextField(
            key: widget.fieldKey,
            controller: _controller,
            autofocus: widget.candidates.isEmpty,
            decoration: InputDecoration(hintText: widget.hint),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: widget.saveKey,
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.action),
        ),
      ],
    );
  }
}
