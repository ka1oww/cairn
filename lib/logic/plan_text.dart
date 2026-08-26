// LOGIC band (docs/architecture.md): pure functions over plain values.
//
// The plan, said back as the text a person could have pasted. This is what
// pre-fills the paste box on a re-paste: the person edits their own plan in
// their own words rather than retyping it, and reading it again merges the
// edit back in (`repaste_merge.dart`).
//
// **The format is chosen to survive its own parser**, which is the whole
// point of it — text this renders and the parser then reads must give back
// the same plan. Three rules carry that:
//
//  - A dated day is written date-first (`Mon 14 June 2027 - Tokyo`), never
//    `Day 1 - Tokyo, 14 June`. Only a date-shaped header binds a date; in a
//    `Day N` header the whole tail becomes the place and the date is lost.
//  - An undated day is written `Day N`, plus its place where it has one, so
//    an open date stays open instead of being invented on the way out.
//  - Every stop line is written with a bullet. A bullet is the one thing that
//    stops the parser reading a line as a header: an unbulleted `Ueno Park`
//    followed by a timed line is classified as a bare place name and opens a
//    new day, which empties the day it came from and strands that day's
//    photographs. `stripBullet` takes the marker off again on re-read, so the
//    stop's own text is unchanged by the round trip.
//
// A stop's time is usually already inside the text the parser gave it
// (`10:12 Train to Kyoto`, `Romancecar 9:05am`), so writing the time out again
// would both duplicate it and mangle the line. **The stored time is the
// authority**: it is written back whenever the line's own words do not carry
// that same time — a time the person set by hand in the editor, whether the
// words carry no time at all or a different one. A line reading `Lunch at
// 12pm` whose time was set to 13:00 renders as `13:00 Lunch at 12pm`, and the
// duplication is the accepted cost of not silently reverting the hand edit.
// It costs one more thing, worth knowing: that line's *words* changed, so the
// re-read is a change to the day rather than a no-op, and the wording it
// replaced is filed in the set-aside — visible and draggable back, never
// deleted, but reported as displaced when it was only reworded. Only a stop
// whose words contradict its time pays this; every other line round-trips
// untouched.
// What time a line carries is asked of the parser itself rather than guessed
// at with a pattern of our own: the two must agree, and there is only one way
// to be sure they do.
import 'package:cairn_model/cairn_model.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

import '../repositories/trip_repository.dart';

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Renders [days] as pasteable itinerary text: one header per day, one line
/// per stop, days separated by a blank line.
///
/// **Only the days.** The lines waiting in the set-aside tray are not written
/// into the text, deliberately: any heading they could sit under would read
/// to the parser as one more day, and a tray line would come back as a stop.
/// They survive a re-paste by staying in the draft instead — the tray is not
/// something the text has to carry.
String renderPlanText(List<ConfirmedDay> days) => [
  for (final day in days)
    [_header(day), for (final stop in day.stops) _stopLine(stop)].join('\n'),
].join('\n\n');

String _header(ConfirmedDay day) {
  final date = day.date;
  if (date != null) {
    final weekday = DateTime.utc(date.year, date.month, date.day).weekday;
    final head =
        '${_weekdays[weekday - 1]} ${date.day} '
        '${_months[date.month - 1]} ${date.year}';
    return day.place == null ? head : '$head - ${day.place}';
  }
  return day.place == null
      ? 'Day ${day.number}'
      : 'Day ${day.number} - ${day.place}';
}

String _stopLine(Stop stop) {
  final time = stop.time;
  final written = _timeCarriedBy(stop.text);
  final saysTheStoredTime =
      time == null ||
      (written != null &&
          written.hour == time.hour &&
          written.minute == time.minute);
  return saysTheStoredTime
      ? '$_bullet${stop.text}'
      : '$_bullet${time.iso} ${stop.text}';
}

const _bullet = '- ';

/// The time the parser would find in this line if it read it again, or null
/// for a line whose words carry none. Asked under a day header and behind the
/// bullet this renders with, because that is the only context in which the
/// parser reads a line as a stop at all.
ip.ParsedTime? _timeCarriedBy(String text) {
  final read = ip.parseItinerary('Day 1\n$_bullet$text');
  final stops = read.days.isEmpty ? const <ip.Stop>[] : read.days.first.stops;
  return stops.isEmpty ? null : stops.first.time;
}
