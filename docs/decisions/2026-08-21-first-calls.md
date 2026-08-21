# First calls — 21 August 2026

Settled after an eight-way research pass covering competitors, the app
graveyard, frontend and backend technical review, and a synthesis.

## The book is digital only
No physical print. A digital photo book, plus the photos themselves exported to
each person's own phone.

Print-ready page geometry was proposed and dropped. A concern was raised once
that print constrains the page design and is hard to retrofit; it was heard and
overruled, and is not revisited.

## Handover puts everything on your own phone
At the end of a trip, one action saves the full-size set to your camera roll,
alongside the book.

This exists because the technical review found there was no download path at
all, and named a careless one as the single worst way this app could leak
someone's photos. Third-party hosting is also narrower than it looks: Google
closed the interface that let outside apps create shared albums in March 2025.

## The day's artefact fits however many answered
No fixed grid, no empty seats. The reasoning, in the captain's words: *"however
many answered that kind of works right? Else if not then the logic is flawed
already."* A quiet day must never read as a failure.

Superseded in shape but not in spirit by
[the moment](2026-08-22-the-moment.md) — the day page is now a timeline, which
satisfies this decision more cleanly than a variable grid would have.

## Android goes through Google's testing track
Twenty-five dollars once, up to 100 testers, and builds that do not expire.
Paid at the end of the build alongside the Apple program.

The trip includes at least one person on Android, and Apple's TestFlight cannot
reach them. Direct APK handout and excluding that person were both considered
and rejected.

## The second solo ping is cut
The original specification had two notification mechanics under a two-a-day
ceiling: the daily moment, and scattered ungated pings with no artefact.

The second is cut. It was the mechanic most exposed to the obligation
kill-risk — prompted capture during leisure, solo-addressed, no shared instant,
no payoff — and its evidential support was only ever "tolerable", never
"valuable". Cairn now interrupts once a day and never otherwise, which is the
cleanest permission ask in the app and worth more than the variety.

## The Pool is plumbing
Plain, correct and fast. Not a destination, not a place to spend design effort.

Most of it already exists: the scrolling grid is a standard component, reading
the camera roll is a standard package, and the logic deciding which day a photo
belongs to is already written and tested in `packages/photo_day_assignment`.
The genuinely missing piece is the way back out, which is the handover above.
