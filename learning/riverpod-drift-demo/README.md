# Riverpod + Drift demo

This is a **throwaway teaching app**, not a prototype of the real trip-companion app. Its only
job is to let you read and run two libraries — [Riverpod](https://riverpod.dev) (state
management) and [Drift](https://drift.simonbinder.eu) (a typed SQLite layer) — so you can decide
whether they belong in the real app, from working code instead of from a pitch.

It's one hardcoded fake trip ("Ember Team Coastal Loop"), three days, three stops per day, and a
button that fakes a photo arriving. No design work, no camera, no networking, no auth. Plain
Material widgets throughout, on purpose.

## 1. What problem each library solves

**The real app's actual shape:** the same trip data is read by the Today screen, the Trail
screen, and the Pool screen at the same time. When a photo finishes uploading, all three need to
update — Today's "N photos today" line, a badge somewhere in the Pool tab, and possibly a Trail
marker. None of those screens should need to know the others exist.

**Riverpod** solves the "many screens, one source of truth" half of that. A provider holds (or
watches) one piece of state; any number of widgets can `ref.watch()` it; when the state changes,
every widget watching it rebuilds, automatically, with no manual wiring between the write and
the reads. The alternative — passing a callback down through every widget that needs to know, or
reaching for a global singleton and calling `setState` on whichever widgets happen to be mounted
— is exactly the kind of spaghetti that makes "why did the Pool badge not update" bugs common in
apps that grow past a screen or two.

**Drift** solves the "the app was closed" half. `sqflite` alone gives you raw SQL strings and
manual row-to-object mapping; a plain JSON file gives you no querying at all. Drift gives you a
typed SQLite database — tables as Dart classes, generated typed row classes, and compile-checked
queries — that happens to also support real joins and aggregates, not just "get all rows and
filter in Dart." That distinction is the whole argument for Drift over a key-value store like
Hive or Isar: "photos per day" is one query here (see `watchPhotoCountsPerDay` in
`lib/data/database.dart`), and would be a manual loop-and-tally over every photo in a
document/object store.

**Where they meet:** a Drift query returns a `Stream`; a Riverpod `StreamProvider` wraps that
stream; a widget `ref.watch()`s the provider. Writing a row to the database is enough to update
every screen watching a query that touches that table — no manual refresh call anywhere in this
codebase. That wiring is the actual thing worth evaluating; the rest of this demo exists to make
it visible.

## 2. Read these files in this order

1. **`lib/data/database.dart`** — the three tables (`Trips`, `Stops`, `Photos`), and every query,
   including the plain "get all stops" query and the join+`GROUP BY` aggregate query
   (`watchPhotoCountsPerDay`). Read `_openConnection()` at the bottom to see the one line that
   differs between web and native platforms — everything above it is platform-agnostic.
2. **`lib/providers/trip_providers.dart`** — the seam between Drift and Riverpod. Every provider
   here is a one-line wrapper around a database query; the interesting part is the comment on
   `todayPhotoCountProvider` explaining why watching it from two unrelated widgets is enough to
   keep them in sync.
3. **`lib/main.dart`** — `ProviderScope` at the root, and the bottom-nav `Consumer` that renders
   the Pool badge. Notice `TripHome` is a plain `StatefulWidget`, not Riverpod-managed — the
   currently-selected tab is local UI state nobody else cares about, so it doesn't belong in a
   provider. Not everything needs to be global state.
4. **`lib/screens/today_screen.dart`** — the "N photos today" line, the add-photo button (the
   entire write path is one line, `addTodaysPhoto(ref)`), and `TripTipCard`, a self-contained
   example of the loading/data/error pattern for a `FutureProvider`.
5. **`lib/screens/pool_screen.dart`** — the other end of the sync: the total-photos badge and a
   small per-day breakdown rendered from the join/aggregate query. Compare this file's simplicity
   to how you'd fetch "photo counts per day" out of Hive.

`lib/screens/trail_screen.dart` is a sixth file, included mainly as a contrast: it lists stops
using a plain `FutureProvider` with no aggregation, to show what querying looks like when you
*don't* need a join.

## 3. How to run it

Flutter isn't installed globally as part of this repo; install it once, then:

```sh
cd learning/riverpod-drift-demo
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # generates lib/data/database.g.dart
flutter run -d chrome
```

Codegen (`build_runner`) has to run once before the app builds, and again any time you change a
table or add a query in `database.dart` — that's the Drift-specific cost mentioned in section 5
below. `flutter analyze` and `flutter test` both pass against the checked-in code without
touching anything else.

### Web-specific setup this repo already did for you

Drift on web needs two extra files sitting in `web/`, both already committed here:

- **`web/sqlite3.wasm`** — a WebAssembly build of SQLite, downloaded from the `sqlite3` Dart
  package's GitHub releases (there's no pub.dev postinstall step that fetches this automatically).
