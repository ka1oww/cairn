# Running the schema, rather than reading it

Row-level security is a runtime property. The first version of this schema read
correctly, applied cleanly, and then aborted every membership-gated query the
moment a real client ran one — a policy on `trip_members` whose `USING` clause
read `trip_members`, so Postgres re-applied the policy to its own subquery and
gave up with `infinite recursion detected in policy for relation
"trip_members"`. Careful inspection cannot find that. Two minutes of a running
database can.

So these are not unit tests in any interesting sense. They are the answer to
"does a real, unprivileged user actually get what the policies say they get",
which is a question only Postgres can answer.

| File | What it is |
| --- | --- |
| `supabase_env.sql` | The parts of a fresh Supabase project the migrations touch: the `anon`/`authenticated`/`service_role` roles, an `auth.users` table, and `auth.uid()`. Nothing else. |
| `harness.py` | Applies the migrations and issues statements the way PostgREST does — `set local role authenticated` plus the JWT claims GUC, inside a transaction. |
| `rls_probe.py` | The adversarial suite, grouped by the product decision each check defends. It also reads `packages/cairn_model/lib/src/` directly — the invite vocabulary and the grace after a trip exist on both sides of the phone/server seam, and comparing them is the only way this file can notice one of the two drifting. The itinerary sections are the same idea one level up: the merge rule is written both here and in `lib/repositories/itinerary_sync.dart`, and what these checks pin is that the SQL half behaves the way the Dart half assumes. |
| `recursion_mechanism.py` | Checks *why* the recursion fix works, not just that it does. Needs a superuser connection: it creates a role and a database. |

## Running them

You need a Postgres 17 (Supabase provisions new projects on 17) and `pg8000`.
Either of these will do:

```sh
# Homebrew -- note the superuser is your login name, not "postgres"
brew install postgresql@17 && brew services start postgresql@17

# or Supabase's own local stack, which is Postgres in Docker, superuser "postgres"
supabase start        # then point CAIRN_PG_PORT at the port it prints
```

Then:

```sh
python3 -m venv .venv && .venv/bin/pip install pg8000
cd supabase/tests
export CAIRN_PG_HOST=127.0.0.1 CAIRN_PG_PORT=5432
export CAIRN_PG_USER="$(whoami)"     # Homebrew; use "postgres" for Docker/Supabase
../../.venv/bin/python rls_probe.py
../../.venv/bin/python recursion_mechanism.py
```

Connection settings come from `CAIRN_PG_HOST`, `CAIRN_PG_PORT`, `CAIRN_PG_USER`,
`CAIRN_PG_PASSWORD` and `CAIRN_PG_DB`, defaulting to `127.0.0.1:5432/postgres`
as `postgres`.

**That default is wrong on a Homebrew cluster**, and the way it fails is worth
knowing, because it looks like a broken test rather than a wrong username:
`brew install postgresql@17` creates exactly one superuser, named after your
macOS login, and no role called `postgres` at all. Connecting without setting
`CAIRN_PG_USER` therefore dies at the first line with `role "postgres" does not
exist`. Both scripts need that superuser: they create and drop databases, and
`recursion_mechanism.py` also creates a role.

Both scripts drop and recreate their own database (`cairn_probe`,
`cairn_owned`) every run, so point them at a throwaway cluster and never at
anything real.

## The trap to know about before adding a check

**Row-level security refuses by filtering, not by raising.** A `SELECT`,
`UPDATE` or `DELETE` you are not allowed to perform returns zero rows and no
error. Only `INSERT` (and an `UPDATE`'s `WITH CHECK`) raises.

This matters more than it sounds. While the recursion was live, a probe that
asserted "a non-member's insert is rejected" *passed* — because the statement
aborted on the recursion before any policy was consulted. It was testing
nothing. Assert on the state of the table afterwards, not on whether a
statement threw.

## What this does not cover

Nothing here runs against the hosted project, and that is deliberate rather
than pending. All ten migrations are applied there, but a single anonymous
account cannot pose as the eight adversaries these checks need, so no RLS
*refusal* has ever been observed on the hosted project — only the permitted
paths (`../README.md`, "What the hosted project has actually done"). These
tests exercise core Postgres behaviour — the RLS engine, `auth.uid()`,
`SECURITY DEFINER` ownership, `RETURNING` against the SELECT policy — all of
which reproduce identically on a real project. They do **not** cover GoTrue
(identity linking across Apple and Google, Apple's private-relay addresses,
the name returned only on first authorization), the edge functions, R2, or
`pg_cron`. Those need the real thing.
