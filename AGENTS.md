# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Layout

- `learning/` — throwaway demos built to make a technical decision, not the app.
  - `learning/dual-camera-spike/` decided the moment's dual capture: build back-then-front
    sequential capture, not true hardware-simultaneous dual camera, because the evidence says
    that's what BeReal itself actually does and true simultaneity has no Flutter framework
    support on either platform. See its `README.md` for the full evidence trail. One sharp edge
    worth knowing generally: `AVCaptureMultiCamSession.isMultiCamSupported` is a device-class
    flag, not a live-hardware probe -- it read `true` on the iOS Simulator during that spike's
    testing, which has no camera at all. Never treat that flag alone as proof a capture session
    will actually work, on Simulator or a real device.
- `supabase/` — the backend (see below).
- `packages/` — standalone Dart packages (own `pubspec.yaml`, tested with `dart test`) that back the Flutter app but must stay Flutter-free. Keep new packages under this pattern rather than pulling their logic into the Flutter app directly.

## The app (root `pubspec.yaml`, `lib/`, `ios/`)

The Flutter application (Riverpod for app state, Drift for the local
database). `lib/README.md` is the authority on the layout: each directory
under `lib/` is one band of `docs/architecture.md`, and which band may
import what is written there, not here.

- Drift's generated code (`lib/**/*.g.dart`) is not checked in (root
  `.gitignore`): run `dart run build_runner build` after checkout, before
  analyzing or testing the app.
- Analyze with `flutter analyze lib test` from the root. A bare
  `flutter analyze` also walks `learning/` and `packages/` -- separate
  projects with their own dependency contexts -- and reports their
  unfetched dependencies as errors.
- iOS only, deliberately: no `android/` exists and the dev machine has no
  Android SDK. The build gate is
  `flutter build ios --simulator --no-codesign`.

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
- `packages/trip_moments/` — pure-Dart, offline notification-timing library: it deals each person on a trip exactly one ping a day, as a collision-free permutation of slots over the party, reshuffled daily. See its `README.md` for the derivation and why it needs no server. Test with `dart test` from inside that directory.
  - **The party is an input, not an afterthought.** Each device derives the whole day's assignment for everyone, which is what makes the schedule collision-free offline. A derivation that hashed only the local member id (as an earlier version did) permits two people to land on the same minute and permits the party to cluster.
  - It derives its instants with multiplication and addition, not bitwise shifts, deliberately: Dart's `int` bitwise operators are 32-bit when compiled to JavaScript, so the shift form silently diverges on web while the arithmetic form is exact on every backend. `test/golden_values_test.dart` pins this -- do not "simplify" the arithmetic back to shifts. `tool/print_goldens.dart` documents the four-command VM-vs-dart2js diff that verifies it.
- `packages/cairn_model/` — pure-Dart domain model: the one vocabulary (trip, trip clock, day, stop, member, photo reference, gate) the database layer, the app's state layer and the interface are all written against. Test with `dart test` from inside that directory; its `README.md` names the decision file behind each non-obvious choice.
  - A day's clock is fixed where the day *starts* and never moves, so a photo taken after an afternoon border crossing still reads at the hour that day was on. `TripDay.sequence`'s per-day clock overrides mirror `photo_day_assignment`'s `timeZoneOverridesByDay` deliberately -- change one and the other has to follow.
- `packages/photo_day_assignment/` — pure-Dart package that decides which day of a trip a photo belongs to, using GPS-derived timezone over EXIF timestamps where possible (see its `README.md` for the full degradation ladder). Test with `dart test` from inside that directory.
  - It calls `timezone_finder`'s `findLocation(longitude, latitude)` -- longitude first, the opposite of the usual lat/lng convention and a standing trap when wiring up callers.

## Design and decisions

See `docs/decisions/` for the authoritative record of why the app is shaped the way it is, and `docs/design/` for the interface and design system. The central decision is recorded in `docs/decisions/2026-08-22-the-moment.md`: the daily ping is scattered per person rather than simultaneous, because a simultaneous buzz adds no value when everyone is co-located and instead prompts people to photograph themselves rather than each other.

`docs/architecture.md` is the dependency map: every node of the app (built or not), what each knows about, and what breaks if it changes -- read it before moving a responsibility between layers. `docs/architecture.html` is the same map as a single self-contained page for visual reading.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
