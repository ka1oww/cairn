// ignore_for_file: deprecated_member_use, use_build_context_synchronously
// SCREENS band (docs/architecture.md): knows app state and nothing below it.
// No repository, no store, no SQL, no parser — the view models come from
// app_state/day_view.dart.
//
// There is one day screen and this is it. Today is `DayPage(today)`, and the
// Trail opens the same widget for every node it draws, because the design
// draws one surface for both (2f, "Today / day detail"). Nothing here reads
// the calendar: which day a date is, and whether it is behind us, are
// decided in app state.
//
// Two ways in, one screen. `DayPage(date:)` asks "what is this date"; the
// Trail's `DayPage.planDay(n)` asks "what is day n", which is the only way to
// reach a day accepted with its date still open. Both end in the same
// `DayView`, and a second day surface remains the thing to refuse in review.
//
// The structure is 2f's: the day's identity, then a flat ordered list of the
// stops as pasted. No progress tracking, no morning/afternoon split, no
// "we're up to here" — every one of those is rejected in the decision
// record. The photo timeline arrives in a later slice and is deliberately
// not stubbed here.
//
// One thing did arrive: **the call to your moment**, at the top of the day,
// which is where the design puts it (the wash card of surface 12a's "later,
// in the app"). It draws nothing at all unless today is asking something of
// you, so a day you are only reading is unchanged.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state/capture_flow.dart';
import '../app_state/day_view.dart';
import '../app_state/maps_handoff_flow.dart';
import '../app_state/trip_providers.dart';
import '../logic/maps_handoff.dart';
import 'capture_screen.dart';

class DayPage extends ConsumerWidget {
  /// The day at [date] — Today, and any dated day the Trail opens.
  const DayPage({super.key, required DateTime this.date}) : number = null;

  /// The plan's day [number], whatever date it fell on and whether or not it
  /// has one. This is the Trail's way in.
  const DayPage.planDay(int this.number, {super.key}) : date = null;

  /// The date this page is showing, at UTC midnight, or null when the page
  /// was opened by position instead.
  final DateTime? date;

