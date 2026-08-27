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
//
// Round 4 of the editor rounds turned this read-back into a real editor
// (`data/cairn-ux/design-mock.html`, screen 2), and the gestures are the
// captain-approved ones:
//
//  - **a plain tap on a chip** opens its little menu — edit the words, give
//    it a time, move it to another day, remove it;
//  - **a long press drags the whole chip**, not a handle — up and down inside
//    its day to rearrange, or across into another day. Set-aside lines drag
//    the same way, back into a day;
//  - **a tap on a day header** renames it and dates it — and when the day's
//    own title named a date, that tap opens the date sheet instead, where one
//    more tap binds it.
//
// Two rules the screen must not quietly break. Removing is never deleting:
// [_StopChip]'s remove calls `removeStop`, which sets the line aside where it
// can be dragged back. And a date a title named is offered, never assumed —
// the sheet says which weekday it worked out, so a wrong year is visible
// before it is bound.
//
// The same editor draws a trip that is already running (screen 3, "Edit the
// whole plan"). Only the foot of the screen differs, and it differs because
// the stakes do: a plan on its way in is accepted, a plan already running is
// *saved over*, so the button says so, a cancel that leaves the trip exactly
// as it was sits beside it, and the re-paste is offered from here. Nothing
// above the foot knows which mode it is in — the editing is the same editing.
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
            if (review.monthFirstExample case final example?) ...[
              _MonthFirstCard(
                example: example,
                readMonthFirst: review.readMonthFirst,
              ),
              const SizedBox(height: 10),
            ],
            if (review.keptAside.isNotEmpty) ...[
              _KeptAsideTile(review: review),
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
            const SizedBox(height: 6),
            // The read is drawn in full either way; only the accept goes.
            // A closed trip's plan is half the record it closed with, so
            // there is nothing to accept into — said in words rather than by
            // a button that does nothing.
            if (review.canAccept)
              FilledButton(
                key: const Key('accept-button'),
                onPressed: () => ref.read(pasteFlowProvider.notifier).accept(),
                child: Text(
                  review.editingLivePlan ? 'Save changes' : 'Looks right',
                ),
              )
            else
              Text(
                review.refusal!,
                key: const Key('accept-refused'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            const SizedBox(height: 8),
            if (review.editingLivePlan) ...[
              Center(
                child: TextButton(
                  key: const Key('repaste-plan'),
                  onPressed: () =>
                      ref.read(pasteFlowProvider.notifier).repasteCurrentPlan(),
                  child: const Text('Re-paste the plan text'),
                ),
              ),
              Center(
                child: TextButton(
                  key: const Key('cancel-plan-edit'),
                  onPressed: () =>
                      ref.read(pasteFlowProvider.notifier).cancelPlanEdit(),
                  child: const Text('Cancel — leave the trip as it is'),
                ),
              ),
            ] else
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
      title =
          '$days ${days == 1 ? 'day' : 'days'}, '
          '$stops ${stops == 1 ? 'stop' : 'stops'}.';
      subtitle = review.editingLivePlan
          ? 'Tap anything to fix it. Nothing changes until you save.'
          : 'Tap anything to fix it. Nothing is final yet.';
    } else {
      final clean = review.cleanCount;
      title = clean == 0
          ? '${unsure == 1 ? 'One day needs' : '$unsure days need'} your eye.'
          : '$clean read clean. '
                '${unsure == 1 ? 'One needs' : '$unsure need'} your eye.';
      subtitle =
          "It knows which lines it wasn't sure of — that's the point "
          'of it. Tap anything to fix it.';
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
///
/// It teaches with the **plan's own** first ambiguous date, not an invented
/// one: a card reading `3/11` beside a plan that says `12/11` makes the
/// person translate the lesson before they can use it. The example is built
/// in the app-state band ([MonthFirstExample]); this only arranges it.
class _MonthFirstCard extends ConsumerWidget {
  const _MonthFirstCard({required this.example, required this.readMonthFirst});

  final MonthFirstExample example;
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
              '${example.asWritten}  →  '
              '${readMonthFirst ? example.monthFirstReading : example.dayFirstReading}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 6),
            Text(
              readMonthFirst
                  ? 'Every date in the paste is being read month-first — '
                        'one flip covered them all.'
                  : 'Dates here read day-first. If your plan speaks '
                        'month-first — ${example.monthFirstReading} — flip it '
                        'once, and every date in the paste follows together.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'It re-reads the whole paste, so any edits made here start '
              'again from the new read.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('month-first-fix'),
              onPressed: () => ref
                  .read(pasteFlowProvider.notifier)
                  .readMonthFirst(!readMonthFirst),
              child: Text(
                readMonthFirst
                    ? 'Read day-first instead'
                    : 'These are month-first dates',
              ),
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
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    );
  }
}

/// The confident read: the full card, chips in itinerary order, a star and
/// time badge exactly where there is a time. Every part of it is touchable.
class _FullDayCard extends StatelessWidget {
  const _FullDayCard({required this.day});

  final ReviewDay day;

  @override
  Widget build(BuildContext context) {
    return _DayDropZone(
      dayNumber: day.number,
      child: Card(
        key: Key('day-card-${day.number}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DayHeaderRow(day: day),
              const SizedBox(height: 8),
              _DayChips(day: day),
            ],
          ),
        ),
      ),
    );
  }
}

