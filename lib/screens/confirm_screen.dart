// SCREENS band (docs/architecture.md): knows app state and nothing below it.
// No repository, no store, no SQL, no parser — the view models and actions
// all come from app_state/paste_flow.dart.
//
// The structure and states are design round 8's
// (docs/design/2026-08-22-round8-handoff.zip): the confident read collapses
// nothing; when doubt exists, clean days collapse to slim rows and the
// doubted days sit expanded with their cause-specific ask, on the way to the
// accept button. No warning triangles, no red — an unsure parser is the
// design working, and the screen never looks broken.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/paste_flow.dart';

class ConfirmScreen extends ConsumerWidget {
  const ConfirmScreen({super.key, required this.review});

  final ItineraryReview review;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (review.nothingRead) return _NothingReadView(review: review);

    final anyUnsure = review.unsureCount > 0;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _Headline(review: review),
            const SizedBox(height: 14),
            if (review.offerMonthFirstFix) ...[
              _MonthFirstCard(readMonthFirst: review.readMonthFirst),
              const SizedBox(height: 10),
            ],
            for (final day in review.days) ...[
              if (day.needsEye)
                _UnsureDayCard(day: day)
              else if (anyUnsure)
                _SlimDayRow(day: day)
              else
                _FullDayCard(day: day),
              const SizedBox(height: 10),
            ],
            if (review.keptAside.isNotEmpty) ...[
              _KeptAsideTile(lines: review.keptAside),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 6),
            FilledButton(
              key: const Key('accept-button'),
              onPressed: () => ref.read(pasteFlowProvider.notifier).accept(),
              child: const Text('Looks right'),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                key: const Key('back-to-paste'),
                onPressed: () =>
                    ref.read(pasteFlowProvider.notifier).startOver(),
                child: const Text('Back to the paste'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.review});

