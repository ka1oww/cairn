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
| `rls_probe.py` | The adversarial suite, grouped by the product decision each check defends. |
| `recursion_mechanism.py` | Checks *why* the recursion fix works, not just that it does. Needs a superuser connection: it creates a role and a database. |

## Running them

You need a Postgres 17 (Supabase provisions new projects on 17) and `pg8000`.
Any of these will do:

```sh
# whatever you already have
brew install postgresql@17 && brew services start postgresql@17

# or Supabase's own local stack, which is Postgres in Docker
supabase start        # then point CAIRN_PG_PORT at the port it prints
```

Then:

```sh
python3 -m venv .venv && .venv/bin/pip install pg8000
cd supabase/tests
CAIRN_PG_PORT=5432 CAIRN_PG_USER=postgres ../../.venv/bin/python rls_probe.py
CAIRN_PG_PORT=5432 CAIRN_PG_USER=postgres ../../.venv/bin/python recursion_mechanism.py
```

Connection settings come from `CAIRN_PG_HOST`, `CAIRN_PG_PORT`, `CAIRN_PG_USER`,
`CAIRN_PG_PASSWORD` and `CAIRN_PG_DB`, defaulting to
`127.0.0.1:5432/postgres` as `postgres`. Both scripts drop and recreate their
own database (`cairn_probe`, `cairn_owned`) every run, so point them at a
throwaway cluster and never at anything real.

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

No Supabase project exists yet, so nothing here has run against a hosted one.
These tests exercise core Postgres behaviour — the RLS engine, `auth.uid()`,
`SECURITY DEFINER` ownership, `RETURNING` against the SELECT policy — all of
which reproduce identically on a real project. They do **not** cover GoTrue
(identity linking across Apple and Google, Apple's private-relay addresses,
the name returned only on first authorization), the edge functions, R2, or
`pg_cron`. Those need the real thing.
