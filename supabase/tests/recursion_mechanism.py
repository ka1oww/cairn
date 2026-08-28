"""Why the membership policies cannot recurse -- checked, not asserted.

The claim in 0004_trip_members.sql is that `is_trip_member` is safe inside
trip_members' own policy because a SECURITY DEFINER function runs as the
function's owner, and a table's owner is exempt from that table's row-level
security unless the table is marked FORCE ROW LEVEL SECURITY. If that is really
the mechanism then two things must be true, and this file checks both:

  1. It must still hold when the owner is an ordinary role -- not a superuser,
     not BYPASSRLS. Otherwise the fix would only be working because the test
     harness happens to run as postgres, and would break on a project where it
     does not.
  2. Turning FORCE ROW LEVEL SECURITY on must bring the recursion straight back.
     If it does not, the explanation is wrong even though the code works.

Needs a superuser connection, because it creates a role and a database.

    python3 supabase/tests/recursion_mechanism.py
"""

import sys

import pg8000.native as pg

from harness import (
    As, HOST, PORT, apply_migrations, check, connect, ensure_api_roles, make_user, summary,
)

OWNER = "cairn_owner"
OWNER_PASSWORD = "probe-only-not-a-secret"
DB = "cairn_owned"


def main():
    admin = connect()
    ensure_api_roles(admin)
    admin.run(f"drop database if exists {DB} with (force)")
    admin.run(f"drop role if exists {OWNER}")
    admin.run(
        f"create role {OWNER} login password '{OWNER_PASSWORD}' "
        f"nosuperuser nocreatedb nobypassrls"
    )
    admin.run(f"create database {DB} owner {OWNER}")
    admin.close()

    # The auth schema belongs to the platform, not to us, so bootstrap it as
    # the superuser and hand the owner role only what a migration needs.
    boot = connect(DB)
    boot.run(open(__file__.replace("recursion_mechanism.py", "supabase_env.sql")).read())
    boot.run(f"grant all on schema public to {OWNER}")
    boot.run(f"grant all on schema auth to {OWNER}")
    boot.run(f"grant all on auth.users to {OWNER}")
    # Supabase's postgres role is a member of authenticated and can SET ROLE to it.
    boot.run(f"grant authenticated to {OWNER}")
    boot.close()

    db = pg.Connection(OWNER, password=OWNER_PASSWORD, host=HOST, port=PORT, database=DB)
    print(f"  applying every migration as {OWNER}:")
    check(apply_migrations(db, label="owned"), "the schema applies as an ordinary table-owner role")
    # Supabase grants the API roles table privileges; RLS, not GRANT, is the gate.
    db.run("grant all on all tables in schema public to anon, authenticated, service_role")
    db.run("grant execute on all functions in schema public to anon, authenticated, service_role")

    owners = db.run("select proname, pg_get_userbyid(proowner) from pg_proc "
                    "where proname in ('is_trip_member', 'is_trip_starter') order by proname")
    check(all(row[1] == OWNER for row in owners), "the helpers are owned by that role", repr(owners))
    check(db.run("select rolbypassrls from pg_roles where rolname = :r", r=OWNER)[0][0] is False,
          "which has no BYPASSRLS -- so only ownership can be exempting the body")

    alice, bob = make_user(db, "Alice"), make_user(db, "Bob")
    a, b = As(db, alice), As(db, bob)
    trip = str(a.run("""insert into public.trips (name, created_by, timezone, start_date, end_date)
                        values ('Japan', :u, 'Asia/Tokyo', current_date, current_date + 3)
                        returning id""", u=alice)[0][0])
    a.run("""insert into public.photos (trip_id, contributor_id, r2_object_key,
                                        content_type, byte_size, day_number, trip_day)
             values (:t, :u, 'k/1', 'image/jpeg', 10, 1, current_date)""", t=trip, u=alice)

    print("\n  with ownership doing the work:")
    status, rows = a.try_run("select user_id from public.trip_members where trip_id = :t", t=trip)
    check(status == "ok", "the roster read resolves", repr(rows))
    status, rows = b.try_run("select count(*) from public.photos")
    check(status == "ok" and rows[0][0] == 0, "and a non-member is still filtered to zero", repr(rows))

    print("\n  now forcing RLS on trip_members, which the migration warns against:")
    db.run("alter table public.trip_members force row level security")
    status, message = a.try_run("select user_id from public.trip_members where trip_id = :t", t=trip)
    check(status == "err" and ("infinite recursion" in str(message) or "stack depth" in str(message)),
          "the recursion comes straight back, so ownership really was the mechanism",
          str(message)[:110])

    db.run("alter table public.trip_members no force row level security")
    status, rows = a.try_run("select user_id from public.trip_members where trip_id = :t", t=trip)
    check(status == "ok", "and un-forcing restores it", repr(rows))

    return summary()


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
