# `lib/` is the dependency map, spelled as directories

`docs/architecture.md` draws the app as bands where **a layer may only know
the layers beneath it**. Each directory here is one band, and each file's
imports are the arrows:

| Directory | Band on the map | May import |
| --- | --- | --- |
| `screens/` | SCREENS | `app_state/`, Flutter |
| `app_state/` | APP STATE | `logic/`, `repositories/`, the domain packages, Riverpod, and the platform edges it drives |
| `logic/` | LOGIC — pure decision cores inside app state's reach | `repositories/` value types, the domain packages; no Flutter, no Riverpod, no IO. Called by `app_state/` (and tests), never by `screens/` |
| `repositories/` | THE SEAM | `storage/`, `package:cairn_model` |
| `storage/drift/` | STORAGE (Drift store) | Drift, `package:cairn_model`, the device disk |
| `storage/remote/` | STORAGE (Supabase/R2 adapter) | `package:http`, `package:cairn_model`, the network, and — for the session vault alone (`gotrue_sessions.dart`) — `package:path_provider` and the device disk |

`storage/`'s two directories are peers and neither imports the other. The
seam above is the only layer that knows both exist — that is what
`repositories/itinerary_sync.dart` is, and why it lives there rather than in
either store. **Nothing outside `storage/remote/` may import an HTTP or
Supabase symbol**, and **nothing anywhere may hold a secret**: the project URL
and the publishable anon key are `--dart-define`s that default to the hosted
project (`SharedFactsConfig.fromEnvironment`), which is why an ordinary build
reaches it and a build told `CAIRN_SUPABASE_URL=` has no backend at all. The
anon key is publishable by design and belongs in the repository; the
service-role key and the database password never do.

The DOMAIN band is not in `lib/` at all: it is the five pure-Dart packages
under `packages/`, consumed as path dependencies and never modified. Four are
the domain proper; the fifth, `plan_extraction`, is the file-import band's
contract — bytes in, honest lines of plan text out — and the one place a new
importable format is implemented.

`logic/` is the youngest band and the narrowest: pure functions over plain
values, for a rule that is the app's rather than the domain's but has no
business knowing about Riverpod, a repository or a widget. It sits beside the
domain packages on the map — everything above may import it, it imports
nothing above itself — and a file that ends up needing `ref`, a store or
`BuildContext` belongs in `app_state/` instead. It exists because the
re-paste's merge rule (`logic/repaste_merge.dart`) and the plan-as-text
rendering it reads back (`logic/plan_text.dart`) have to be readable and
testable on their own.

Two files sit outside the bands, deliberately:

- **`bootstrap.dart`** is the composition root. Something has to build the
  stack in dependency order — open the database, wrap it in the repository,
  bind the repository into Riverpod — and that something necessarily knows
  every layer. Confining that knowledge to one file is what keeps it out of
  all the others: `app_state/` declares `tripRepositoryProvider`,
  `photoRepositoryProvider` and `membershipRepositoryProvider` as unbound —
  each throws if read — and only `bootstrap.dart` (and tests) may bind them.
  Two of those seams have a write half as well (`photoStoreProvider`,
  `membershipStoreProvider`), and the app must bind each pair to the *same*
  object; binding them apart is how a captured photo or a renamed trip
  silently stops reaching the screen that reads it.
- **`main.dart`** imports nothing but `bootstrap.dart`. What it holds is an
  order, not logic: it resolves who this phone is signed in as *before* it
  builds the app, so nothing is ever credited to the offline stand-in and then
  re-credited (the file's own header says why).

## Where the framework bends the map, written down

- **Screens import `flutter_riverpod` directly** (`ConsumerWidget`,
  `WidgetRef`). The map's arrow is screens → app state; Riverpod's idiom puts
  its own widget base classes inside the screen files. This is treated as
  framework plumbing, not an arrow: the rule that matters — screens name no
  repository, no store, no SQL, nothing below `app_state/` — holds, and is the
  thing to check in review.
- **`app_state/` re-exports nothing from below.** A screen that needs a type
  from the seam is a design smell; today none does.
- **The platform edges are reached from `app_state/`, not from screens.**
  `camera_source.dart` imports `package:camera` and `package:path_provider`;
  `ping_schedule.dart` owns the notification edge; `file_picker_edge.dart`
  owns the document picker the paste box's import pill opens. That is the
  map's own shape — the edges are drawn beside the app-state band, and
  "platform glue" is an app-state node — so the rule to check in review is the
  one above it: no screen ever names a plugin. Each edge is an interface with
  a real implementation and a test one, so nothing above it needs a device to run.
