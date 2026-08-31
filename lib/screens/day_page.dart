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

/// The day's plan: every stop, in the order it was pasted, under the areas
/// they are in.
class _StopList extends StatelessWidget {
  const _StopList({
    required this.stops,
    required this.isOver,
    required this.dayNumber,
  });

  final List<DayStop> stops;
  final bool isOver;
  final int dayNumber;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final stop in stops) ...[
          if (stop.areaHeadingBefore != null)
            _AreaHeading(
              area: stop.areaHeadingBefore!,
              dayNumber: dayNumber,
              position: stop.position,
            ),
          _StopRow(stop: stop, isOver: isOver, dayNumber: dayNumber),
        ],
      ],
    );
  }
}

/// The running area, drawn where it changes.
///
/// Quiet on purpose — the same voice as the day's own eyebrow — because it is
/// what Cairn worked out rather than what the traveller wrote. It is tappable,
/// and that is the whole correction door: what is visibly wrong is one tap
/// from being right for the rest of the trip.
class _AreaHeading extends ConsumerWidget {
  const _AreaHeading({
    required this.area,
    required this.dayNumber,
    required this.position,
  });

  final String area;
  final int dayNumber;
  final int position;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return InkWell(
      key: Key('area-heading-$position-$area'),
      onTap: () => _correctArea(
        context,
        ref,
        dayNumber: dayNumber,
        area: area,
        wholeRun: true,
        position: position,
      ),
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

/// `LUNCH` on a meal line: structure, not a place. It shows, and it is never
/// part of what a tap searches for.
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
///
/// A row that opens a maps search carries a small arrow, and a row that does
/// not simply has none: an inert line is drawn exactly like any other, never
/// greyed and never restyled, because it is the traveller's own words and
/// nothing is wrong with it.
class _StopRow extends ConsumerWidget {
  const _StopRow({
    required this.stop,
    required this.isOver,
    required this.dayNumber,
  });

  final DayStop stop;
  final bool isOver;
  final int dayNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final badged = stop.showsPlaceCount;
    final row = Container(
      key: Key('stop-${stop.position}'),
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outline, width: 0.7),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 26,
            child: stop.isStarred
                // Past tense, the star loses its fill: surface 3i, which
                // holds no opinion about a starred stop that was missed.
                ? Icon(
                    isOver ? Icons.star_border : Icons.star,
                    size: 18,
                    color: isOver ? muted : Colors.amber.shade700,
                  )
                : Text(
                    stop.position.toString().padLeft(2, '0'),
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
          ),
          const SizedBox(width: 10),
          if (stop.mealLabel != null) ...[
            _MealLabel(stop.mealLabel!),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              badged ? '${stop.places.first} …' : stop.text,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: stop.isStarred && !isOver
                    ? FontWeight.bold
                    : FontWeight.normal,
                color: isOver ? muted : null,
              ),
            ),
          ),
          if (badged) ...[
            const SizedBox(width: 6),
            Container(
              key: Key('places-badge-${stop.position}'),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                '${stop.places.length} places',
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
            ),
          ],
          if (stop.opensMaps) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.north_east,
              size: 13,
              color: theme.colorScheme.outlineVariant,
            ),
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
    if (!stop.opensMaps) return row;
    return InkWell(
      key: Key('stop-tap-${stop.position}'),
      onTap: () => _openStop(ref, stop),
      onLongPress: () => _showPlacesSheet(context, ref, stop, dayNumber),
      child: row,
    );
  }
}

/// What a short tap sends.
///
/// One free keyless maps URL carries exactly one search, so a row that stands
/// for a list of shops cannot open all of them. A row drawn with the "N
/// places" badge opens the district instead — the honest useful answer — and
/// the long press is where each shop is offered. Every other row sends its own
/// words, plus the area in force if there is one.
Future<bool> _openStop(WidgetRef ref, DayStop stop) {
  final handoff = ref.read(mapsHandoffProvider);
  if (stop.showsPlaceCount && stop.area != null) {
    return handoff.openArea(stop.area!);
  }
  return handoff.openStop(stop);
}