  final ItineraryReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unsure = review.unsureCount;
    final String title;
    final String subtitle;
    if (unsure == 0) {
      final days = review.days.length;
      final stops = review.totalStops;
      title = '$days ${days == 1 ? 'day' : 'days'}, '
          '$stops ${stops == 1 ? 'stop' : 'stops'}.';
      subtitle = 'Read right here on the phone — your plan never left it.';
    } else {
      final clean = review.cleanCount;
      title = clean == 0
          ? '${unsure == 1 ? 'One day needs' : '$unsure days need'} your eye.'
          : '$clean read clean. '
              '${unsure == 1 ? 'One needs' : '$unsure need'} your eye.';
      subtitle = "It knows which lines it wasn't sure of — that's the point "
          'of it.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(subtitle, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// The round-8 FixingIt card: one tap re-reads the whole paste in the other
/// date dialect — never a per-line correction, because a plan doesn't change
/// dialect halfway through. Shown only when the flip would actually change a
/// date.
class _MonthFirstCard extends ConsumerWidget {
  const _MonthFirstCard({required this.readMonthFirst});

  final bool readMonthFirst;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              readMonthFirst ? '3/11  →  March 11th' : '3/11  →  3 November',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 6),
            Text(
              readMonthFirst
                  ? 'Every date in the paste is being read month-first — '
                      'one flip covered them all.'
                  : 'Dates here read day-first. If your plan speaks '
                      'month-first — March 11th — flip it once, and every '
                      'date in the paste follows together.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('month-first-fix'),
              onPressed: () => ref
                  .read(pasteFlowProvider.notifier)
                  .readMonthFirst(!readMonthFirst),
              child: Text(readMonthFirst
                  ? 'Read day-first instead'
                  : 'These are month-first dates'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayNumber extends StatelessWidget {
  const _DayNumber(this.number);

  final int number;

  @override
  Widget build(BuildContext context) {
    return Text(
      number.toString().padLeft(2, '0'),
      style: Theme.of(context)
          .textTheme
          .labelMedium
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    );
  }
}

/// The confident read: the full card, chips in itinerary order, a star and
/// time badge exactly where the parser starred (a found, unhedged time).
class _FullDayCard extends StatelessWidget {
  const _FullDayCard({required this.day});

  final ReviewDay day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: Key('day-card-${day.number}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _DayNumber(day.number),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    day.title,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (day.dateLabel != null)
                  Text(day.dateLabel!, style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final stop in day.stops) _StopChip(stop: stop),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StopChip extends StatelessWidget {
  const _StopChip({required this.stop});

  final ReviewStop stop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stop.isStarred) ...[
            Icon(Icons.star, size: 14, color: Colors.amber.shade700),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              stop.text,
              style: stop.isStarred
                  ? theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.bold)
                  : theme.textTheme.bodySmall,
            ),
          ),
          if (stop.timeLabel != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                stop.timeLabel!,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: Colors.brown.shade800),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A clean day when other days need the eye: collapsed to one line, so
/// nothing competes with the doubt for attention.
class _SlimDayRow extends StatelessWidget {
  const _SlimDayRow({required this.day});

  final ReviewDay day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      if (day.dateLabel != null) day.dateLabel!,
      '${day.stops.length} ${day.stops.length == 1 ? 'stop' : 'stops'}',
    ].join(' · ');
    return Card(
      key: Key('day-card-${day.number}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            _DayNumber(day.number),
            const SizedBox(width: 8),
            Expanded(child: Text(day.title, style: theme.textTheme.titleSmall)),
            Text(meta, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// A doubted day, expanded: the cause-specific ask with its one-tap answers,
/// sitting on the way to the accept button so it cannot be skipped unseen.
class _UnsureDayCard extends ConsumerWidget {
  const _UnsureDayCard({required this.day});

  final ReviewDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final doubt = day.doubt!;
    final accent = day.confidence == DayConfidence.low
        ? theme.colorScheme.outline
        : Colors.amber.shade600;
    return Card(
      key: Key('day-card-${day.number}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _DayNumber(day.number),
                const SizedBox(width: 8),
                Expanded(
                    child:
                        Text(day.title, style: theme.textTheme.titleSmall)),
                Text(
                  day.dateLabel ?? 'date open',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            if (day.stops.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final stop in day.stops) _StopChip(stop: stop),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(doubt.ask, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in doubt.options)
                  OutlinedButton(
                    onPressed: () => _apply(context, ref, option),
                    child: Text(option.label),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    DayAskOption option,
  ) async {
    final notifier = ref.read(pasteFlowProvider.notifier);
    switch (option.action) {
      case UseDate(:final date):
        notifier.setDayDate(day.number, date);
      case UseYear(:final year):
        notifier.useYear(year);
      case ConfirmAsIs():
        notifier.confirmDay(day.number);
      case PickDate(:final initial):
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: initial ?? now,
          firstDate: DateTime(now.year - 2),
          lastDate: DateTime(now.year + 5),
        );
        if (picked != null) notifier.setDayDate(day.number, picked);
      case AddStop():
        final text = await _askForStopText(context);
        if (text != null) notifier.addStop(day.number, text);
    }
  }

  Future<String?> _askForStopText(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a stop'),
        content: TextField(
          key: const Key('add-stop-input'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'What happens that day?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('add-stop-save'),
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

/// The set-aside lines: kept, with reasons, never silently dropped.
class _KeptAsideTile extends StatelessWidget {
  const _KeptAsideTile({required this.lines});

  final List<KeptAsideLine> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ExpansionTile(
        key: const Key('set-aside-tile'),
        shape: const Border(),
        title: Text(
          "${lines.length} ${lines.length == 1 ? 'line' : 'lines'} I "
          "couldn't place",
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text('kept, with reasons', style: theme.textTheme.bodySmall),
        children: [
          for (final line in lines)
            ListTile(
              dense: true,
              title: Text(
                line.text,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
              subtitle: Text(line.explanation, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// The paste that wouldn't parse — not a dead end, and never the person's
/// fault. The lines are shown kept; the way forward is another paste.
/// (Round 8 also draws "lay the days out myself" and "start with empty
/// days"; both need the by-hand day editor, which is a later slice.)
class _NothingReadView extends ConsumerWidget {
  const _NothingReadView({required this.review});

  final ItineraryReview review;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'No days in this one — that I could find.',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              "I read it right here on the phone, and I don't guess. "
              "Nothing's thrown away either.",
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in review.keptLines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          line,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Every line stays kept. Fix the plan where it lives and paste '
              'it again — laying the days out by hand arrives in a later '
              'slice.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: const Key('paste-something-else'),
              onPressed: () => ref.read(pasteFlowProvider.notifier).startOver(),
              child: const Text('Paste something else'),
            ),
          ],
        ),
      ),
    );
  }
}
