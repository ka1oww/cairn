# Design calls — 22 August 2026

Seven calls settled so a design round could be commissioned. All follow from
[the moment](2026-08-22-the-moment.md).

## 1. The day's page is a vertical timeline
Photos down the screen in the order they happened, hour in the margin.

The division that earns the name: **the day is a timeline, the trip is a
cairn.** A day is inherently linear, and a vertical scroll is how a phone reads
a timeline. The stone metaphor is reserved for the trip as a whole, where
accumulation is the actual point.

## 2. Times show, prominently
The hour is part of the composition, not metadata in small grey text. The hours
are the point of the scattered model — "08:40 breakfast · 22:10 the walk back"
is what makes it a day rather than a folder of pictures.

The time is reliable. A pinged photo's time is known exactly because the app
took it. For imported photos, `packages/photo_day_assignment` already derives
the day from a GPS-derived timezone over EXIF, with a documented degradation
ladder for photos whose metadata has been stripped.

## 3. Each photo is credited, small and quiet
A name at roughly the weight of the timestamp. The photo is the subject; the
byline is not.

No separate username system. The display name comes from the Google or Apple
sign-in and is editable when someone joins a trip, because providers tend to
supply full legal names.

**Known defect this exposes:** the backend review found that deleting an account
would erase the name credited on that person's photos, through three restrict
foreign keys to `profiles` plus a cascade from `profiles.id` to `auth.users`.
Credited photos make that visible. The fix is inside the backend correctness
work and must land before this ships.

## 4. The shut gate shows the shape of the day, obscured
Times and names visible; images not. You can see that six moments happened and
when, but not inside them.

A gate is motivating when it tells you exactly what is behind it and how much.
An empty screen with a message reads as punishment, and a gate that hides how
much you are missing is not tempting, only obstructive.

## 5. Back camera, with a small front inset
You photograph the people you are with; a small corner frame catches your own
face, in the manner people already know from BeReal.

The back camera is the important one — the entire reason scattered timing works
is that the interrupted person photographs the others rather than themselves.
Front-only would undo it.

**Cost, stated:** both cameras at once is the one genuinely hard piece of
engineering in this app. Back-only remains an acceptable fallback now that the
camera points outward; the inset is a nice-to-have, not the mechanic.

*Later the same day the dual-camera spike dissolved this cost: "like BeReal"
turns out to mean a back-then-front sequence, not simultaneity. See
[the camera stays BeReal-shaped](2026-08-22-camera-like-bereal.md).*

## 6. The trip view: the cairn is the trip's portrait, not its front door
Drawn first, decided after. The design round solved the character problem —
stone width from the day's photo count, tint drawn from that day's own prints,
tilt from the pile, so no two days weigh the same and it never becomes a
progress bar. Today is never a stone; it hovers as a dashed outline and drops at
midnight.

But the job was wrong. Cairn already has a trip-level home in the Trail, and two
maps of the same eight days compete — a person opening to the pile must still go
somewhere else to see today's stops, which makes the pile a lobby.

**Decision: the Trail stays the front door.** The cairn becomes what the trip
turns into — the book's cover, the spine on the shelf, the share image, and the
binding-night animation as stones drop one by one.

*The cover half of this was refined by
[book round nine](2026-08-22-book-round-nine.md): the photograph is the
cover's face, and the cairn signs the foot rather than fronting it.*

## 7. Thirty-minute window, late contributions always allowed
Late photos carry their real timestamp, so a late one sits at the hour it was
actually taken and is visibly late.

No hard lockout. A lockout would leave someone permanently shut out of the
memory of a trip they were physically on, over a notification missed while
swimming. Being visibly the person who answered at 23:40 is pressure enough,
and it is funnier.

*The thirty was narrowed to two minutes on 3 September; nothing else in this
call moved, and the late path is still open till midnight. The number lives
in `captureWindow` (`lib/app_state/capture_flow.dart`), which is the only
place it is written.*

## Open
The book's page design, pending a reference the captain is supplying. One spread
per day, photos in the order they happened, digital only.

*Closed since: the reference landed and round nine drew the interior — see
[book round nine](2026-08-22-book-round-nine.md) and
[no book editor](2026-08-22-book-no-editor.md). The treatment fork itself was
settled on 23 August — see
[the book's treatment](2026-08-23-book-treatment.md).*