  /// The 1-based day of the plan, or null when opened by date.
  final int? number;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = number == null
        ? ref.watch(dayViewProvider(date!))
        : ref.watch(planDayViewProvider(number!));
    return Scaffold(
      body: SafeArea(
        child: switch (view) {
          AsyncData(value: final DayView day) => _Day(view: day, date: date),
          AsyncData() => const SizedBox.shrink(),
          AsyncError(:final error) => Center(
            child: Text('Failed to read: $error'),
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Day extends StatelessWidget {
  const _Day({required this.view, this.date});

  final DayView view;

  /// The date this page was opened on, or null when it was opened by the
  /// plan's day number instead. Only a page that knows its date can be
  /// today, and only today ever asks anything of you.
  final DateTime? date;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Today is a tab's root and has nowhere to go back to; a day the
        // Trail pushed does. Drawing the control exactly when there is
        // somewhere to go is what lets one screen serve both.
        if (Navigator.of(context).canPop())
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: const Key('day-back'),
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to the Trail',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        if (date != null) _CaptureCall(date: date!),
        ...switch (view) {
          final PlannedDay day => _plannedDay(day),
          final GapDay day => _gapDay(day),
          final BeforeTheTrip pre => _beforeTheTrip(pre),
          final AfterTheTrip post => _afterTheTrip(post),
        },
      ],
    );
  }

  List<Widget> _plannedDay(PlannedDay day) => [
    _DayIdentity(day: day),
    const SizedBox(height: 18),
    if (day.stops.isEmpty)
      const _NothingPlanned()
    else
      _StopList(stops: day.stops, isOver: day.isOver, dayNumber: day.number),
  ];

  List<Widget> _gapDay(GapDay day) => [
    _Identity(
      key: const Key('gap-day'),
      title: day.title,
      dateLabel: day.dateLabel,
    ),
    const SizedBox(height: 18),
    const _NothingPlanned(),
  ];

  List<Widget> _beforeTheTrip(BeforeTheTrip view) => [
    _Announcement(
      key: const Key('pre-trip'),
      headline: view.headline,
      detail: view.detail,
    ),
    const SizedBox(height: 26),
    const _Label('NEXT UP'),
    const SizedBox(height: 8),
    _DayIdentity(day: view.nextUp),
    const SizedBox(height: 18),
    if (view.nextUp.stops.isEmpty)
      const _NothingPlanned()
    else
      _StopList(stops: view.nextUp.stops, isOver: false, dayNumber: view.nextUp.number),
  ];

  List<Widget> _afterTheTrip(AfterTheTrip view) => [
    _Announcement(
      key: const Key('post-trip'),
      headline: view.headline,
      detail: view.detail,
    ),
    if (view.closing != null) ...[
      const SizedBox(height: 10),
      _Closing(view.closing!),
    ],
    const SizedBox(height: 26),
    const _Label('THE LAST DAY'),
    const SizedBox(height: 8),
    _DayIdentity(day: view.lastDay),
    const SizedBox(height: 18),
    if (view.lastDay.stops.isEmpty)
      const _NothingPlanned()
    else
      _StopList(stops: view.lastDay.stops, isOver: true, dayNumber: view.lastDay.number),
  ];
}

/// What today is asking of you, at the top of the day — or nothing at all,
/// which is the usual.
///
/// It never says *when* your minute is. A ping you can see coming is a ping
/// you can pose for, and the whole value of the scattered model is that the
/// photograph is one nobody planned
/// (docs/decisions/2026-08-22-the-moment.md).
class _CaptureCall extends ConsumerWidget {
  const _CaptureCall({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(captureCallProvider(date));
    if (call is NoMomentHere) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final (String line, String? action) = switch (call) {
      MomentAhead() => ('Your minute is somewhere in today.', null),
      MomentOpen(isLastStretch: true) => (
        'Your minute. Last stretch.',
        'Take it',
      ),
      MomentOpen() => ('Your minute. Look up.', 'Take it'),
      // Surface 12a's wash card, and design-calls §7: no lockout, ever. A
      // photo taken now carries its real hour and sits visibly late on the
      // page, which is the only pressure the system applies.
      MomentLate() => (
        "Your minute came and went. The door's open till midnight.",
        'Take it now',
      ),
      MomentAnswered(:final hourLabel) => ('Yours landed at $hourLabel.', null),
      NoMomentHere() => ('', null),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line,
            key: const Key('capture-call'),
            style: theme.textTheme.titleMedium,
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('capture-call-action'),
              onPressed: () {
                ref.read(captureFlowProvider.notifier).open();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => const CaptureScreen(),
                  ),
                );
              },
              child: Text(action),
            ),
          ],
        ],
      ),
    );
  }
}

/// Where the trip's ending stands, under the post-trip announcement.
class _Closing extends StatelessWidget {
  const _Closing(this.line);

  final String line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      line,
      key: const Key('post-trip-closing'),
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// The day's identity: which day of the trip it is, then the day itself.
class _DayIdentity extends StatelessWidget {
  const _DayIdentity({required this.day});

  final PlannedDay day;

  @override
  Widget build(BuildContext context) => _Identity(
    eyebrow: 'DAY ${day.number} OF ${day.dayCount}',
    title: day.title,
    // A day accepted with its date still open says so rather than
    // wearing a date nobody gave it (design round 8's spelling).
    dateLabel: day.dateLabel ?? 'date open',
  );
}

class _Identity extends StatelessWidget {
  const _Identity({
    super.key,
    this.eyebrow,
    required this.title,
    required this.dateLabel,
  });

  final String? eyebrow;
  final String title;
  final String dateLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow != null) ...[
          _Label(eyebrow!, key: const Key('day-eyebrow')),
          const SizedBox(height: 6),
        ],
        Text(
          title,
          key: const Key('day-title'),
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 4),
        Text(
          dateLabel,
          key: const Key('day-date'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The day's plan: every stop, in the order it was pasted.
class _StopList extends StatelessWidget {
  const _StopList({required this.stops, required this.isOver, required this.dayNumber});

  final List<DayStop> stops;
  final bool isOver;
  final int dayNumber;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final stop in stops) ...[
          if (stop.areaHeadingBefore != null) _AreaHeading(area: stop.areaHeadingBefore!, dayNumber: dayNumber, isOver: isOver),
          _StopRow(stop: stop, isOver: isOver, dayNumber: dayNumber),
        ],
      ],
    );
  }
}

