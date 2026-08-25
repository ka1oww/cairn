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
- The launch surface: `RootScreen` opens on the paste box until an itinerary
  is accepted into Drift, then on the trip — `TripShell`, whose tabs open on
  **Today**. Each flow's whole brain is one file in `lib/app_state/`
  (`paste_flow.dart`, `day_view.dart`, `trail_view.dart`, `pool_view.dart`,
  `capture_flow.dart`, `ping_schedule.dart`); screens render their view models
  and never import the parser or `cairn_model`.
- **The container is `lib/screens/trip_shell.dart`**: a tab per destination,
  each owning its own `Navigator` so a day page opened from the Trail
  survives a switch to Today and back. It holds all three of the design's
  destinations (Today, Trail, Pool) and no fourth: trip-level actions hang
  off the Trail's title, where the chevron opens `TripSheet` — the roster,
  the trip's live code, rename, new words, the gated delete, and the
  temporary route back to the paste box. Anything drawn but not built stays
  **absent, not disabled** — that is how the Pool waited, how leaving and
  removing wait now, and how the next one should.
- **The trip is a stored fact, and the permission model is not the app's.**
  Accepting a plan starts it (`MembershipStore.startTrip`, idempotent) and
  mints its first three-word code. Who may do what is `cairn_model`'s
  `trip_powers.dart` and nothing above it re-decides it; there is no role
  column in `trip_members` and there must never be one. A code carries no
  expiry of its own either: it dies when the trip closes, so
  `trip_invite_codes` has no expiry column and `TripInvite.standingAt` is
  *told* the close. Everything about joining is local — nothing carries a
  membership to another phone, and the join door says so rather than
  spinning.
- **The trip's three Drift tables do not re-emit for free.** `trip_facts`,
  `trip_members` and `trip_invite_codes` are read through one stream, and it
  is a `customSelect` over all three with `readsFrom` — minting a code
  changes no fact about the trip, so a stream watching `trip_facts` alone
  leaves a rotated code on screen. Writing a no-op empty companion to force
  an emit does not work; this was the bug.
- **Capture is a route, not a tab.** The only way in is the day page's one
  call to action, and only an open or a late window offers it. The camera is
  behind `CameraSource` (`lib/app_state/camera_source.dart`): a real back
  camera on a device, a *generated* PNG anywhere without one — which is what
  makes the flow walkable on the Simulator, and also means a green simulator
  run is no evidence the camera path works. Judge that on a device only.
  `NSCameraUsageDescription` is in `ios/Runner/Info.plist`; audio is off, so
  no microphone string is needed. The ping's schedule is real
  (`trip_moments`) but dealt for a stub party of one, and `NotificationEdge`
  is not implemented against iOS -- nothing actually buzzes yet.
- **A photo row is an index, not the photograph**: Drift's `photos` table
  holds the row, the frame is a file in the app's documents directory, and
  that mirrors Postgres-plus-R2 on the server on purpose. The seam over it has
  two halves on purpose -- `PhotoRepository` is the read interface the Pool was
  built against, `PhotoStore` is the Drift implementation that also owns the
  write path, and `bootstrap.dart` binds both providers to the one instance.
  Bind them to two and every test still passes while the Pool goes blank.
- **There is one day screen and no separate day detail.** Today is
  `DayPage(date:)` handed today's date; the Trail opens the same widget for
  every node, through `DayPage.planDay(n)`. Two ways in, one screen: the
  number is the only way to reach a day whose date is still open, since
  nothing here guesses a date. A second day surface is the thing to refuse in
  review. `todayProvider` derives today from the *device* date because no
  trip clock is stored yet — it is the one place that changes when one is,
  and `bootstrapApp(today:)` pins it in tests.
- The Trail draws **one node per day of the plan and no others**: a date the
  plan skips gets a `GapDay` page but never a node, because every drawing
  numbers the path over the plan's own days ("Day 4 of 8"). The winding
  geometry is the screen's identity, not decoration.
