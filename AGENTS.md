# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Layout

- `learning/` — throwaway demos built to make a technical decision, not the app.
- `supabase/` — the backend (see below).
- `packages/` — standalone Dart packages (own `pubspec.yaml`, tested with `dart test`) that back the Flutter app but must stay Flutter-free. Keep new packages under this pattern rather than pulling their logic into the Flutter app directly.

## Backend (`supabase/`)

The backend is Supabase (Postgres: accounts, trip membership, photo index)
+ Cloudflare R2 (photo bytes). See `supabase/README.md` for the full model,
RLS rationale, free-tier limits, and setup steps -- it is the source of
truth, not this file.

Sharp edges worth knowing before touching this directory again:

- The backend is intentionally minimal: it holds only the shared photo pool
  and trip membership. The itinerary/trail/stars/notifications are computed
  on the phone and must never move server-side without a deliberate
  decision to change that.
- Migrations in `supabase/migrations/` are numbered and dependency-ordered
  -- several RLS policies are deferred to a later-numbered file because
  they reference a table (usually `trip_members`) that doesn't exist yet
  at table-creation time. Read the comments in `0003_trips.sql` /
  `0004_trip_members.sql` before reordering anything.
- No Supabase project has been created yet and no migration has been run
  against a real database (verified by inspection only -- no
  Supabase CLI/Docker/psql was available in the worktree that authored
  this). Before trusting the schema, run `supabase db push` against a
  throwaway project.

## Packages

- `packages/itinerary_parser/` — pure-Dart package (no Flutter dependency) that parses pasted free-text trip plans into structured days/stops. Test with `dart test` from inside that directory; see its `README.md` for the public API, confidence semantics, and documented parsing limitations.
- `packages/trip_moments/` — pure-Dart, offline notification-timing library; see its `README.md` for why it needs no server. Test with `dart test` from inside that directory.
  - It derives its instants with multiplication and addition, not bitwise shifts, deliberately: Dart's `int` bitwise operators are 32-bit when compiled to JavaScript, so the shift form silently diverges on web while the arithmetic form is exact on every backend. `test/golden_values_test.dart` pins this -- do not "simplify" the arithmetic back to shifts.
- `packages/cairn_model/` — pure-Dart domain model: the one vocabulary (trip, trip clock, day, stop, member, photo reference, gate) the database layer, the app's state layer and the interface are all written against. Test with `dart test` from inside that directory; its `README.md` names the decision file behind each non-obvious choice.
  - A day's clock is fixed where the day *starts* and never moves, so a photo taken after an afternoon border crossing still reads at the hour that day was on. `TripDay.sequence`'s per-day clock overrides mirror `photo_day_assignment`'s `timeZoneOverridesByDay` deliberately -- change one and the other has to follow.
- `packages/photo_day_assignment/` — pure-Dart package that decides which day of a trip a photo belongs to, using GPS-derived timezone over EXIF timestamps where possible (see its `README.md` for the full degradation ladder). Test with `dart test` from inside that directory.
  - It calls `timezone_finder`'s `findLocation(longitude, latitude)` -- longitude first, the opposite of the usual lat/lng convention and a standing trap when wiring up callers.

## Design and decisions

See `docs/decisions/` for the authoritative record of why the app is shaped the way it is, and `docs/design/` for the interface and design system. The central decision is recorded in `docs/decisions/2026-08-22-the-moment.md`: the daily ping is scattered per person rather than simultaneous, because a simultaneous buzz adds no value when everyone is co-located and instead prompts people to photograph themselves rather than each other.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
