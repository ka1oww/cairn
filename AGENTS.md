# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- `packages/` holds standalone, publish-agnostic Dart packages (own `pubspec.yaml`, `dart test`, **no Flutter dependency**) — logic that doesn't need Flutter shouldn't carry it. Each package stays self-contained; work inside one shouldn't reach into another.
- `packages/photo_day_assignment/`: decides which trip day a photo belongs to via a GPS→timezone→local-time ladder (never trusts the bare, timezone-less EXIF timestamp alone). See its README for the ladder, the offline coordinate→timezone package it uses (`timezone_finder`, on top of `timezone`'s `latest_all` tzdb), and — read this before reusing it elsewhere — the "What this cannot do" section.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
