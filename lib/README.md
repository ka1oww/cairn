# `lib/` is the dependency map, spelled as directories

`docs/architecture.md` draws the app as bands where **a layer may only know
the layers beneath it**. Each directory here is one band, and each file's
imports are the arrows:

| Directory | Band on the map | May import |
| --- | --- | --- |
| `screens/` | SCREENS | `app_state/`, Flutter |
| `app_state/` | APP STATE | `repositories/`, the domain packages, Riverpod |
| `repositories/` | THE SEAM | `storage/`, `package:cairn_model` |
| `storage/drift/` | STORAGE (Drift store) | Drift, `package:cairn_model`, the device disk |

The DOMAIN band is not in `lib/` at all: it is the four pure-Dart packages
under `packages/`, consumed as path dependencies and never modified.

Two files sit outside the bands, deliberately:

- **`bootstrap.dart`** is the composition root. Something has to build the
  stack in dependency order — open the database, wrap it in the repository,
  bind the repository into Riverpod — and that something necessarily knows
  every layer. Confining that knowledge to one file is what keeps it out of
  all the others: `app_state/` declares `tripRepositoryProvider` as unbound,
  and only `bootstrap.dart` (and tests) may bind it.
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