/// The long press: every place on the line, then the district, then the door
/// to correcting the area.
Future<void> _showPlacesSheet(
  BuildContext context,
  WidgetRef ref,
  DayStop stop,
  int dayNumber,
) async {
  final theme = Theme.of(context);
  final handoff = ref.read(mapsHandoffProvider);
  final searchText = stop.searchText;
  if (searchText == null) return;
  final sub = stop.area != null
      ? 'Each opens a Maps search in ${stop.area}.'
      : 'No area is written for this stop.';
  final correct = await showModalBottomSheet<bool>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              stop.text,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'serif',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              sub,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (stop.places.length > 1)
            for (final place in stop.places)
              ListTile(
                key: Key('place-$place'),
                leading: const Icon(Icons.place_outlined),
                title: Text(place),
                onTap: () {
                  Navigator.of(sheet).pop(false);
                  handoff.openPlace(place, area: stop.area);
                },
              )
          else
            ListTile(
              key: const Key('place-as-written'),
              leading: const Icon(Icons.place_outlined),
              title: const Text('Search it as written'),
              onTap: () {
                Navigator.of(sheet).pop(false);
                handoff.openSearch(searchText: searchText, area: stop.area);
              },
            ),
          const Divider(height: 1),
          if (stop.area != null)
            ListTile(
              key: Key('just-show-me-${stop.area}'),
              leading: const Icon(Icons.map_outlined),
              title: Text('Just show me ${stop.area}'),
              onTap: () {
                Navigator.of(sheet).pop(false);
                handoff.openArea(stop.area!);
              },
            )
          else
            // The neighbours' areas, offered as search hints. The wording
            // promises a search *near* somewhere and never that the place is
            // there — nothing here has ever looked a place up.
            for (final area in stop.adjacentAreas)
              ListTile(
                key: Key('nearest-to-$area'),
                leading: const Icon(Icons.near_me_outlined),
                title: Text('nearest to $area'),
                onTap: () {
                  Navigator.of(sheet).pop(false);
                  handoff.openSearch(searchText: searchText, area: area);
                },
              ),
          ListTile(
            key: const Key('correct-this-stop'),
            leading: const Icon(Icons.edit_outlined),
            title: Text(
              stop.area == null ? 'Give it an area' : 'The area is wrong',
            ),
            onTap: () => Navigator.of(sheet).pop(true),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
  if (correct != true || !context.mounted) return;
  await _correctArea(
    context,
    ref,
    dayNumber: dayNumber,
    area: stop.area,
    wholeRun: false,
    position: stop.position,
  );
}

/// The correction picker: every area already in the plan, somewhere else, or
/// honest nothing.
///
/// [wholeRun] is the difference between tapping a heading and tapping one
/// stop's "the area is wrong" — the heading stands over a run, and correcting
/// it corrects the run.
Future<void> _correctArea(
  BuildContext context,
  WidgetRef ref, {
  required int dayNumber,
  required String? area,
  required bool wholeRun,
  required int position,
}) async {
  final theme = Theme.of(context);
  final plan = ref.read(savedItineraryProvider).value;
  final known = <String>{
    for (final day in plan?.days ?? const [])
      for (final stop in day.stops)
        if (stop.area != null) stop.area!,
  }..remove(area);

  final choice = await showModalBottomSheet<_AreaChoice>(
    context: context,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                'Where is this, really?',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'serif',
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                wholeRun
                    ? 'Every stop under this heading will search there.'
                    : 'This stop alone will search there.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (area != null)
              ListTile(
                key: Key('area-standing-$area'),
                title: Text(area),
                subtitle: const Text('what the plan said'),
                trailing: const Icon(Icons.check),
                onTap: () => Navigator.of(sheet).pop(),
              ),
            for (final other in known)
              ListTile(
                key: Key('area-choice-$other'),
                title: Text(other),
                onTap: () =>
                    Navigator.of(sheet).pop(_AreaChoice.named(other)),
              ),
            ListTile(
              key: const Key('area-somewhere-else'),
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Somewhere else…'),
              onTap: () => Navigator.of(sheet).pop(const _AreaChoice.typed()),
            ),
            ListTile(
              key: const Key('area-none'),
              leading: const Icon(Icons.block),
              title: const Text('No area — just search the words'),
              onTap: () => Navigator.of(sheet).pop(const _AreaChoice.none()),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  var answer = choice.area;
  if (choice.isTyped) {
    answer = await _askForAnArea(context, area);
    if (answer == null) return;
  }

  final actions = ref.read(dayActionsProvider);
  if (wholeRun && area != null) {
    await actions.setAreaRun(
      dayNumber: dayNumber,
      position: position,
      area: answer,
    );
  } else {
    await actions.setStopArea(
      dayNumber: dayNumber,
      position: position,
      area: answer,
    );
  }
}

Future<String?> _askForAnArea(BuildContext context, String? area) async {
  final typed = await showDialog<String>(
    context: context,
    builder: (dialog) => _AreaDialog(area: area),
  );
  if (typed == null || typed.isEmpty) return null;
  return typed;
}

/// The one-field "where is this?" dialog. It owns its controller, because a
/// dialog's future completes at the pop and the field is still on screen for
/// the dismissal frames after it -- disposing at the await is disposing a
/// controller still being read.
class _AreaDialog extends StatefulWidget {
  const _AreaDialog({required this.area});

  final String? area;

  @override
  State<_AreaDialog> createState() => _AreaDialogState();
}

class _AreaDialogState extends State<_AreaDialog> {
  late final TextEditingController _field = TextEditingController(
    text: widget.area ?? '',
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Where is this?'),
    content: TextField(
      key: const Key('area-field'),
      controller: _field,
      autofocus: true,
      decoration: const InputDecoration(hintText: 'Yanaka'),
      onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('area-save'),
        onPressed: () => Navigator.of(context).pop(_field.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}

/// What came back from the picker: an area, no area at all, or "let me type
/// one". Null is not one of them — that is the person closing the sheet.
class _AreaChoice {
  const _AreaChoice.named(this.area) : isTyped = false;
  const _AreaChoice.none() : area = null, isTyped = false;
  const _AreaChoice.typed() : area = null, isTyped = true;

  final String? area;
  final bool isTyped;
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