- **The Pool reads; capture writes; they meet at one store.**
  `PhotoRepository` (`lib/repositories/photo_repository.dart`) is the trip's
  photo *read* seam, and `PhotoStore` is the Drift implementation that answers
  it and owns the write path. `bootstrap.dart` binds `photoRepositoryProvider`
  and `photoStoreProvider` to the same instance — that, and nothing else, is
  what makes a captured photo appear in the Pool. Tests build a pool of a
  known shape through `bootstrapApp(photos:)`, which overrides the read side
  alone. Two rules the screen depends on: a photo's day is
  the `dayNumber` already on its `PhotoRef` — never re-derived from
  `photo_day_assignment` on read, since a person may have overridden it — and
  a day's photos are ordered by `cairn_model.DayPool`, not by the screen. A
  tile whose bytes are not on this phone is a permanent state of a pool eight
  people share, not a loading spinner.
- **The gate is one rule, written once.** `cairn_model`'s `GateState.decide`
  is it: the gate applies to the day being lived, and every day that has sealed
  is open to everyone on the trip whether they answered it or not
  (`docs/decisions/2026-08-22-grill-round-one.md` §1). `Trip.gateFor` answers
  with it for a real trip; `lib/app_state/day_gate.dart` answers with it for
  this one-phone slice, which has no roster to build a `Trip` from and so gates
  on `localMemberId` and on the photos still in the pool -- both are seams
  Phase 2 closes, and the second one has a trap the server already avoids with
  `day_unlocks` (deleting your photo must never re-shut a day you opened). The
  only other copy of the rule is `day_page_is_open` in SQL, and that one is
  deliberate (`docs/architecture.md`, invariant 2). A copy per surface is the
  thing to refuse in review. The Pool is its one live consumer today, because
  the gate withholds photographs and no other built surface draws one.
- Widget tests over the stack must open Drift with
  `closeStreamsSynchronously: true` or teardown hangs silently at 0% CPU —
  the header comment in `test/paste_confirm_flow_test.dart` explains the
  mechanism. Read it before writing any test that pumps the app. Since the
  container landed, every tab stays in the tree but the unselected ones are
  *offstage*: finders skip those by default, so a plain `find.byKey` sees
  only the tab you are standing on, and a tap only reaches it. A test that
  pumps `bootstrapApp` and then its own `ProviderScope` must key that scope
  (`UniqueKey`): Riverpod refuses to update a scope whose override count
  changed, and every new binding in `bootstrap.dart` changes it. Two more
  silent hangs, both at 0% CPU with no error: awaiting a drift *stream*
  (`watch().first`) inside `testWidgets` never completes under the faked
  clock -- read once instead (`AppDatabase.readPhotos`) -- and so does real
  file I/O, so a fake camera must write its frame synchronously.
- Fixture-writing trap: a `Day 1 - Tokyo, 14 June 2027` header does *not*
  give the day a date (the whole tail becomes the place); only a date-shaped
  header (`Mon 14 June 2027 - Tokyo`, `3/11/2027 - Tokyo`) resolves
  `ParsedDay.date`.

## Backend (`supabase/`)

The backend is Supabase (Postgres: accounts, trip membership, photo index)
+ Cloudflare R2 (photo bytes). See `supabase/README.md` for the full model,
RLS rationale, free-tier limits, and setup steps -- it is the source of
truth, not this file.

Sharp edges worth knowing before touching this directory again:

- The backend is intentionally minimal: it holds the shared photo pool, trip
  membership and the shared trip clock. The trail/stars/ping schedule are
  computed on the phone and must never move server-side without a deliberate
  decision to change that. One such decision exists: the itinerary becomes a
  *stored* shared fact that syncs to every phone
  (`docs/decisions/2026-08-22-grill-round-one.md` §2 — storing a shared fact
  is not computing on the server); nothing implements it yet, and
  `supabase/README.md` still describes the pre-decision state.
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
  - The trip's whole permission model is `src/trip_powers.dart`, as pure
    functions over `(member, startedBy, members)`. `Trip` delegates to it, and
    so does the app: the rules live in one place because two copies drift.
    Also here: `InviteCode` (two words and a number, forgiving of order and of
    one edit, over a vocabulary whose words are pairwise three edits apart) and
    `tripClosesAt` (trip end + the fourteen-day grace; the book's rule is not
    this one and never expires).
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