class _AreaHeading extends ConsumerWidget {
  const _AreaHeading({required this.area, required this.dayNumber, required this.isOver});
  final String area;
  final int dayNumber;
  final bool isOver;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Try to find day number from context: we pass via ancestor? Simpler: handle via callback with area string.
    // For subheading tap we need day number; we get it from enclosing _StopList? For now use 0 if unknown.
    return InkWell(
      key: Key('area-heading-$area'),
      onTap: () => _showAreaCorrectionSheet(context, ref, area: area, dayNumber: dayNumber, isRun: true),
      child: Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 2),
        child: Text(
          area.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.4,
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _MealLabel extends StatelessWidget {
  const _MealLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// One stop.
///
/// A star and a time, or neither. **This is the only place a time appears in
/// the whole app**, which is what makes it mean something: a starred stop is
/// one the plan pinned to a clock, and an unstarred stop shows no time even
/// where the source line hedged one.
class _StopRow extends ConsumerWidget {
  const _StopRow({required this.stop, required this.isOver, this.dayNumber});

  final DayStop stop;
  final bool isOver;
  final int? dayNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final isPlace = stop.kind == StopLineKind.place;
    final display = _displayFor(stop);
    final showBadge = stop.places.length > 1 && shouldTruncateMultiPlace(stop.text);
    final content = Container(
      key: Key('stop-${stop.position}'),
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.7),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 26,
            child: stop.isStarred
                ? Icon(
                    isOver ? Icons.star_border : Icons.star,
                    size: 18,
                    color: isOver ? muted : Colors.amber.shade700,
                  )
                : Text(
                    stop.position.toString().padLeft(2, '0'),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (stop.mealLabel != null) ...[
                      _MealLabel(stop.mealLabel!),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        display,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: stop.isStarred && !isOver ? FontWeight.bold : FontWeight.normal,
                          color: isOver ? muted : null,
                        ),
                      ),
                    ),
                    if (showBadge) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text('${stop.places.length} places', style: theme.textTheme.labelSmall),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (isPlace) ...[
            const SizedBox(width: 6),
            Icon(Icons.north_east, size: 13, color: theme.colorScheme.outlineVariant),
          ],
          if (stop.timeLabel != null) ...[
            const SizedBox(width: 10),
            _Time(
              key: Key('stop-time-${stop.position}'),
              label: stop.timeLabel!,
              isOver: isOver,
            ),
          ],
        ],
      ),
    );
    if (!isPlace) return content;
    return InkWell(
      key: Key('stop-tap-${stop.position}'),
      onTap: () => ref.read(mapsHandoffProvider).openStop(stop),
      onLongPress: () => _showPlacesSheet(context, ref, stop),
      child: content,
    );
  }

  String _displayFor(DayStop s) {
    // Meal label stripped already rendered separately; show query part
    // For multi-place truncation, shorten
    if (s.places.length > 1 && shouldTruncateMultiPlace(s.text)) {
      final first = s.places.first;
      return '$first …';
    }
    // Show text minus meal label if present? Use classifier query for display text?
    // Keep raw text sans meal label duplication: classify to get remainder
    final c = classifyStopLine(s.text);
    if (c.mealLabel != null && c.query.isNotEmpty) return c.query;
    return s.text;
  }
}

