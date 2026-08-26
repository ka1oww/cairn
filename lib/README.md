# `lib/` is the dependency map, spelled as directories

`docs/architecture.md` draws the app as bands where **a layer may only know
the layers beneath it**. Each directory here is one band, and each file's
imports are the arrows:

| Directory | Band on the map | May import |
| --- | --- | --- |
| `screens/` | SCREENS | `app_state/`, Flutter |
| `app_state/` | APP STATE | `repositories/`, the domain packages, Riverpod, and the platform edges it drives |
| `logic/` | LOGIC — pure decision cores inside app state's reach | `repositories/` value types, the domain packages; no Flutter, no Riverpod, no IO. Called by `app_state/` (and tests), never by `screens/` |
| `repositories/` | THE SEAM | `storage/`, `package:cairn_model` |
| `storage/drift/` | STORAGE (Drift store) | Drift, `package:cairn_model`, the device disk |

The DOMAIN band is not in `lib/` at all: it is the four pure-Dart packages
under `packages/`, consumed as path dependencies and never modified.

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
- **`main.dart`** only calls `bootstrap.dart`.

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
  `ping_schedule.dart` owns the notification edge. That is the map's own
  shape — the edges are drawn beside the app-state band, and "platform glue"
  is an app-state node — so the rule to check in review is the one above it:
  no screen ever names a plugin. Each edge is an interface with a real
  implementation and a test one, so nothing above it needs a device to run.