/// A clean day when other days need the eye: collapsed to one line, so
/// nothing competes with the doubt for attention. Still a door — a tap opens
/// the day editor, and a chip dragged from another day still lands here.
class _SlimDayRow extends ConsumerWidget {
  const _SlimDayRow({required this.day});

  final ReviewDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final meta = [
      if (day.dateLabel != null) day.dateLabel!,
      '${day.stops.length} ${day.stops.length == 1 ? 'stop' : 'stops'}',
    ].join(' · ');
    return _DayDropZone(
      dayNumber: day.number,
      child: Card(
        key: Key('day-card-${day.number}'),
        child: InkWell(
          onTap: () => _openDayHeader(context, ref, day),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _DayNumber(day.number),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(day.title, style: theme.textTheme.titleSmall),
                ),
                if (day.dateSuggestion != null) ...[
                  _DatePromptChip(day: day),
                  const SizedBox(width: 6),
                ],
                Text(meta, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
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
    return _DayDropZone(
      dayNumber: day.number,
      child: Card(
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
              _DayHeaderRow(day: day, dateFallback: 'date open'),
              const SizedBox(height: 8),
              _DayChips(day: day),
              const SizedBox(height: 8),
              Text(doubt.ask, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in doubt.options)
                    OutlinedButton(
                      onPressed: () => _applyAsk(context, ref, day, option),
                      child: Text(option.label),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _applyAsk(
  BuildContext context,
  WidgetRef ref,
  ReviewDay day,
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
      final picked = await _pickDate(context, initial);
      if (picked != null) notifier.setDayDate(day.number, picked);
    case AddStop():
      final text = await _askForText(
        context,
        title: 'Add a stop',
        hint: 'What happens that day?',
        action: 'Add',
        fieldKey: const Key('add-stop-input'),
        saveKey: const Key('add-stop-save'),
      );
      if (text != null) notifier.addStop(day.number, text);
  }
}

// ---------------------------------------------------------------------------
// The day header: the title, the date, and the doors behind both.
// ---------------------------------------------------------------------------

class _DayHeaderRow extends ConsumerWidget {
  const _DayHeaderRow({required this.day, this.dateFallback});

  final ReviewDay day;

  /// What to draw where the date goes while it is still open. The doubted
  /// card says "date open" out loud; a clean card says nothing at all.
  final String? dateFallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trailing = day.dateLabel ?? dateFallback;
    return InkWell(
      key: Key('day-header-${day.number}'),
      onTap: () => _openDayHeader(context, ref, day),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            _DayNumber(day.number),
            const SizedBox(width: 8),
            Expanded(child: Text(day.title, style: theme.textTheme.titleSmall)),
            if (day.dateSuggestion != null) ...[
              _DatePromptChip(day: day),
              const SizedBox(width: 6),
            ] else if (trailing != null) ...[
              Text(trailing, style: theme.textTheme.bodySmall),
              const SizedBox(width: 6),
            ],
            Icon(
              Icons.edit_outlined,
              size: 14,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

/// The subtle prompt the mock draws in a day header whose own title carried a
/// date nobody has answered about yet. One tap opens the sheet; the sheet's
/// one tap binds it.
class _DatePromptChip extends ConsumerWidget {
  const _DatePromptChip({required this.day});

  final ReviewDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final suggestion = day.dateSuggestion!;
    return GestureDetector(
      key: Key('date-prompt-${day.number}'),
      onTap: () => _showDateSheet(context, ref, day),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          '${suggestion.dateLabel}?',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// A tap on the header goes wherever the day's own question is: to the date
/// sheet while a date in its title is unanswered, and to the day editor once
/// it is.
Future<void> _openDayHeader(
  BuildContext context,
  WidgetRef ref,
  ReviewDay day,
) {
  if (day.dateSuggestion != null) return _showDateSheet(context, ref, day);
  return _showDayEditor(context, ref, day);
}

// ---------------------------------------------------------------------------
// The chips.
// ---------------------------------------------------------------------------

/// What a long press is carrying: a stop out of some day, or a set-aside line
/// on its way back into one.
class _Dragged {
  const _Dragged.stop(String this.stopId) : asideId = null;
  const _Dragged.aside(String this.asideId) : stopId = null;

  final String? stopId;
  final String? asideId;
}

/// The one place a drop is turned into an edit. A stop lands at a slot; a
/// kept line becomes a stop at that slot. Null [index] means the end of the
/// day.
void _dropInto(WidgetRef ref, _Dragged item, int dayNumber, int? index) {
  final notifier = ref.read(pasteFlowProvider.notifier);
  final stopId = item.stopId;
  if (stopId != null) {
    notifier.moveStop(stopId, toDayNumber: dayNumber, toIndex: index);
  } else {
    notifier.restoreAside(
      item.asideId!,
      toDayNumber: dayNumber,
      toIndex: index,
    );
  }
}

/// The whole card as a drop target, so a chip let go anywhere over a day
/// joins that day rather than snapping back. The slots between chips sit on
/// top of this and win when the aim was precise.
class _DayDropZone extends ConsumerWidget {
  const _DayDropZone({required this.dayNumber, required this.child});

  final int dayNumber;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return DragTarget<_Dragged>(
      onAcceptWithDetails: (details) =>
          _dropInto(ref, details.data, dayNumber, null),
      builder: (context, candidate, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: candidate.isEmpty
                ? Colors.transparent
                : theme.colorScheme.primary,
            width: 2,
          ),
        ),
        child: child,
      ),
    );
  }
}

class _DayChips extends StatelessWidget {
  const _DayChips({required this.day});

  final ReviewDay day;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 2,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (index, stop) in day.stops.indexed) ...[
          _DropSlot(dayNumber: day.number, index: index),
          _StopChip(stop: stop, day: day),
        ],
        _DropSlot(dayNumber: day.number, index: day.stops.length),
        const SizedBox(width: 4),
        _AddStopChip(day: day),
      ],
    );
  }
}

/// A gap between two chips that opens up when something is dragged over it —
/// the up/down rearrange inside a day, and the precise landing spot across
/// days.
class _DropSlot extends ConsumerWidget {
  const _DropSlot({required this.dayNumber, required this.index});

  final int dayNumber;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return DragTarget<_Dragged>(
      key: Key('drop-slot-$dayNumber-$index'),
      onAcceptWithDetails: (details) =>
          _dropInto(ref, details.data, dayNumber, index),
      builder: (context, candidate, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: candidate.isEmpty ? 4 : 24,
        height: 26,
        decoration: BoxDecoration(
          color: candidate.isEmpty
              ? Colors.transparent
              : theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}

class _StopChip extends ConsumerWidget {
  const _StopChip({required this.stop, required this.day});

  final ReviewStop stop;
  final ReviewDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final body = _ChipBody(stop: stop);
    return LongPressDraggable<_Dragged>(
      data: _Dragged.stop(stop.id),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
        offset: const Offset(-40, -18),
        child: Material(
          color: Colors.transparent,
          child: Opacity(opacity: 0.9, child: body),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: body),
      child: GestureDetector(
        key: Key('stop-chip-${stop.id}'),
        onTap: () => _showStopMenu(context, ref, stop, day),
        child: body,
      ),
    );
  }
}

class _ChipBody extends StatelessWidget {
  const _ChipBody({required this.stop});

  final ReviewStop stop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(99),
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
                  ? theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    )
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
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.brown.shade800,
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          Icon(
            Icons.drag_indicator,
            size: 13,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _AddStopChip extends ConsumerWidget {
  const _AddStopChip({required this.day});

  final ReviewDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return GestureDetector(
      key: Key('add-stop-${day.number}'),
      onTap: () async {
        final text = await _askForText(
          context,
          title: 'Add a stop',
          hint: 'What happens that day?',
          action: 'Add',
          fieldKey: const Key('add-stop-input'),
          saveKey: const Key('add-stop-save'),
        );
        if (text != null) {
          ref.read(pasteFlowProvider.notifier).addStop(day.number, text);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: theme.colorScheme.primary, width: 1.5),
        ),
        child: Text(
          '+ add a stop',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// The set-aside lines: kept, with reasons, never silently dropped — and now
/// also where a stop the person took out of a day waits. Every one of them
/// drags back into a day.
class _KeptAsideTile extends StatelessWidget {
  const _KeptAsideTile({required this.review});

  final ItineraryReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = review.keptAside;
    final count = '${lines.length} ${lines.length == 1 ? 'line' : 'lines'}';
    return Card(
      child: ExpansionTile(
        key: const Key('set-aside-tile'),
        shape: const Border(),
        title: Text(
          review.anyRemovedByPerson
              ? '$count set aside'
              : "$count I couldn't place",
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text('kept, with reasons', style: theme.textTheme.bodySmall),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Hold one and drag it onto a day to put it there.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AsideChip(line: line),
                  const SizedBox(height: 4),
                  Text(line.explanation, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AsideChip extends StatelessWidget {
  const _AsideChip({required this.line});

  final KeptAsideLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              line.text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            Icons.drag_indicator,
            size: 13,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: LongPressDraggable<_Dragged>(
        key: Key('aside-chip-${line.id}'),
        data: _Dragged.aside(line.id),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Transform.translate(
          offset: const Offset(-40, -18),
          child: Material(
            color: Colors.transparent,
            child: Opacity(opacity: 0.9, child: body),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: body),
        child: body,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The sheets and dialogs.
// ---------------------------------------------------------------------------

/// The mock's little popover, as a sheet: the four things a chip can become.
Future<void> _showStopMenu(
  BuildContext context,
  WidgetRef ref,
  ReviewStop stop,
  ReviewDay day,
) async {
  final theme = Theme.of(context);
  final notifier = ref.read(pasteFlowProvider.notifier);
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(
              stop.text,
              style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'serif'),
            ),
          ),
          ListTile(
            key: const Key('stop-menu-edit'),
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit the words'),
            onTap: () => Navigator.of(sheetContext).pop('edit'),
          ),
          ListTile(
            key: const Key('stop-menu-time'),
            leading: const Icon(Icons.schedule),
            title: Text(
              stop.timeLabel == null ? 'Give it a time' : 'Change the time',
            ),
            onTap: () => Navigator.of(sheetContext).pop('time'),
          ),
          if (stop.timeLabel != null)
            ListTile(
              key: const Key('stop-menu-untime'),
              leading: const Icon(Icons.star_outline),
              title: const Text('Take the time off'),
              onTap: () => Navigator.of(sheetContext).pop('untime'),
            ),
          ListTile(
            key: const Key('stop-menu-move'),
            leading: const Icon(Icons.arrow_forward),
            title: const Text('Move to another day'),
            onTap: () => Navigator.of(sheetContext).pop('move'),
          ),
          ListTile(
            key: const Key('stop-menu-remove'),
            leading: Icon(Icons.close, color: theme.colorScheme.error),
            title: Text(
              'Remove',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: const Text('kept in the set-aside, not deleted'),
            onTap: () => Navigator.of(sheetContext).pop('remove'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'edit':
      final text = await _askForText(
        context,
        title: 'Edit the words',
        hint: 'What happens here?',
        action: 'Save',
        initial: stop.text,
        fieldKey: const Key('edit-stop-input'),
        saveKey: const Key('edit-stop-save'),
      );
      if (text != null) notifier.editStopText(stop.id, text);
    case 'time':
      final picked = await showTimePicker(
        context: context,
        initialTime: _initialTimeOf(stop),
      );
      if (picked != null) {
        notifier.setStopTime(stop.id, picked.hour, picked.minute);
      }
    case 'untime':
      notifier.clearStopTime(stop.id);
    case 'move':
      final target = await _askWhichDay(context, ref, exceptDay: day.number);
      if (target != null) notifier.moveStop(stop.id, toDayNumber: target);
    case 'remove':
      notifier.removeStop(stop.id);
  }
}

TimeOfDay _initialTimeOf(ReviewStop stop) {
  final label = stop.timeLabel;
  if (label == null) return const TimeOfDay(hour: 9, minute: 0);
  final parts = label.split(':');
  return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
}

/// "Move to another day", for the person who would rather not drag.
Future<int?> _askWhichDay(
  BuildContext context,
  WidgetRef ref, {
  required int exceptDay,
}) {
  final state = ref.read(pasteFlowProvider);
  final days = state is PasteReview ? state.review.days : const <ReviewDay>[];
  final theme = Theme.of(context);
  return showModalBottomSheet<int>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(
              'Which day?',
              style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'serif'),
            ),
          ),
          for (final day in days)
            if (day.number != exceptDay)
              ListTile(
                key: Key('move-to-day-${day.number}'),
                leading: _DayNumber(day.number),
                title: Text(day.title),
                subtitle: day.dateLabel == null ? null : Text(day.dateLabel!),
                onTap: () => Navigator.of(sheetContext).pop(day.number),
              ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Renaming and dating one day. Reached from a header whose date question is
/// already answered — the unanswered one goes to [_showDateSheet] instead.
Future<void> _showDayEditor(
  BuildContext context,
  WidgetRef ref,
  ReviewDay day,
) async {
  final notifier = ref.read(pasteFlowProvider.notifier);
  final result = await showModalBottomSheet<_DayEdit>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _DayEditorSheet(day: day),
  );
  if (result == null || !context.mounted) return;

  notifier.renameDay(day.number, result.name);
  switch (result.choice) {
    case 'date':
      final picked = await _pickDate(context, day.date);
      if (picked != null) notifier.setDayDate(day.number, picked);
    case 'undate':
      notifier.leaveDateOpen(day.number);
  }
}

/// What the day editor hands back: the name as it was typed, and which of its
/// doors was used to leave.
class _DayEdit {
  const _DayEdit(this.name, this.choice);

  final String name;
  final String choice;
}

/// Stateful because it owns a [TextEditingController], and a controller
/// disposed the moment the sheet pops is still being rebuilt by the sheet's
/// own exit animation.
class _DayEditorSheet extends StatefulWidget {
  const _DayEditorSheet({required this.day});

  final ReviewDay day;

  @override
  State<_DayEditorSheet> createState() => _DayEditorSheetState();
}

class _DayEditorSheetState extends State<_DayEditorSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.day.place ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _leave(String choice) =>
      Navigator.of(context).pop(_DayEdit(_controller.text, choice));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final day = widget.day;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text(
                'Day ${day.number}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'serif',
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: TextField(
                key: const Key('rename-day-input'),
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: 'What to call it',
                  hintText: 'Tokyo',
                ),
              ),
            ),
            ListTile(
              key: const Key('day-editor-date'),
              leading: const Icon(Icons.event_outlined),
              title: Text(
                day.dateLabel == null ? 'Set a date' : 'Change the date',
              ),
              subtitle: Text(day.dateLabel ?? 'date open'),
              onTap: () => _leave('date'),
            ),
            if (day.dateLabel != null)
              ListTile(
                key: const Key('day-editor-undate'),
                leading: const Icon(Icons.event_busy_outlined),
                title: const Text('Leave it open'),
                onTap: () => _leave('undate'),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    key: const Key('rename-day-save'),
                    onPressed: () => _leave('rename'),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// **The date seam.** A day whose own title named a date, drawn as the
/// captain approved it in round 4: the serif question, the date as one soft
/// card that binds on a tap, and the two alternatives demoted to small text.
///
/// The weekday is on the card on purpose — it is how a year worked out wrong
/// shows itself before it is bound, since the title rarely spells one.
Future<void> _showDateSheet(
  BuildContext context,
  WidgetRef ref,
  ReviewDay day,
) async {
  final suggestion = day.dateSuggestion;
  if (suggestion == null) return _showDayEditor(context, ref, day);
  final theme = Theme.of(context);
  final notifier = ref.read(pasteFlowProvider.notifier);

  final choice = await showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This day has a date in its title.',
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'serif',
                fontWeight: FontWeight.normal,
              ),
            ),
            const SizedBox(height: 2),
            _QuotedTitle(suggestion: suggestion),
            const SizedBox(height: 12),
            InkWell(
              key: const Key('date-sheet-use-it'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(sheetContext).pop('use'),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Text(
                      suggestion.dateLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${suggestion.weekdayLabel} · '
                        'day ${suggestion.dayNumber}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      'Use it ›',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  key: const Key('date-sheet-pick-another'),
                  onPressed: () => Navigator.of(sheetContext).pop('pick'),
                  child: const Text('Pick another date'),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('date-sheet-leave-open'),
                  onPressed: () => Navigator.of(sheetContext).pop('leave'),
                  child: const Text('Leave it open'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'use':
      notifier.useDateSuggestion(day.number);
    case 'leave':
      notifier.leaveDateOpen(day.number);
    case 'pick':
      final picked = await _pickDate(context, suggestion.date);
      if (picked != null) {
        notifier.setDayDate(day.number, picked);
      } else {
        // Backing out of the picker is not an answer: the suggestion stays
        // on offer rather than quietly disappearing.
      }
  }
}

/// `"Tokyo, 14 June" — want me to use it?`, with the date-shaped part of the
/// person's own title picked out.
class _QuotedTitle extends StatelessWidget {
  const _QuotedTitle({required this.suggestion});

  final DateSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'serif',
      color: theme.colorScheme.onSurfaceVariant,
    );
    final title = suggestion.headerText;
    final at = title.indexOf(suggestion.fragment);
    return Text.rich(
      TextSpan(
        style: base,
        children: at < 0
            ? [TextSpan(text: '"$title" — want me to use it?')]
            : [
                TextSpan(text: '"${title.substring(0, at)}'),
                TextSpan(
                  text: suggestion.fragment,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text:
                      '${title.substring(at + suggestion.fragment.length)}" '
                      '— want me to use it?',
                ),
              ],
      ),
    );
  }
}

Future<DateTime?> _pickDate(BuildContext context, DateTime? initial) {
  final now = DateTime.now();
  return showDatePicker(
    context: context,
    initialDate: initial ?? now,
    firstDate: DateTime(now.year - 2),
    lastDate: DateTime(now.year + 5),
  );
}

Future<String?> _askForText(
  BuildContext context, {
  required String title,
  required String hint,
  required String action,
  required Key fieldKey,
  required Key saveKey,
  String initial = '',
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
    ),
  );
}

/// Stateful for the same reason [_DayEditorSheet] is: the dialog's exit
/// animation rebuilds this after the pop, and a controller disposed at the
/// pop is a controller used after disposal.
class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.hint,
    required this.action,
    required this.fieldKey,
    required this.saveKey,
    required this.initial,
  });

  final String title;
  final String hint;
  final String action;
  final Key fieldKey;
  final Key saveKey;
  final String initial;

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
      title: Text(widget.title),
      content: TextField(
        key: widget.fieldKey,
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
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
              onPressed: () =>
                  ref.read(pasteFlowProvider.notifier).backToTheText(),
              child: Text(
                review.editingLivePlan
                    ? 'Back to the text'
                    : 'Paste something else',
              ),
            ),
            // Over a running trip this state is reachable — the person emptied
            // the text — and the trip must not be stranded behind it. Nothing
            // has been saved, so leaving costs nothing.
            if (review.editingLivePlan)
              Center(
                child: TextButton(
                  key: const Key('cancel-plan-edit'),
                  onPressed: () =>
                      ref.read(pasteFlowProvider.notifier).cancelPlanEdit(),
                  child: const Text('Cancel — leave the trip as it is'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