Future<void> _showPlacesSheet(BuildContext context, WidgetRef ref, DayStop stop) async {
  final theme = Theme.of(context);
  final handoff = ref.read(mapsHandoffProvider);
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Text(stop.text, style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'serif')),
          ),
          if (stop.area != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Each opens a Maps search in ${stop.area}.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            )
          else if (stop.adjacentAreas.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('No area is written for this stop.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          for (final place in stop.places.isEmpty ? [stop.text] : stop.places)
            ListTile(
              key: Key('place-$place'),
              leading: const Icon(Icons.place_outlined),
              title: Text(place),
              onTap: () {
                Navigator.of(ctx).pop();
                handoff.openPlace(place, area: stop.area);
              },
            ),
          if (stop.area != null) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: Text('Just show me ${stop.area}'),
              onTap: () {
                Navigator.of(ctx).pop();
                handoff.openArea(stop.area!);
              },
            ),
          ] else if (stop.adjacentAreas.isNotEmpty) ...[
            const Divider(height: 1),
            ListTile(
              title: const Text('Search it as written'),
              leading: const Icon(Icons.search),
              onTap: () {
                Navigator.of(ctx).pop();
                handoff.openPlace(stop.places.isNotEmpty ? stop.places.first : stop.text, area: null);
              },
            ),
            const Divider(height: 1),
            for (final a in stop.adjacentAreas)
              ListTile(
                leading: const Icon(Icons.near_me_outlined),
                title: Text('nearest to $a'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  handoff.openPlace(stop.places.isNotEmpty ? stop.places.first : stop.text, area: a);
                },
              ),
          ],
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(stop.area == null ? 'Give it an area' : 'The area is wrong'),
            onTap: () {
              Navigator.of(ctx).pop();
              _showAreaCorrectionSheet(context, ref, area: stop.area ?? '', dayNumber: 0, isRun: false, stop: stop);
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

Future<void> _showAreaCorrectionSheet(BuildContext context, WidgetRef ref,
    {required String area, required int dayNumber, required bool isRun, DayStop? stop}) async {
  final theme = Theme.of(context);
  final actions = ref.read(dayActionsProvider);
  // Collect all distinct areas in plan
  final plan = ref.read(savedItineraryProvider).value;
  final allAreas = <String>{};
  if (plan != null) {
    for (final d in plan.days) {
      for (final s in d.stops) {
        if (s.area != null) allAreas.add(s.area!);
      }
    }
  }
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text('Where is this, really?', style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'serif')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(isRun ? 'Every stop under this heading will search there.' : 'Search this stop there.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          for (final a in allAreas)
            RadioListTile<String>(
              title: Text(a),
              value: a,
              groupValue: area,
              onChanged: (v) => Navigator.of(ctx).pop(v),
            ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Somewhere else…'),
            onTap: () => Navigator.of(ctx).pop('__else__'),
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('No area — just search the words'),
            onTap: () => Navigator.of(ctx).pop('__none__'),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
  if (choice == null) return;
  if (choice == '__else__') {
    final typed = await showDialog<String>(
      context: context,
      builder: (dctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('Area'),
          content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'Ginza')),
          actions: [
            TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.of(dctx).pop(c.text.trim()), child: const Text('Save')),
          ],
        );
      },
    );
    if (typed == null || typed.isEmpty) return;
    if (isRun) {
      await actions.setAreaRun(dayNumber: dayNumber, currentArea: area, newArea: typed);
    } else if (stop != null) {
      await actions.setStopArea(dayNumber: dayNumber == 0 ? _inferDayNumber(plan, stop) : dayNumber, position: stop.position, area: typed);
    }
    return;
  }
  if (choice == '__none__') {
    if (isRun) {
      await actions.setAreaRun(dayNumber: dayNumber, currentArea: area, newArea: null);
    } else if (stop != null) {
      await actions.setStopArea(dayNumber: dayNumber == 0 ? _inferDayNumber(plan, stop) : dayNumber, position: stop.position, area: null);
    }
    return;
  }
  // chosen existing area
  if (isRun) {
    await actions.setAreaRun(dayNumber: dayNumber, currentArea: area, newArea: choice);
  } else if (stop != null) {
    await actions.setStopArea(dayNumber: dayNumber == 0 ? _inferDayNumber(plan, stop) : dayNumber, position: stop.position, area: choice);
  }
}

int _inferDayNumber(dynamic plan, DayStop stop) {
  if (plan == null) return 1;
  for (final d in plan.days) {
    for (final s in d.stops) {
      if (s.text == stop.text) return d.number as int;
    }
  }
  return 1;
}

class _Time extends StatelessWidget {
  const _Time({super.key, required this.label, required this.isOver});

  final String label;
  final bool isOver;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (isOver) {
      return Text(
        'was $label',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: Colors.brown.shade800,
        ),
      ),
    );
  }
}

/// A day with nothing in it is a written state, not an empty list — design
/// surface 3g. No skeleton rows and no nagging.
class _NothingPlanned extends StatelessWidget {
  const _NothingPlanned();

  @override
  Widget build(BuildContext context) => Text(
    'Nothing planned. The best day of most trips.',
    key: const Key('nothing-planned'),
    style: Theme.of(context).textTheme.titleMedium,
  );
}

class _Announcement extends StatelessWidget {
  const _Announcement({
    super.key,
    required this.headline,
    required this.detail,
  });

  final String headline;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(headline, style: theme.textTheme.displaySmall),
        const SizedBox(height: 8),
        Text(
          detail,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        letterSpacing: 1.4,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