- **`web/drift_worker.js`** — a prebuilt worker script, copied from the installed `drift` package
  (`drift-<version>/drift_worker.js`) that runs the actual database off the UI thread.

If you ever bump the `drift`/`sqlite3` package versions, re-fetch both files to match — a
mismatched `sqlite3.wasm` version is the most likely cause of a web-only "failed to open
database" error that doesn't reproduce on native platforms.

**This is a demo-only detour.** The real app, targeting iOS, will use Drift's native SQLite
backend (via `sqlite3_flutter_libs`, already a dependency here) instead of the wasm/worker pair —
no `web/` files, no `DriftWebOptions`, just a native file on disk. The only code that differs
between the two is the few lines inside `_openConnection()` in `database.dart`; every table
definition and every query is identical on both platforms.

### `flutter doctor` output (captured on this machine)

```
[✓] Flutter (Channel stable, 3.47.1, on macOS 26.3.1 25D2128 darwin-arm64, locale en-US) [124ms]
    • Flutter version 3.47.1 on channel stable at /opt/homebrew/share/flutter
    • Upstream repository https://github.com/flutter/flutter.git
    • Framework revision 6655482ec0 (25 hours ago), 2026-08-19 10:07:23 -0700
    • Engine revision 5d53178869
    • Dart version 3.13.1
    • DevTools version 2.60.0

[✗] Android toolchain - develop for Android devices [43ms]
    ✗ Unable to locate Android SDK.
      (not installed on this machine — irrelevant to this demo)

[!] Xcode - develop for iOS and macOS [53ms]
    ✗ Xcode installation is incomplete; a full installation is necessary for iOS and macOS development.
      (deliberately not installed — see the task brief; iOS is out of scope for this demo)
    ! CocoaPods not installed.

[✓] Chrome - develop for the web [21ms]
    • Chrome at /Applications/Google Chrome.app/Contents/MacOS/Google Chrome

[✓] Connected device (2 available) [115ms]
    • macOS (desktop) • macos  • darwin-arm64   • macOS 26.3.1 25D2128 darwin-arm64
    • Chrome (web)    • chrome • web-javascript • Google Chrome 151.0.7922.169

[✓] Network resources [1,710ms]
    • All expected network resources are available.

! Doctor found issues in 2 categories.
```

The two failing categories (Android, Xcode) are expected and out of scope — this demo only
targets Chrome, which reports clean.

### What was actually verified running

The app was launched in Chrome, and driven through `chrome-devtools-axi` (scripted browser
control, not just a build check):

- Fresh load seeds one trip, three stops for "today," and shows **"0 photos today"** with a
  matching (hidden, since it's zero) Pool badge.
- Pressing **"Simulate a photo arriving"** once updated **both** the Today screen's photo count
  (`0 photos today` → `1 photo today`) **and** the Pool tab's bottom-navigation badge (`1`) in
  the same frame, confirmed via before/after screenshots.
- A full page reload (equivalent to quitting and relaunching) after that press still showed
  **"1 photo today"** and the Pool badge still **"1"** — the write survived a restart, through
  IndexedDB-backed Drift, with the seed logic correctly *not* re-inserting the fake trip a second
  time.
- The trip-tip card correctly showed a loading spinner, then either a tip or the simulated error
  text, exercising all three `AsyncValue` branches.

One real bug surfaced and was fixed during this process: the initial seeding logic ran inside
Drift's `onCreate` migration callback, which is documented to fire only the first time a database
is created. On this browser's web storage path (`WasmStorageImplementation.sharedIndexedDb`,
used because this Chrome lacks `SharedArrayBuffer`/nested-worker support), the schema-version
marker `onCreate` relies on wasn't reliably persisted, so a page reload could re-trigger it and
insert the seed trip a second time, silently doubling every stop. The fix (visible in
`AppDatabase.migration` in `database.dart`) moved seeding into `beforeOpen`, guarded by an
explicit "is the trips table actually empty?" check — a check that can't lie regardless of how
the version marker behaves. This is exactly the kind of platform-specific storage quirk worth
knowing about before shipping Drift on web; it does not affect the native path the real app will
use.

## 4. What the alternatives were, honestly

### State management: `setState` / `provider` / `bloc` / Riverpod

- **`setState`** is correct for state that belongs to exactly one widget and its own subtree —
  a text field's focus state, whether a card is expanded. It does not scale to "three unrelated
  screens need to react to one event" without threading callbacks through the widget tree, which
  gets unmanageable fast. If the real app only ever needed local per-screen state, `setState`
  would be the right, boring answer, and adding Riverpod would be over-engineering.
