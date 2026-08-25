# Riverpod and Drift are the app's stack — 25 August 2026

This one is not a fresh call. The choice was made in code, twice over: the
learning demo argued it, the scaffold committed to it, and every slice since
has been built on it. What was missing was the record. The architecture map
had been carrying the gap as a flagged honesty note — *"validated and now
built on, not decided"* — and the root `README.md` still described the stack
as being chosen. This file closes that, and says what the choice was weighed
against so a future reader can tell a decision from a default.

## The decision

**Riverpod for app state. Drift (SQLite) for the local database.** On iOS,
Drift runs on its native backend via `sqlite3_flutter_libs` — not the demo's
wasm-and-worker detour, which existed only so the demo could run in Chrome.

## What the choice actually had to do

The app's shape decided this, not taste. The same trip is read by Today, the
Trail and the Pool at once, and a photo kept in capture has to appear in the
Pool with no wire between those two features. Underneath, the interesting
reads are relational and aggregate — a day's photos, photos per day — over
data that must survive the app being closed.

So the two halves are: **one source of truth many screens can watch**, and
**a store that both persists and answers a join**.

## State: what was rejected

| Considered | Why not |
|---|---|
| `setState` | Correct for state one widget and its subtree own, and it is still used that way here. It does not answer "three unrelated screens react to one event" without threading callbacks through the tree. |
| `provider` | Would have worked, and is simpler to learn. Riverpod wins on compile-time safety — `context.watch<T>()` can fail at runtime when the type is not above in the tree — and on `AsyncValue` for free from `FutureProvider`/`StreamProvider`, which is the exact case every screen here hits. |
| `bloc` | The heavier, more structured option: explicit events in, explicit states out. That ceremony pays for itself on a large team wanting one enforced pattern. This is one person on a passion project; the boilerplate would outweigh the guarantee. |

## Storage: what was rejected

| Considered | Why not |
|---|---|
| `sqflite` | Raw SQL strings and hand-written row mapping. Right for a schema barely worth typing; wrong for several related tables where the mapping code is the error-prone part. |
| Hive | A key-value box store with no query language. "Group photos by day" means loading everything into Dart and counting by hand. |
| Isar | A good fit for document-shaped data, and it has real queries — but not a relational join, and its maintenance position is less certain than Drift's or sqflite's, which matters for an app meant to last years. |

Drift won because the data is genuinely relational and the reads are
aggregates across that relationship, and because its typed queries catch a
wrong column or a wrong type at compile time rather than as a malformed SQL
string at runtime. Its cost is real and named below.

## The evidence

**From the learning demo (`learning/riverpod-drift-demo/`).** It was built to
be run, not pitched, and it was driven through a scripted browser rather than
merely built. Pressing "simulate a photo arriving" once updated both the Today
screen's count and the Pool tab's badge in the same frame, with no refresh
call anywhere in that codebase — the Drift stream → `StreamProvider` → widget
path is the whole mechanism, and that path is what the real app now runs on. A
reload, standing in for a relaunch, kept the write.

The demo also produced the more useful kind of evidence: a real bug. Seeding
ran in Drift's `onCreate`, whose schema-version marker was not reliably
persisted on that browser's web storage path, so a reload could seed twice and
silently double every stop. The fix moved seeding to `beforeOpen` behind an
explicit "is the table empty?" check. That is a *web* storage quirk the iOS
native path does not hit — but the lesson it leaves is the one worth keeping:
exercise the restart path before trusting persistence code.

**From the scaffold and every slice since.** The scaffold turned the app's
bands from intention into code on both libraries at once, with a disposable
proving screen over a disposable `trip_drafts` table. Everything after it is
the real evidence, because it is the real app: paste-and-confirm replaced the
proving screen and persists an itinerary that survives a relaunch; Today, the
Trail and the Pool all derive from that one saved-itinerary stream rather than
each adding a read; capture writes a `photos` row and the Pool draws it with
nothing wired between them. The schema has migrated four times against real
data (v2 dropped `trip_drafts`, v3 added photos, v4 added the trip's three
tables), so the migration path the demo explicitly did not exercise now has
been. It is proven end to end on the simulator.

## The costs, accepted with open eyes

- **Codegen.** `dart run build_runner build` after every schema or query
  change, and the generated `lib/**/*.g.dart` is not checked in — a fresh
  checkout does not analyze or test until it has been run. This is the single
  largest recurring tax and it was known before the choice.
- **Testing Drift-backed widgets is not free.** The demo said a real suite
  would need an injected database through `ProviderScope.overrides`; the app
  now does exactly that. It also found a trap the demo never could — a widget
  test over the stack must open Drift with `closeStreamsSynchronously: true`
  or teardown hangs silently at 0% CPU.
- **Neither library solves sync.** Background writes arriving from a server
  while someone is using the app is a coordination problem Riverpod and Drift
  leave entirely to us. Sync and conflict policy remains undecided, and this
  decision does not touch it.

## What this does not decide

Nothing about the backend, which is settled elsewhere (Supabase and R2, and
deliberately minimal). Nothing about sync. And no claim that either library is
the right answer for a different app — the argument above is made from this
app's shape, and it is the shape, not the library, that should be re-examined
first if this ever looks wrong.
