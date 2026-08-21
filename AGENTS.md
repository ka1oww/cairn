# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- `packages/` holds standalone Dart packages (own `pubspec.yaml`, tested with `dart test`) that back the Flutter app but must stay Flutter-free — e.g. `packages/trip_moments` (notification-timing logic; see its README for why it needs no server) and `packages/itinerary_parser`. Keep new packages under this pattern rather than pulling their logic into the Flutter app directly.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