- **`provider`** (the package Riverpod is the spiritual successor to) solves the same
  cross-widget sharing problem and is simpler to learn — no code generation, no separate
  "provider" vs "consumer" API surface. It would have been a perfectly reasonable choice here.
  The reasons to prefer Riverpod over it: compile-time safety (provider's `context.watch<T>()` can
  fail at runtime if the type isn't found above in the tree; Riverpod's providers are checked at
  the provider-definition level), and better ergonomics for exactly the async-loading case this
  demo shows (`FutureProvider`/`StreamProvider` giving you `AsyncValue` for free, versus manually
  wrapping a `ChangeNotifier` around a `Future` yourself in plain `provider`).
- **`bloc`** is the heavier, more structured option — explicit events in, explicit states out,
  which pays off in large teams that want a single enforced pattern for "how state changes
  happen" and strong testability guarantees. For an app this size, bloc's ceremony (separate
  event classes, state classes, and a bloc class per feature) would be more boilerplate than the
  problem justifies. If the real app grows a large team or needs strict architectural rules
  enforced by the type system, bloc's structure becomes worth its cost; it likely isn't yet.

### Local storage: `sqflite` / Isar / Hive / Drift

- **`sqflite`** is "just SQLite" — you write raw SQL strings and manually map `Map<String,
  dynamic>` rows to Dart objects yourself. It is lighter-weight than Drift (no code generation
  step) and would be the right call for a schema so simple it's barely worth typing — a single
  key-value settings table, say. For three related tables with a join query, hand-writing and
  maintaining that mapping code by hand is exactly the error-prone busywork Drift's code
  generation exists to remove.
- **Isar** is a fast, purpose-built NoSQL object database for Flutter, with a nicer local-first
  API than Hive and solid query support (including some filtering/sorting that goes beyond plain
  key lookups). It would be a fine choice if the real app's data were naturally
  document-shaped — one photo album blob, one settings object — and never needed a true relational
  join. It is not a good fit for "photo counts grouped by day joined through stops," which is
  precisely the kind of query this demo exists to show working. Isar is also currently in a
  more uncertain maintenance position than Drift or sqflite, which matters for a multi-year app.
- **Hive** is the simplest of the three: a fast, unencrypted-by-default key-value box store, no
  query language at all. It's the right choice for pure caching or settings persistence where you
  always know the key you want. It has no answer for "group photos by day" beyond loading
  everything into Dart and counting by hand, which is the exact cost this demo's aggregate query
  was written to make visible.
- **Drift** won here because the real app's data is genuinely relational (a trip has stops, stops
  have photos, and the interesting reads are aggregates across that relationship), and because
  its typed query builder catches mistakes (wrong column, wrong type) at compile time instead of
  at runtime with a malformed SQL string. The cost — build_runner codegen — is real and is the
  first thing listed as a limitation below.

## 5. What this demo does NOT show

- **Code generation cost in practice.** `build_runner` has to run after every schema or query
  change, and on a larger app it gets noticeably slower as more `@DriftDatabase`/generated files
  accumulate. This demo's schema is three tables and never had to iterate on it under time
  pressure — that's not representative of what a real feature branch feels like.
- **Testing.** There's exactly one trivial widget test (`test/widget_test.dart`), checked in
  mainly to prove a `ProviderScope`-wrapped, Drift-backed widget tree is testable with ordinary
  Flutter tooling at all. It deliberately avoids asserting on anything that depends on the
  database resolving, because opening a native SQLite connection inside `flutter test`'s host
  process isn't guaranteed to finish within a fixed number of pumps — a real test suite would
  need an explicit fake/in-memory `AppDatabase` injected via `ProviderScope.overrides` to test
  Drift-backed widgets reliably and fast, which this demo doesn't build.
- **Schema migrations.** `schemaVersion` is hardcoded to `1` and `migration` only has an
  `onCreate`/`beforeOpen` path. A real app will eventually need to add a column or table against
  data that already exists on someone's phone; Drift supports that (`MigrationStrategy.onUpgrade`,
  step-by-step migrations, `drift_dev`'s schema verification tooling), but none of it is exercised
  here.
- **The onCreate-timing bug described in section 3.** It's fixed, but it's worth internalizing as
  a category of risk: web storage backends for Drift/sqlite3 have quirks native SQLite does not,
  and "works when I click through it once" is not the same as "works." The real app's native-only
  iOS target won't hit this specific issue, but it's a reminder to actually exercise the restart
  path, not just the happy path, before trusting persistence code.
- **Concurrent writes / conflict handling.** This demo has exactly one client writing to the
  database. The real app will eventually sync photos from a server in the background while the
  user is also interacting locally; neither Riverpod nor Drift solve that coordination problem for
  you, and nothing here demonstrates what that looks like.
