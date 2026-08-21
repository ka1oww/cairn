# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Backend (`supabase/`)

The backend is Supabase (Postgres: accounts, trip membership, photo index)
+ Cloudflare R2 (photo bytes). See `supabase/README.md` for the full model,
RLS rationale, free-tier limits, and setup steps -- it is the source of
truth, not this file.

Sharp edges worth knowing before touching this directory again:

- The backend is intentionally minimal: it holds only the shared photo pool
  and trip membership. The itinerary/trail/stars/notifications are computed
  on the phone and must never move server-side without a deliberate
  decision to change that.
- Migrations in `supabase/migrations/` are numbered and dependency-ordered
  -- several RLS policies are deferred to a later-numbered file because
  they reference a table (usually `trip_members`) that doesn't exist yet
  at table-creation time. Read the comments in `0003_trips.sql` /
  `0004_trip_members.sql` before reordering anything.
- No Supabase project has been created yet and no migration has been run
  against a real database (verified by inspection only -- no
  Supabase CLI/Docker/psql was available in the worktree that authored
  this). Before trusting the schema, run `supabase db push` against a
  throwaway project.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
