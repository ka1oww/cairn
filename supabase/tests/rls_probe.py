"""Adversarial suite for Cairn's schema and its row-level security.

Grouped by the thing being defended rather than by table, so a failure names a
product decision rather than a policy. Run it against a throwaway Postgres 17:

    python3 supabase/tests/rls_probe.py

Read the caution in harness.As.try_run before adding a check: RLS refuses by
filtering to zero rows, not by raising, so "the statement errored" is the wrong
assertion almost every time. Assert on the state of the table afterwards.
"""

import json
import os
import re
import sys

from harness import As, apply_migrations, check, make_user, recreate_db, summary

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODEL = os.path.join(REPO, "packages", "cairn_model", "lib", "src")


def dart_invite_words():
    """The vocabulary as `cairn_model` spells it, read out of the Dart itself.

    The point is drift, not parsing. A code minted on one side of the seam is
    typed into the other, so a word that exists in only one of the two lists is
    a code somebody can be given and cannot use. Reading the Dart is the only
    way this file can notice that.
    """
    src = open(os.path.join(MODEL, "invite_code.dart")).read()
    body = re.search(r"static const words = <String>\[(.*?)\];", src, re.S).group(1)
    return re.findall(r"'([a-z]+)'", body)


def dart_grace_days():
    """`graceAfterATrip`, in days, as `cairn_model` states it."""
    src = open(os.path.join(MODEL, "trip_close.dart")).read()
    return int(re.search(r"graceAfterATrip = Duration\(days: (\d+)\)", src).group(1))

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
    a.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, 'otter maple 42', :u)",
          t=japan, u=alice)
    status, rows = c.try_run("select public.redeem_trip_invite('otter maple 42')")
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

    d.run("select public.redeem_trip_invite('otter maple 42')")
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
    c.run("select public.redeem_trip_invite('otter maple 42')")

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
    d.run("select public.redeem_trip_invite('otter maple 42')")
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
        "insert into public.trip_invites (trip_id, code, created_by) values (:t, 'cedar willow 27', :u)",
        t=japan, u=carol)
    check(status == "ok", "any member can mint one -- inviting is flat", repr(rows)[:80])
    before = db.run("select use_count from public.trip_invites where code = 'otter maple 42'")[0][0]
    c.run("select public.redeem_trip_invite('otter maple 42')")
    after = db.run("select use_count from public.trip_invites where code = 'otter maple 42'")[0][0]
    check(before == after, "re-redeeming a code you already used spends no use", f"{before} -> {after}")

    # ------------------------------------------------- the code is three words
    print("\n== a code is three spoken words, and the two halves spell them the same ==")
    words = db.run("select public.invite_code_words()")[0][0]
    check(list(words) == dart_invite_words(),
          "the server's vocabulary is the phone's, word for word",
          f"server={len(words)} dart={len(dart_invite_words())}")

    columns = [row[0] for row in db.run(
        "select column_name from information_schema.columns "
        "where table_schema = 'public' and table_name = 'trip_invites'")]
    check("expires_at" not in columns,
          "an invite carries no expiry of its own -- the trip's close is the only one",
          f"columns={columns}")

    minted = [db.run("select public.generate_invite_code()")[0][0] for _ in range(20)]
    shape = re.compile(r"^([a-z]+) ([a-z]+) ([1-9][0-9])$")
    check(all(shape.match(m) for m in minted),
          "the generator mints two words and a two-digit number, never eight characters",
          repr(minted[:3]))
    check(all(shape.match(m).group(1) != shape.match(m).group(2) for m in minted),
          "and never the same word twice", repr(minted[:3]))
    check(all(shape.match(m).group(i) in words for m in minted for i in (1, 2)),
          "drawn only from the vocabulary", repr(minted[:3]))

    # The whole grammar rests on this: a word one edit out can only ever be the
    # word it was reaching for. It is pinned on the phone by
    # `packages/cairn_model/test/invite_code_test.dart`, and pinned here too
    # because the server is the half that does the matching at redemption.
    slack = db.run("select public.invite_code_spelling_slack()")[0][0]
    close = db.run("""select a, b from unnest(public.invite_code_words()) a,
                                        unnest(public.invite_code_words()) b
                      where a < b and public.invite_word_distance(a, b) <= :n""", n=2 * slack)
    check(not close, f"no two words are within {2 * slack} edits of each other", repr(close[:3]))
    check(db.run("select public.invite_word_distance('maple', 'mapel')")[0][0] == 1,
          "a swapped pair of letters is one edit, not two -- the commonest typo there is",
          repr(db.run("select public.invite_word_distance('maple', 'mapel')")[0][0]))
    check(db.run("select public.invite_code_key('otter, maple, 42')")[0][0]
          == db.run("select public.invite_code_key('OTTER-MAPLE-42')")[0][0]
          == 'maple otter 42',
          "and everything that is not a letter or a digit is a gap")
    check(db.run("select public.invite_code_key('otter maple 4')")[0][0] is None
          and db.run("select public.invite_code_key('otter maple 999999999999')")[0][0] is None
          and db.run("select public.invite_code_key('otter otter 42')")[0][0] is None,
          "a one-digit number, a forty-digit one and the same word twice are all not codes")

    drawn = str(c.run(
        "insert into public.trip_invites (trip_id, created_by) values (:t, :u) returning code",
        t=japan, u=carol)[0][0])
    check(bool(shape.match(drawn)), "and it is what the column defaults to", repr(drawn))

    status, rows = c.try_run(
        "insert into public.trip_invites (trip_id, code, created_by) values (:t, 'JAPAN123', :u)",
        t=japan, u=carol)
    check(db.run("select count(*) from public.trip_invites where code = 'JAPAN123'")[0][0] == 0,
          "an eight-character code is not a code any more, and cannot be stored",
          repr(rows)[:80])

    print("\n== said in another order, or a letter out, it is the same code ==")
    joined = str(d.run("select public.redeem_trip_invite('willow cedar 27')")[0][0])
    check(joined == japan, "the words in the other order open the trip they were minted for",
          f"{joined} -> {japan}")
    db.run("delete from public.trip_members where trip_id = :t and user_id = :u", t=japan, u=dave)
    joined = str(d.run("select public.redeem_trip_invite('ceder willo 27')")[0][0])
    check(joined == japan, "and one letter out per word is still the word that was said", joined)
    status, rows = d.try_run("select public.redeem_trip_invite('cedar zzzzzz 27')")
    check(status == "err" and "not found" in str(rows),
          "while a word nothing is reaching for is not a worse guess, it is no code",
          repr(rows)[:90])
    status, rows = c.try_run(
        "insert into public.trip_invites (trip_id, code, created_by) values (:t, 'willow cedar 27', :u)",
        t=japan, u=carol)
    check(db.run("select count(*) from public.trip_invites "
                 "where code in ('willow cedar 27', 'cedar willow 27')")[0][0] == 1,
          "so the same code written the other way round cannot be minted twice",
          repr(rows)[:80])

    # ------------------------------------------------ a code dies with its trip
    print("\n== a code that outlived its trip opens nothing ==")
    grace = dart_grace_days()
    check(db.run("select extract(epoch from public.trip_grace_after_end())")[0][0]
          == grace * 86400,
          f"the grace after a trip is the phone's {grace} days, not a second number",
          repr(db.run("select public.trip_grace_after_end()")[0][0]))
    check(db.run("""select public.trip_closes_at(t.id)
                           = ((t.end_date + 1)::timestamp at time zone t.timezone)
                             + make_interval(days => :g)
                    from public.trips t where t.id = :t""", t=japan, g=grace)[0][0] is True,
          "and a trip closes a grace after its last day ends, in its own clock, not UTC")

    stale = str(b.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('Last year', :u, 'Atlantic/Reykjavik', current_date - 44, current_date - 40)
           returning id""", u=bob)[0][0])
    b.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, 'puffin quartz 61', :u)",
          t=stale, u=bob)
    status, rows = d.try_run("select public.redeem_trip_invite('puffin quartz 61')")
    check(status == "err" and "expired" in str(rows),
          "redeeming a code whose trip closed is refused", repr(rows)[:90])
    check(db.run("select count(*) from public.trip_members where trip_id = :t and user_id = :u",
                 t=stale, u=dave)[0][0] == 0,
          "and nobody joined -- the refusal is a refusal, not a message")
    status, rows = d.try_run("select count(*) from public.photos where trip_id = :t", t=stale)
    check(rows[0][0] == 0, "so last year's archive stays shut to whoever still remembers three words")

    fresh = str(b.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('Just back', :u, 'Atlantic/Reykjavik', current_date - 9, current_date - 5)
           returning id""", u=bob)[0][0])
    b.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, 'puffin quartz 62', :u)",
          t=fresh, u=bob)
    status, rows = d.try_run("select public.redeem_trip_invite('puffin quartz 62')")
    check(status == "ok", "a trip that ended inside the grace still lets someone in", repr(rows)[:90])
    check(db.run("select count(*) from public.trip_members where trip_id = :t and user_id = :u",
                 t=fresh, u=dave)[0][0] == 1,
          "which is what the grace is for: the photos are still coming")

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

    print("\n== an invite cannot be repointed to another trip ==")
    before_trip = db.run("select trip_id from public.trip_invites where code = 'cedar willow 27'")[0][0]
    status, rows = c.try_run(
        "update public.trip_invites set trip_id = :t where code = 'cedar willow 27'", t=iceland)
    check(status == "err", "even by its own creator, to a trip she also belongs to", repr(rows)[:80])
    after_trip = db.run("select trip_id from public.trip_invites where code = 'cedar willow 27'")[0][0]
    check(str(after_trip) == str(before_trip), "and the row's trip_id is unchanged",
          f"{before_trip} -> {after_trip}")

    # ------------------------------------------------- the itinerary as a fact
    #
    # The plan is a shared stored fact since 0010_trip_itinerary.sql, merged
    # last-write-wins per day. That rule is written twice on purpose -- in
    # `sync_trip_itinerary` and on the phone in `lib/repositories/itinerary_sync.dart`
    # -- so what matters here is that the SQL half behaves exactly as the Dart
    # half assumes: a stale day loses, a fresh day wins, a day nobody pushed is
    # not collaterally rewritten, and a phone that has not synced lately cannot
    # delete what it has never seen.
    #
    # A trip of its own, because the trips above have been deliberately taken
    # apart -- Alice has left Japan and had her login deleted by this point, and
    # a merge test wants two members who are both still there.
    print("\n== the itinerary is a shared fact, merged per day ==")

    norway = str(
        b.run(
            """insert into public.trips (name, created_by, timezone, start_date, end_date)
               values ('Norway', :u, 'Europe/Oslo', current_date, current_date + 4)
               returning id""",
            u=bob,
        )[0][0]
    )
    b.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, 'anchor bison 61', :u)",
          t=norway, u=bob)
    c.run("select public.redeem_trip_invite('anchor bison 61')")

    def sync(who, trip, plan_at, days, pocket_at="-infinity", pocket=()):
        """One call, both directions: (status, merged plan) or (status, message)."""
        status, rows = who.try_run(
            "select public.sync_trip_itinerary(:t, :plan::timestamptz, :days::jsonb, "
            ":pocket_at::timestamptz, :pocket::jsonb)",
            t=trip, plan=plan_at, days=json.dumps(days),
            pocket_at=pocket_at, pocket=json.dumps(list(pocket)),
        )
        if status != "ok":
            return status, rows
        payload = rows[0][0]
        return status, json.loads(payload) if isinstance(payload, str) else payload

    T1, T2, T3 = "2027-06-01T00:00:00Z", "2027-06-02T00:00:00Z", "2027-06-03T00:00:00Z"

    def day(n, revised, place, stops=()):
        return {
            "day_number": n, "day_date": None, "place": place, "revised_at": revised,
            "stops": [{"position": i, "stop_text": s, "time_of_day": None}
                      for i, s in enumerate(stops)],
        }

    def numbered(plan):
        return {d["day_number"]: d for d in plan["days"]}

    def texts(plan, n):
        return [s["stop_text"] for s in numbered(plan).get(n, {}).get("stops", [])]

    status, plan = sync(b, norway, T1, [day(1, T1, "Oslo", ["Vigeland"]), day(2, T1, "Bergen")])
    check(status == "ok" and len(plan["days"]) == 2,
          "a member pushes a plan and gets the merged plan back", repr(plan)[:120])
    check(texts(plan, 1) == ["Vigeland"],
          "with each day's stops under it, in order", repr(numbered(plan)[1]["stops"]))

    # Carol pulls by pushing nothing at all -- the joiner's case, and the one
    # that must delete nothing.
    status, plan = sync(c, norway, "-infinity", [])
    check(status == "ok" and len(plan["days"]) == 2,
          "a member with no plan of her own pulls the whole plan by pushing nothing",
          repr(status))
    check(db.run("select count(*) from public.trip_itinerary_days where trip_id = :t",
                 t=norway)[0][0] == 2,
          "and deletes nothing by not having it")

    # Carol edits day 2. Bob then pushes the stale copy he still holds.
    sync(c, norway, T2, [day(1, T1, "Oslo", ["Vigeland"]), day(2, T2, "Bergen", ["Bryggen"])])
    status, plan = sync(b, norway, T1, [day(1, T1, "Oslo", ["Vigeland"]), day(2, T1, "Bergen")])
    check(texts(plan, 2) == ["Bryggen"],
          "a stale push does not overwrite a day somebody edited since", repr(texts(plan, 2)))
    check(texts(plan, 1) == ["Vigeland"],
          "and the day it did not lose is left exactly as it was", repr(texts(plan, 1)))

    status, plan = sync(b, norway, T3, [day(1, T3, "Oslo", ["Holmenkollen"]),
                                        day(2, T2, "Bergen", ["Bryggen"])])
    check(texts(plan, 1) == ["Holmenkollen"],
          "a newer push does overwrite, stops replaced with the day", repr(texts(plan, 1)))

    # Deletion. Carol adds a day 3; Bob, whose view of the plan's shape is older
    # than that, re-pushes a two-day plan.
    sync(c, norway, T3, [day(1, T3, "Oslo", ["Holmenkollen"]),
                         day(2, T2, "Bergen", ["Bryggen"]),
                         day(3, T3, "Tromso")])
    status, plan = sync(b, norway, T2, [day(1, T3, "Oslo", ["Holmenkollen"]),
                                        day(2, T2, "Bergen", ["Bryggen"])])
    check(sorted(numbered(plan)) == [1, 2, 3],
          "a phone cannot delete a day added after the shape it last saw",
          repr(sorted(numbered(plan))))
    status, plan = sync(b, norway, T3, [day(1, T3, "Oslo", ["Holmenkollen"]),
                                        day(2, T2, "Bergen", ["Bryggen"])])
    check(sorted(numbered(plan)) == [1, 2],
          "but a phone whose view is current can drop a day", repr(sorted(numbered(plan))))
    check(db.run("select count(*) from public.trip_itinerary_stops "
                 "where trip_id = :t and day_number = 3", t=norway)[0][0] == 0,
          "and the dropped day takes its stops with it")

    print("\n== the set-aside pocket is one atom, and emptying it still counts ==")
    onsen = [{"position": 0, "source_line_number": 9,
              "line_text": "book the cabin", "explanation": "no day named"}]
    sync(b, norway, T3, [day(1, T3, "Oslo", ["Holmenkollen"]), day(2, T2, "Bergen")],
         pocket_at=T2, pocket=onsen)
    status, plan = sync(c, norway, T3, [day(1, T3, "Oslo", ["Holmenkollen"]), day(2, T2, "Bergen")],
                        pocket_at=T3, pocket=[])
    check(plan["set_asides"] == [], "a newer push can empty the pocket", repr(plan["set_asides"]))
    status, plan = sync(b, norway, T3, [day(1, T3, "Oslo", ["Holmenkollen"]), day(2, T2, "Bergen")],
                        pocket_at=T2, pocket=onsen)
    check(plan["set_asides"] == [],
          "and a stale phone cannot refill it by still holding a line", repr(plan["set_asides"]))

    print("\n== the plan is a trip's, and nobody else's ==")
    status, rows = d.try_run(
        "select count(*) from public.trip_itinerary_days where trip_id = :t", t=norway)
    check(status == "ok" and rows[0][0] == 0,
          "a non-member reads zero itinerary days, filtered not errored", repr(rows))
    status, rows = sync(d, norway, T3, [day(1, T3, "Nowhere")])
    check(status == "err", "and cannot push a plan into a trip he is not on", repr(rows)[:80])
    check(db.run("select place from public.trip_itinerary_days "
                 "where trip_id = :t and day_number = 1", t=norway)[0][0] == "Oslo",
          "the day he aimed at is unchanged")
    status, rows = d.try_run(
        "insert into public.trip_itinerary_days (trip_id, day_number, revised_at) "
        "values (:t, 9, now())", t=norway)
    check(status == "err", "nor write one round the function, straight into the table",
          repr(rows)[:80])

    print("\n== the roster reads as one statement, and only for the party ==")
    status, rows = b.try_run(
        "select user_id, display_name from public.trip_roster where trip_id = :t order by joined_at",
        t=norway)
    names = sorted(row[1] for row in rows) if status == "ok" else []
    check(status == "ok" and names == ["Bob", "Carol"],
          "a member reads every co-member and their name in one read", repr(names))
    status, rows = d.try_run("select count(*) from public.trip_roster where trip_id = :t", t=norway)
    check(status == "ok" and rows[0][0] == 0,
          "a non-member reads nobody -- the view invents no access", repr(rows))
    columns = [row[0] for row in db.run(
        "select column_name from information_schema.columns "
        "where table_schema = 'public' and table_name = 'trip_roster'")]
    check("joined_on_day" not in columns and "joined_at" in columns,
          "and it hands over the instant, never the trip day -- the phone counts those",
          f"columns={columns}")

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
