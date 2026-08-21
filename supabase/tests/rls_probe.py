"""Adversarial suite for Cairn's schema and its row-level security.

Grouped by the thing being defended rather than by table, so a failure names a
product decision rather than a policy. Run it against a throwaway Postgres 17:

    python3 supabase/tests/rls_probe.py

Read the caution in harness.As.try_run before adding a check: RLS refuses by
filtering to zero rows, not by raising, so "the statement errored" is the wrong
assertion almost every time. Assert on the state of the table afterwards.
"""

import sys

from harness import As, apply_migrations, check, make_user, recreate_db, summary

PHOTO_A = "aaaaaaaa-0000-0000-0000-000000000001"
PHOTO_B = "bbbbbbbb-0000-0000-0000-000000000001"
PHOTO_C = "cccccccc-0000-0000-0000-000000000001"


def main():
    db = recreate_db("cairn_probe")

    print("\n== the migrations apply, and re-apply ==")
    first = apply_migrations(db, label="round 1")
    second = apply_migrations(db, label="round 2")
    check(first and second, "every migration applies cleanly, twice")
    tables = db.run("select count(*) from pg_tables where schemaname = 'public'")[0][0]
    policies = db.run("select count(*) from pg_policies where schemaname = 'public'")[0][0]
    print(f"  {tables} tables, {policies} policies")

    alice = make_user(db, "Alice")
    bob = make_user(db, "Bob")
    carol = make_user(db, "Carol")
    dave = make_user(db, "Dave")
    a, b, c, d = As(db, alice), As(db, bob), As(db, carol), As(db, dave)

    # ---------------------------------------------------------------- blockers
    print("\n== the first thing the app ever does: create a trip, read its id back ==")
    status, rows = a.try_run(
        """insert into public.trips (name, created_by, timezone, country, city, start_date, end_date)
           values ('Japan', :u, 'Asia/Tokyo', 'Japan', 'Tokyo', current_date - 2, current_date + 5)
           returning id""",
        u=alice,
    )
    check(status == "ok", "INSERT INTO trips ... RETURNING id succeeds", repr(rows))
    japan = str(rows[0][0])
    check(
        bool(a.run("select 1 from public.trip_members where trip_id = :t and user_id = :u", t=japan, u=alice)),
        "and the creator is a member of the trip they started",
    )

    iceland = str(
        b.run(
            """insert into public.trips (name, created_by, timezone, start_date, end_date)
               values ('Iceland', :u, 'Atlantic/Reykjavik', current_date, current_date + 3)
               returning id""",
            u=bob,
        )[0][0]
    )

    print("\n== membership-gated reads resolve at all (the recursion) ==")
    status, rows = a.try_run("select user_id from public.trip_members where trip_id = :t", t=japan)
    check(status == "ok", "a member reads the roster with no recursion", repr(rows))
    a.run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                      content_type, byte_size, trip_day, captured_at)
           values (:id, :t, :u, 'k/a1', 'image/jpeg', 100, current_date - 2, now())""",
        id=PHOTO_A, t=japan, u=alice,
    )
    status, rows = a.try_run("select r2_object_key from public.photos where trip_id = :t", t=japan)
    check(status == "ok" and len(rows) == 1, "a member reads her own trip's photo", repr(rows))

    print("\n== isolation between trips ==")
    for who, label in ((c, "a non-member"), (b, "a member of a different trip")):
        status, rows = who.try_run("select count(*) from public.photos where trip_id = :t", t=japan)
        check(status == "ok" and rows[0][0] == 0, f"{label} sees zero photos, filtered not errored", repr(rows))
    status, rows = c.try_run("select count(*) from public.trips")
    check(status == "ok" and rows[0][0] == 0, "a non-member sees zero trips", repr(rows))

    # ------------------------------------------------------- roles are flat...
    print("\n== roles are flat: nothing to escalate to ==")
    a.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, 'JAPAN123', :u)",
          t=japan, u=alice)
    status, rows = c.try_run("select public.redeem_trip_invite('JAPAN123')")
    check(status == "ok", "Carol redeems the invite and joins", repr(rows))

    columns = [row[0] for row in db.run(
        "select column_name from information_schema.columns "
        "where table_schema = 'public' and table_name = 'trip_members'")]
    check("role" not in columns, "trip_members has no role column to promote into", f"columns={columns}")
    status, rows = c.try_run(
        "update public.trip_members set joined_at = now() where trip_id = :t and user_id = :u",
        t=japan, u=carol)
    check(status == "ok" and rows is None,
          "and no UPDATE policy at all, so any rewrite matches zero rows")

    # ------------------------------------------- ...except the starter's removal
    print("\n== the one asymmetry: the person who started the trip can remove someone ==")
    c.try_run("delete from public.trip_members where trip_id = :t and user_id = :u", t=japan, u=alice)
    check(db.run("select count(*) from public.trip_members where trip_id = :t and user_id = :u",
                 t=japan, u=alice)[0][0] == 1,
          "a plain member cannot remove someone else")

    d.run("select public.redeem_trip_invite('JAPAN123')")
    a.run("delete from public.trip_members where trip_id = :t and user_id = :u", t=japan, u=dave)
    check(db.run("select count(*) from public.trip_members where trip_id = :t and user_id = :u",
                 t=japan, u=dave)[0][0] == 0,
          "the trip's starter can remove someone")
    status, rows = d.try_run("select count(*) from public.photos where trip_id = :t", t=japan)
    check(rows[0][0] == 0, "and a removed member loses read access immediately")

    c.run("delete from public.trip_members where trip_id = :t and user_id = :u", t=japan, u=carol)
    check(db.run("select count(*) from public.trip_members where trip_id = :t and user_id = :u",
                 t=japan, u=carol)[0][0] == 0,
          "anyone can remove themselves -- leaving is not the starter's to permit")
    c.run("select public.redeem_trip_invite('JAPAN123')")

    print("\n== nobody edits anyone else's photos or placements ==")
    before = db.run("select trip_day from public.photos where id = :id", id=PHOTO_A)[0][0]
    c.try_run("update public.photos set trip_day = current_date where id = :id", id=PHOTO_A)
    check(db.run("select trip_day from public.photos where id = :id", id=PHOTO_A)[0][0] == before,
          "a co-member cannot re-place my photo")
    c.try_run("delete from public.photos where id = :id", id=PHOTO_A)
    check(db.run("select count(*) from public.photos where id = :id", id=PHOTO_A)[0][0] == 1,
          "a co-member cannot delete my photo")
    status, rows = c.try_run(
        """insert into public.photos (trip_id, contributor_id, r2_object_key, content_type, byte_size)
           values (:t, :other, 'k/forged', 'image/jpeg', 10)""", t=japan, other=alice)
    check(status == "err", "a member cannot tag a photo as someone else", repr(rows)[:80])
    status, rows = c.try_run(
        """insert into public.photos (trip_id, contributor_id, r2_object_key, content_type, byte_size)
           values (:t, :u, 'k/x', 'image/jpeg', 10)""", t=iceland, u=carol)
    check(status == "err", "and cannot insert into a trip they are not on", repr(rows)[:80])

    # ------------------------------------------------------------------- gate
    print("\n== the gate holds today shut until you have put something in it ==")
    today = db.run("select (now() at time zone 'Asia/Tokyo')::date")[0][0]
    is_open = "select public.day_page_is_open(:t, :d, :u)"
    check(db.run("select count(*) from public.day_unlocks where user_id = :u", u=alice)[0][0] == 1,
          "contributing a photo records an unlock for that day")
    check(c.run(is_open, t=japan, d=today, u=carol)[0][0] is False,
          "today is shut for a member who has contributed nothing to it")
    status, rows = c.try_run(
        "select count(*), min(captured_at) from public.photos where trip_id = :t", t=japan)
    check(status == "ok" and rows[0][0] == 1,
          "but a shut gate can still read the day's times and names -- rows are not hidden")
    c.run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                      content_type, byte_size, trip_day, captured_at)
           values (:id, :t, :u, 'k/c1', 'image/jpeg', 100, :d, now())""",
        id=PHOTO_C, t=japan, u=carol, d=today)
    check(c.run(is_open, t=japan, d=today, u=carol)[0][0] is True,
          "and contributing opens it for her at once")

    print("\n== you can delete your own photo, and the day stays open ==")
    status, _ = c.try_run("delete from public.photos where id = :id", id=PHOTO_C)
    check(status == "ok" and db.run("select count(*) from public.photos where id = :id",
                                    id=PHOTO_C)[0][0] == 0,
          "a person can delete their own photo")
    check(c.run(is_open, t=japan, d=today, u=carol)[0][0] is True,
          "the day stays open afterwards -- no re-lock")
    c.try_run("delete from public.day_unlocks where trip_id = :t and user_id = :u", t=japan, u=carol)
    check(db.run("select count(*) from public.day_unlocks where trip_id = :t and user_id = :u",
                 t=japan, u=carol)[0][0] == 1,
          "and nobody can delete the unlock, so nobody can re-lock the day")
    status, rows = d.try_run(
        "insert into public.day_unlocks (trip_id, day_date, user_id) values (:t, :d, :u)",
        t=japan, d=today, u=dave)
    check(status == "err", "nor forge one", repr(rows)[:80])

    print("\n== someone joining mid-trip sees every past day freely ==")
    d.run("select public.redeem_trip_invite('JAPAN123')")
    past = db.run("select (current_date - 2)::date")[0][0]
    check(d.run(is_open, t=japan, d=past, u=dave)[0][0] is True,
          "a member who joined today can open a day that ended before he arrived")
    check(d.run(is_open, t=japan, d=today, u=dave)[0][0] is False,
          "while today is gated for him normally")
    status, rows = d.try_run("select count(*) from public.photos where trip_id = :t", t=japan)
    check(status == "ok" and rows[0][0] == 1, "and past days' rows carry no day predicate at all")

    # ----------------------------------------------------------------- credit
    print("\n== the credit under a photo outlives the person ==")
    status, rows = d.try_run("select display_name from public.profiles where id = :u", u=alice)
    check(status == "ok" and rows and rows[0][0] == "Alice", "a co-member's name is readable", repr(rows))
    a.run("delete from public.trip_members where trip_id = :t and user_id = :u", t=japan, u=alice)
    check(db.run("select count(*) from public.photos where contributor_id = :u", u=alice)[0][0] == 1,
          "a departed member's photos stay in the pool")
    status, rows = d.try_run("select display_name from public.profiles where id = :u", u=alice)
    check(status == "ok" and rows and rows[0][0] == "Alice",
          "and their name is still readable after they leave", repr(rows))
    status, rows = b.try_run("select display_name from public.profiles where id = :u", u=alice)
    check(status == "ok" and not rows, "while an unrelated user still cannot read it", repr(rows))

    print("\n== deleting the account removes the login, not the credit ==")
    status, message = "ok", None
    try:
        db.run("delete from auth.users where id = :u", u=alice)
    except Exception as exc:  # noqa: BLE001
        status, message = "err", str(exc).splitlines()[0]
    check(status == "ok", "the auth.users row can actually be deleted at all", repr(message))
    check(db.run("select display_name from public.profiles where id = :u", u=alice)[0][0] == "Alice",
          "the profile survives as a tombstone")
    check(db.run("select count(*) from public.photos where contributor_id = :u", u=alice)[0][0] == 1,
          "the photo is still there, still credited")
    status, rows = d.try_run("select display_name from public.profiles where id = :u", u=alice)
    check(status == "ok" and rows and rows[0][0] == "Alice", "and still readable on the trip", repr(rows))
    d.try_run("delete from public.profiles where id = :u", u=alice)
    check(db.run("select count(*) from public.profiles where id = :u", u=alice)[0][0] == 1,
          "no client can delete a profile")

    # ---------------------------------------------------------------- invites
    print("\n== invites ==")
    status, rows = b.try_run("select code from public.trip_invites")
    check(status == "ok" and not rows, "an outsider cannot enumerate invite codes", repr(rows))
    status, rows = c.try_run(
        "insert into public.trip_invites (trip_id, code, created_by) values (:t, 'FLAT2345', :u)",
        t=japan, u=carol)
    check(status == "ok", "any member can mint one -- inviting is flat", repr(rows)[:80])
    before = db.run("select use_count from public.trip_invites where code = 'JAPAN123'")[0][0]
    c.run("select public.redeem_trip_invite('JAPAN123')")
    after = db.run("select use_count from public.trip_invites where code = 'JAPAN123'")[0][0]
    check(before == after, "re-redeeming a code you already used spends no use", f"{before} -> {after}")

    # ------------------------------------------------------------------ clock
    print("\n== the shared trip clock ==")
    status, rows = b.try_run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('Bad', :u, 'Nihon/Tokyo', current_date, current_date)""", u=bob)
    check(status == "err" and "unknown IANA timezone" in str(rows),
          "an invalid timezone is refused where it is written, not on eight phones later",
          repr(rows)[:100])
    c.try_run("update public.trips set timezone = 'America/New_York' where id = :t", t=japan)
    check(db.run("select timezone from public.trips where id = :t", t=japan)[0][0] == "Asia/Tokyo",
          "a member cannot retime the trip out from under everyone")
    c.try_run("delete from public.trips where id = :t", t=japan)
    check(db.run("select count(*) from public.trips where id = :t", t=japan)[0][0] == 1,
          "nor delete it, taking eight people's photos with it")

    # ------------------------------------------------------------- updated_at
    print("\n== a pull cursor can see an edit, not just an insert ==")
    missing = db.run("""
        select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r'
          and c.relname in ('profiles', 'trips', 'trip_invites', 'photos', 'day_pages')
          and not exists (select 1 from pg_attribute a
                          where a.attrelid = c.oid and a.attname = 'updated_at' and a.attnum > 0)""")
    check(not missing, "every mutable synced table has updated_at", repr(missing))
    before = db.run("select updated_at from public.photos where id = :id", id=PHOTO_A)[0][0]
    db.run("update public.photos set trip_day_is_manual = true where id = :id", id=PHOTO_A)
    after = db.run("select updated_at from public.photos where id = :id", id=PHOTO_A)[0][0]
    check(after > before, "and an edit bumps it", f"{before} -> {after}")

    # ------------------------------------------------------------- day pages
    print("\n== the four-up is gone from the day's artefact ==")
    columns = [row[0] for row in db.run(
        "select column_name from information_schema.columns "
        "where table_schema = 'public' and table_name = 'day_page_photos'")]
    check("slot" not in columns and "ordinal" in columns,
          "a page's photos are ordered by ordinal, not seated in a 1..4 slot", f"{columns}")
    constraints = db.run("""select pg_get_constraintdef(oid) from pg_constraint
                            where conrelid = 'public.day_page_photos'::regclass and contype = 'c'""")
    check(all("4" not in row[0] for row in constraints), "and carry no four-up cap", repr(constraints))

    page = str(c.run(
        """insert into public.day_pages (trip_id, page_date, r2_object_key, content_type, byte_size)
           values (:t, :d, 'pages/1.jpg', 'image/jpeg', 500) returning id""", t=japan, d=today)[0][0])
    status, rows = c.try_run(
        "insert into public.day_page_photos (day_page_id, ordinal, photo_id) values (:p, 5, :ph)",
        p=page, ph=PHOTO_A)
    check(status == "ok", "a page can list an eighth photo, or a fifth", repr(rows)[:80])

    b.run("""insert into public.photos (id, trip_id, contributor_id, r2_object_key, content_type, byte_size)
             values (:id, :t, :u, 'k/b1', 'image/jpeg', 10)""", id=PHOTO_B, t=iceland, u=bob)
    db.run("insert into public.trip_members (trip_id, user_id) values (:t, :u)", t=iceland, u=carol)
    status, rows = c.try_run(
        "insert into public.day_page_photos (day_page_id, ordinal, photo_id) values (:p, 6, :ph)",
        p=page, ph=PHOTO_B)
    check(status == "err", "but not one from another trip, even one it is also a member of",
          repr(rows)[:80])

    # ------------------------------------------------------------------- RLS
    print("\n== nothing is left open, and nothing forces RLS ==")
    unprotected = db.run("""select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                            where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity""")
    check(not unprotected, "every public table has row-level security enabled", repr(unprotected))
    forced = db.run("""select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                       where n.nspname = 'public' and c.relforcerowsecurity""")
    check(not forced, "and none forces it -- forcing re-introduces the recursion", repr(forced))

    return summary()


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
