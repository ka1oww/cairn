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

- The backend is intentionally minimal: it holds the shared photo pool, trip
  membership and the shared trip clock. The itinerary/trail/stars/ping
  schedule are computed on the phone and must never move server-side without
  a deliberate decision to change that.
- **Never inline a membership subquery in an RLS policy.** Every
  membership/ownership check goes through the `SECURITY DEFINER` helpers
  `is_trip_member` / `is_trip_starter` in `0004_trip_members.sql`, because a
  policy on `trip_members` that reads `trip_members` recurses infinitely and
  takes every membership-gated read in the schema down with it. For the same
  reason, never add `force row level security` to any table here -- it
  re-enables the recursion. Both directions are demonstrated by
  `supabase/tests/recursion_mechanism.py`.
- Migrations in `supabase/migrations/` are numbered and dependency-ordered.
  Only one forward reference remains, and it is irreducible: `0003_trips.sql`
  defers its own RLS policies to `0004_trip_members.sql`, because `trips` must
  exist before `trip_members` can reference it but the policies are written in
  terms of membership. Read that comment before reordering anything.
- The schema has been run, but only locally: `supabase/tests/` applies it to a
  throwaway Postgres 17 and drives it as PostgREST does. Run
  `python3 supabase/tests/rls_probe.py` (see that directory's README) after any
  change to a policy -- RLS refuses by filtering to zero rows rather than
  raising, so a change that silently opens or closes access looks identical to
  one that works until something actually queries it. **No Supabase project
  exists yet and nothing has been applied to a hosted one**; `supabase db push`
  against a throwaway project is still the gate before anything real.

## Packages

- `packages/itinerary_parser/` — pure-Dart package (no Flutter dependency) that parses pasted free-text trip plans into structured days/stops. Test with `dart test` from inside that directory; see its `README.md` for the public API, confidence semantics, and documented parsing limitations.
- `packages/trip_moments/` — pure-Dart, offline notification-timing library; see its `README.md` for why it needs no server. Test with `dart test` from inside that directory.
  - It derives its instants with multiplication and addition, not bitwise shifts, deliberately: Dart's `int` bitwise operators are 32-bit when compiled to JavaScript, so the shift form silently diverges on web while the arithmetic form is exact on every backend. `test/golden_values_test.dart` pins this -- do not "simplify" the arithmetic back to shifts.
- `packages/photo_day_assignment/` — pure-Dart package that decides which day of a trip a photo belongs to, using GPS-derived timezone over EXIF timestamps where possible (see its `README.md` for the full degradation ladder). Test with `dart test` from inside that directory.
  - It calls `timezone_finder`'s `findLocation(longitude, latitude)` -- longitude first, the opposite of the usual lat/lng convention and a standing trap when wiring up callers.

## Design and decisions

See `docs/decisions/` for the authoritative record of why the app is shaped the way it is, and `docs/design/` for the interface and design system. The central decision is recorded in `docs/decisions/2026-08-22-the-moment.md`: the daily ping is scattered per person rather than simultaneous, because a simultaneous buzz adds no value when everyone is co-located and instead prompts people to photograph themselves rather than each other.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
