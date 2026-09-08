"""Adversarial suite for Cairn's schema and its row-level security.

Grouped by the thing being defended rather than by table, so a failure names a
product decision rather than a policy. Run it against a throwaway Postgres 17:

    python3 supabase/tests/rls_probe.py

Read the caution in harness.As.try_run before adding a check: RLS refuses by
filtering to zero rows, not by raising, so "the statement errored" is the wrong
assertion almost every time. Assert on the state of the table afterwards.
"""

import datetime
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


def dart_grace_hours():
    """`graceAfterATrip`, in hours, as `cairn_model` states it.

    Written as hours on both sides since the window became seventy-two of
    them (`docs/decisions/2026-08-26-the-ending.md`). Read rather than
    hard-coded for the same reason the word list is: the number lives in the
    Dart and in `trip_grace_after_end()`, and the only thing that can notice
    the two drifting apart is something that reads both.
    """
    src = open(os.path.join(MODEL, "trip_close.dart")).read()
    return int(re.search(r"graceAfterATrip = Duration\(hours: (\d+)\)", src).group(1))

PHOTO_A = "aaaaaaaa-0000-0000-0000-000000000001"
PHOTO_B = "bbbbbbbb-0000-0000-0000-000000000001"
PHOTO_C = "cccccccc-0000-0000-0000-000000000001"
PHOTO_D = "dddddddd-0000-0000-0000-000000000001"


def photo_key(trip, photo, name="original.jpg"):
    """`r2-upload-url`'s `objectKeyFor` said in Python, for fixtures.

    Since `0011` a `photos` row may only claim a key inside its own
    `trips/<trip_id>/photos/<photo_id>/` folder, so every insert below has to
    build one -- which is also why every insert now names an explicit `id`
    rather than letting `gen_random_uuid()` supply it. A photo whose key must
    contain its own id cannot be written by a client that does not know the id
    yet; the app already mints it (`PhotoId.mint`).
    """
    return f"trips/{trip}/photos/{photo}/{name}"


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
                                      content_type, byte_size, day_number, trip_day, captured_at)
           values (:id, :t, :u, :k, 'image/jpeg', 100, 1, current_date - 2, now())""",
        id=PHOTO_A, t=japan, u=alice, k=photo_key(japan, PHOTO_A),
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

    # --------------------------------------------------------- naming is flat
    print("\n== any current member may rename, and only rename, the trip ==")
    renamed_at = db.run("select now() + interval '1 minute'")[0][0]
    status, rows = c.try_run(
        """update public.trips
           set name = 'Japan together', name_revised_at = :at
           where id = :t""",
        t=japan, at=renamed_at)
    check(status == "ok" and db.run(
        "select name from public.trips where id = :t", t=japan)[0][0] == "Japan together",
        "a member who did not create the trip can rename it", repr(rows)[:80])

    b.try_run(
        """update public.trips
           set name = 'Not Bob''s trip', name_revised_at = now() + interval '2 minutes'
           where id = :t""",
        t=japan)
    check(db.run("select name from public.trips where id = :t", t=japan)[0][0]
          == "Japan together",
          "a person who is not a member cannot rename it")

    before_zone = db.run("select timezone from public.trips where id = :t", t=japan)[0][0]
    status, rows = c.try_run(
        """update public.trips
           set timezone = 'Asia/Seoul', name_revised_at = now() + interval '3 minutes'
           where id = :t""",
        t=japan)
    check(status == "err" and db.run(
        "select timezone from public.trips where id = :t", t=japan)[0][0] == before_zone,
        "the member rename path cannot retime the trip", repr(rows)[:100])

    disposable = str(a.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('Disposable', :u, 'Asia/Tokyo', current_date, current_date + 1)
           returning id""", u=alice)[0][0])
    a.run("insert into public.trip_members (trip_id, user_id) values (:t, :u)",
          t=disposable, u=carol)
    c.try_run("delete from public.trips where id = :t", t=disposable)
    check(db.run("select count(*) from public.trips where id = :t", t=disposable)[0][0] == 1,
          "a non-starter member still cannot delete the trip")
    a.run("delete from public.trips where id = :t", t=disposable)
    check(db.run("select count(*) from public.trips where id = :t", t=disposable)[0][0] == 0,
          "and the starter's existing delete power is unchanged")

    # ------------------------------- and through the door the app actually uses
    #
    # Everything above drives `update public.trips` directly, which the app
    # never does: `PostgrestSharedFacts.syncTripName` posts to
    # `/rest/v1/rpc/sync_trip_name`. A column that exists but is not reachable
    # through the function is the state `0012` shipped in, and reading the
    # schema cannot see it -- so the merge rule is asserted on the round trip,
    # exactly as the itinerary's is.
    print("\n== the rename round trip, through sync_trip_name ==")

    def rename(who, trip, name, at):
        """('ok', the name that won) or ('err', message)."""
        status, rows = who.try_run(
            "select public.sync_trip_name(:t, :n, :at::timestamptz)",
            t=trip, n=name, at=at)
        if status != "ok":
            return status, rows
        payload = rows[0][0]
        return status, json.loads(payload) if isinstance(payload, str) else payload

    def now_plus(minutes):
        return db.run("select (now() + make_interval(mins => :m))::text", m=minutes)[0][0]

    def trip_name(trip):
        return db.run("select name from public.trips where id = :t", t=trip)[0][0]

    fresh_at = now_plus(10)
    status, answer = rename(c, japan, "Japan, the second time", fresh_at)
    check(status == "ok" and answer["name"] == "Japan, the second time"
          and trip_name(japan) == "Japan, the second time",
          "a member who did not start the trip renames it through the RPC",
          repr(answer)[:100])

    status, answer = rename(c, japan, "Typed on a phone with a slow clock", now_plus(5))
    check(status == "ok" and answer["name"] == "Japan, the second time"
          and trip_name(japan) == "Japan, the second time",
          "a stale revision loses and is handed the name that won -- strictly newer wins",
          repr(answer)[:100])

    status, answer = rename(c, japan, "Japan, again", now_plus(20))
    check(status == "ok" and trip_name(japan) == "Japan, again",
          "while a newer revision from the same phone lands", repr(answer)[:100])

    status, rows = rename(b, japan, "Not Bob's trip", now_plus(30))
    check(status == "err" and "not a member" in str(rows)
          and trip_name(japan) == "Japan, again",
          "a non-member calling the function directly is refused, and nothing moved",
          repr(rows)[:100])

    # A trip of its own, closed, so the refusal is the close and nothing else:
    # Carol is a member of it and Alice started it, and both are refused.
    closed = str(a.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('Last summer', :u, 'Asia/Tokyo', current_date - 44, current_date - 40)
           returning id""", u=alice)[0][0])
    a.run("insert into public.trip_members (trip_id, user_id) values (:t, :u)",
          t=closed, u=carol)
    status, rows = rename(c, closed, "Renamed after the fact", now_plus(10))
    check(status == "err" and "closed" in str(rows) and trip_name(closed) == "Last summer",
          "a member cannot rename a closed trip -- what it was called is part of the record",
          repr(rows)[:100])
    status, rows = rename(a, closed, "Renamed by the starter", now_plus(10))
    check(status == "err" and "closed" in str(rows) and trip_name(closed) == "Last summer",
          "and neither can the person who started it", repr(rows)[:100])
    status, rows = c.try_run(
        """update public.trips set name = 'Round the function',
               name_revised_at = now() + interval '11 minutes' where id = :t""",
        t=closed)
    check(status == "err" and trip_name(closed) == "Last summer",
          "nor round the function, straight into the table", repr(rows)[:100])
    # The starter has an UPDATE policy of their own (0004), so a bare PATCH is
    # a second door and the refusal has to be a property of the record rather
    # than of `sync_trip_name`.
    status, rows = a.try_run(
        """update public.trips set name = 'Round it as the starter',
               name_revised_at = now() + interval '12 minutes' where id = :t""",
        t=closed)
    check(status == "err" and "closed" in str(rows) and trip_name(closed) == "Last summer",
          "and the starter cannot walk round it either, on the path 0004 gave them",
          repr(rows)[:100])
    # ...while nothing else the starter could already do to a closed trip has
    # been taken away with it: the guard is on the rename, not on the UPDATE.
    status, rows = a.try_run(
        "update public.trips set city = 'Sapporo' where id = :t", t=closed)
    check(status == "ok" and db.run(
        "select city from public.trips where id = :t", t=closed)[0][0] == "Sapporo",
        "the rest of the starter's power over a closed trip is untouched",
        repr(rows)[:100])
    a.run("delete from public.trips where id = :t", t=closed)

    # The guard is an allowlist, so a column a later migration adds to `trips`
    # is refused without that migration having to remember this trigger.
    db.run("alter table public.trips add column probe_future_column text")
    status, rows = c.try_run(
        """update public.trips set probe_future_column = 'mine now',
               name_revised_at = now() + interval '40 minutes' where id = :t""",
        t=japan)
    check(status == "err" and db.run(
        "select probe_future_column from public.trips where id = :t", t=japan)[0][0] is None,
        "a column nobody has taught the guard about is refused, not handed over",
        repr(rows)[:100])
    db.run("alter table public.trips drop column probe_future_column")

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
    forged = "ffffffff-0000-0000-0000-000000000001"
    status, rows = c.try_run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key, content_type,
                                      byte_size, day_number)
           values (:id, :t, :other, :k, 'image/jpeg', 10, 1)""",
        id=forged, t=japan, other=alice, k=photo_key(japan, forged))
    check(status == "err", "a member cannot tag a photo as someone else", repr(rows)[:80])
    status, rows = c.try_run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key, content_type,
                                      byte_size, day_number)
           values (:id, :t, :u, :k, 'image/jpeg', 10, 1)""",
        id=forged, t=iceland, u=carol, k=photo_key(iceland, forged))
    check(status == "err", "and cannot insert into a trip they are not on", repr(rows)[:80])

    # ------------------------------- what the row's protection does NOT reach
    #
    # These are premises, not policies: they pin the facts `r2-upload-url`'s
    # refusals rest on, so that a change here surfaces as a failure beside the
    # policy that caused it rather than as a silent widening of what that
    # function must check.
    #
    # The row above is well protected. The *object* it points at is not
    # protected by anything in this schema at all -- there is no R2 in
    # Postgres -- so whatever a co-member can read here is the raw material for
    # signing a PUT over somebody else's original. That is why the function
    # refuses to sign a photo id a row already holds
    # (`supabase/functions/r2-upload-url/handler.ts`, tested in its own
    # `handler_test.ts`), and these two checks are why it has to.
    print("\n== a co-member can read what an upload URL is minted from ==")
    status, rows = c.try_run(
        "select id, r2_object_key from public.photos where id = :id", id=PHOTO_A)
    check(status == "ok" and len(rows) == 1 and str(rows[0][0]) == PHOTO_A,
          "a co-member reads my photo's id and its object key -- neither is a secret",
          repr(rows)[:90])
    check(bool(rows) and bool(rows[0][1]),
          "so a photo id is never evidence of who is entitled to write that object")

    print("\n== trip_closes_at answers a member and hides from everyone else ==")
    # `UploadDatabase.tripClosesAt` refuses on a null, and this is what makes
    # that right: null is "a trip you cannot see", never "a trip with no end".
    status, rows = a.try_run("select public.trip_closes_at(:t)", t=japan)
    check(status == "ok" and rows[0][0] is not None,
          "a member is told when their trip closes", repr(rows)[:90])
    status, rows = b.try_run("select public.trip_closes_at(:t)", t=japan)
    check(status == "ok" and rows[0][0] is None,
          "and a stranger is told null, which is a refusal and not 'never closes'",
          repr(rows)[:90])

    # ------------------------------------------------------------------- gate
    #
    # Since 0011 the gate is keyed by the day's **ordinal**, not its date: the
    # photograph belongs to its day by number (move the trip a week later and a
    # day-3 photograph is still on day 3), while whether you may see it yet is
    # a fact about the calendar. So the function resolves the date itself,
    # through the itinerary the trip has synced -- which is what these rows are
    # for. Day 3 is today in the trip's own zone, day 1 is walked, day 5 has
    # not arrived, day 9 carries no date at all, and day 42 is not in the plan.
    print("\n== the gate holds today shut until you have put something in it ==")
    today = db.run("select (now() at time zone 'Asia/Tokyo')::date")[0][0]
    for n in range(1, 9):
        db.run("""insert into public.trip_itinerary_days (trip_id, day_number, day_date, revised_at)
                  values (:t, :n, (:today::date + (:n - 3)), now())
                  on conflict (trip_id, day_number) do nothing""", t=japan, n=n, today=today)
    db.run("""insert into public.trip_itinerary_days (trip_id, day_number, day_date, revised_at)
              values (:t, 9, null, now())
              on conflict (trip_id, day_number) do nothing""", t=japan)
    TODAY_DAY, PAST_DAY, FUTURE_DAY, UNDATED_DAY, UNPLANNED_DAY = 3, 1, 5, 9, 42

    is_open = "select public.day_page_is_open(:t, :d, :u)"
    check(db.run("select count(*) from public.day_unlocks where user_id = :u", u=alice)[0][0] == 1,
          "contributing a photo records an unlock for that day")
    check(db.run("select day_number from public.day_unlocks where user_id = :u", u=alice)[0][0] == 1,
          "and the unlock names the day by its number, not by a date")
    check(c.run(is_open, t=japan, d=TODAY_DAY, u=carol)[0][0] is False,
          "today is shut for a member who has contributed nothing to it")
    status, rows = c.try_run(
        "select count(*), min(captured_at) from public.photos where trip_id = :t", t=japan)
    check(status == "ok" and rows[0][0] == 1,
          "but a shut gate can still read the day's times and names -- rows are not hidden")
    c.run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                      content_type, byte_size, day_number, trip_day, captured_at)
           values (:id, :t, :u, :k, 'image/jpeg', 100, :n, :d, now())""",
        id=PHOTO_C, t=japan, u=carol, n=TODAY_DAY, d=today, k=photo_key(japan, PHOTO_C))
    check(c.run(is_open, t=japan, d=TODAY_DAY, u=carol)[0][0] is True,
          "and contributing opens it for her at once")
    check(c.run(is_open, t=japan, d=FUTURE_DAY, u=carol)[0][0] is False,
          "a day that has not arrived is shut, and contribution is not offered as its key")

    # The phone's own rule, mirrored deliberately: `standingOfPlanDay` reads
    # `planDay?.date` and answers `walked` when it is null, which collapses "a
    # day nobody has dated" and "a day the plan no longer claims" into the one
    # answer. Its reasoning transfers exactly -- today has a date, so a day
    # with none is certainly not the day being lived, and the gate has no
    # business shutting any other day.
    print("\n== a day with no date is walked, exactly as the phone reads it ==")
    check(c.run(is_open, t=japan, d=UNDATED_DAY, u=carol)[0][0] is True,
          "a day of the plan whose date is still open is open to the party")
    check(c.run(is_open, t=japan, d=UNPLANNED_DAY, u=carol)[0][0] is True,
          "and so is a day number the plan does not claim at all")
    status, rows = b.try_run(is_open, t=japan, d=UNDATED_DAY, u=bob)
    check(status == "ok" and rows[0][0] is False,
          "while a stranger is refused every day of it, dated or not", repr(rows)[:60])

    # The hole 0011 closes on the write path: the old trigger only recorded an
    # unlock when `trip_day` was non-null, so a photograph taken on a day
    # nobody had dated opened nothing and its own taker was gated out.
    # Contributing never requires a day to have a date.
    print("\n== contributing to an undated day still opens it ==")
    d.run("select public.redeem_trip_invite('otter maple 42')")
    undated_photo = "eeeeeeee-0000-0000-0000-000000000001"
    d.run("""insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                        content_type, byte_size, day_number, captured_at)
             values (:id, :t, :u, :k, 'image/jpeg', 100, :n, now())""",
          id=undated_photo, t=japan, u=dave, n=UNDATED_DAY,
          k=photo_key(japan, undated_photo))
    check(db.run("""select count(*) from public.day_unlocks
                    where trip_id = :t and user_id = :u and day_number = :n""",
                 t=japan, u=dave, n=UNDATED_DAY)[0][0] == 1,
          "a photograph on a day with no date records an unlock all the same")
    d.run("delete from public.photos where id = :id", id=undated_photo)

    print("\n== an unlock follows a photograph instead of opening every day it visits ==")
    walked_photo = "eeeeeeee-0000-0000-0000-000000000002"
    d.run("""insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                        content_type, byte_size, day_number, trip_day, captured_at)
             values (:id, :t, :u, :k, 'image/jpeg', 100, :n, :d, now())""",
          id=walked_photo, t=japan, u=dave, n=TODAY_DAY, d=today,
          k=photo_key(japan, walked_photo))
    check(d.run(is_open, t=japan, d=TODAY_DAY, u=dave)[0][0] is True,
          "the photograph opens the day where it currently lives")
    d.run("update public.photos set day_number = :n where id = :id",
          n=FUTURE_DAY, id=walked_photo)
    check(d.run(is_open, t=japan, d=TODAY_DAY, u=dave)[0][0] is False,
          "moving the only photograph away closes the old current day again")
    check(db.run("""select count(*) from public.day_unlocks
                    where trip_id = :t and user_id = :u and day_number = :n""",
                 t=japan, u=dave, n=TODAY_DAY)[0][0] == 0,
          "and no stale unlock remains for the old day")
    check(d.run(is_open, t=japan, d=FUTURE_DAY, u=dave)[0][0] is True,
          "while the unlock follows the photograph to its new day")
    d.run("delete from public.photos where id = :id", id=walked_photo)

    print("\n== changing a date cannot turn a shut day into a walked one ==")
    status, rows = d.try_run(
        """update public.trip_itinerary_days set day_date = :past
            where trip_id = :t and day_number = :n""",
        past=today - datetime.timedelta(days=1),
        t=japan, n=TODAY_DAY)
    check(status == "ok",
          "a member may still correct today's itinerary date", repr(rows)[:90])
    check(d.run(is_open, t=japan, d=TODAY_DAY, u=dave)[0][0] is False,
          "but re-dating it into the past does not open the gate early")
    db.run("""update public.trip_itinerary_days set day_date = :today
              where trip_id = :t and day_number = :n""",
           today=today, t=japan, n=TODAY_DAY)
    status, rows = d.try_run(
        """update public.trip_itinerary_days set day_date = null
            where trip_id = :t and day_number = :n""",
        t=japan, n=TODAY_DAY)
    check(status == "ok",
          "and may still leave that date open", repr(rows)[:90])
    check(d.run(is_open, t=japan, d=TODAY_DAY, u=dave)[0][0] is False,
          "but un-dating it does not reach the permissive default early")
    status, _ = d.try_run(
        "delete from public.day_gate_date_guards where trip_id = :t and day_number = :n",
        t=japan, n=TODAY_DAY)
    check(status == "ok" and db.run(
        """select count(*) from public.day_gate_date_guards
            where trip_id = :t and day_number = :n""",
        t=japan, n=TODAY_DAY)[0][0] == 1,
        "and no member can erase the date guard that keeps the gate shut")
    db.run("""update public.trip_itinerary_days set day_date = :today
              where trip_id = :t and day_number = :n""",
           today=today, t=japan, n=TODAY_DAY)
    check(d.run(is_open, t=japan, d=TODAY_DAY, u=dave)[0][0] is False,
          "and the restored current day remains shut for that member")

    print("\n== you can delete your own photo, and the day stays open ==")
    status, _ = c.try_run("delete from public.photos where id = :id", id=PHOTO_C)
    check(status == "ok" and db.run("select count(*) from public.photos where id = :id",
                                    id=PHOTO_C)[0][0] == 0,
          "a person can delete their own photo")
    check(c.run(is_open, t=japan, d=TODAY_DAY, u=carol)[0][0] is True,
          "the day stays open afterwards -- no re-lock")
    c.try_run("delete from public.day_unlocks where trip_id = :t and user_id = :u", t=japan, u=carol)
    check(db.run("select count(*) from public.day_unlocks where trip_id = :t and user_id = :u",
                 t=japan, u=carol)[0][0] == 1,
          "and nobody can delete the unlock, so nobody can re-lock the day")
    status, rows = d.try_run(
        "insert into public.day_unlocks (trip_id, day_number, user_id) values (:t, :n, :u)",
        t=japan, n=TODAY_DAY, u=dave)
    check(status == "err", "nor forge one", repr(rows)[:80])

    print("\n== someone joining mid-trip sees every past day freely ==")
    check(d.run(is_open, t=japan, d=PAST_DAY, u=dave)[0][0] is True,
          "a member who joined today can open a day that ended before he arrived")
    check(d.run(is_open, t=japan, d=TODAY_DAY, u=dave)[0][0] is False,
          "while today is gated for him normally")
    status, rows = d.try_run("select count(*) from public.photos where trip_id = :t", t=japan)
    check(status == "ok" and rows[0][0] == 1, "and past days' rows carry no day predicate at all")

    # ------------------------------------------------- the single seat, 0011
    #
    # `may_read_trip_photos` answers `is_trip_member` today and nothing else.
    # What is being pinned is not its body but its *position*: every photo read
    # in the system -- the SELECT policy here, and `r2-download-url`, which
    # inherits it by reading the row as the caller -- goes through this one
    # function, so the leaver split ("if you leave you keep the trip; if you
    # are removed you do not") lands in one body and not in scattered checks.
    print("\n== every photo read goes through one seat, so the leaver rule has one ==")
    policy = db.run("""select qual from pg_policies
                       where schemaname = 'public' and tablename = 'photos'
                         and policyname = 'photos_select_trip_member'""")[0][0]
    check("may_read_trip_photos" in policy,
          "the photos SELECT policy asks the seat, not is_trip_member directly", policy[:80])
    check(db.run("select prosecdef from pg_proc where proname = 'may_read_trip_photos'")[0][0] is True,
          "and the seat is SECURITY DEFINER, so a policy on a gated table cannot recurse into it")
    check(c.run("select public.may_read_trip_photos(:t, :u)", t=japan, u=carol)[0][0] is True,
          "a member may read the trip's photographs")
    check(c.run("select public.may_read_trip_photos(:t, :u)", t=iceland, u=dave)[0][0] is False,
          "and someone who is not on the trip may not")

    # ------------------------------------------------------- the word, 0011
    #
    # Single-owner by the policy that already existed: `photos_update_contributor`
    # is contributor-only with an explicit WITH CHECK, so no new machinery is
    # needed to make "the owner's most recent write wins" true. Watch it refuse
    # rather than assume it.
    print("\n== the word under a photograph is its owner's, and nobody else's ==")
    d.run("""insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                        content_type, byte_size, day_number, captured_at)
             values (:id, :t, :u, :k, 'image/jpeg', 100, :n, now())""",
          id=undated_photo, t=japan, u=dave, n=PAST_DAY,
          k=photo_key(japan, undated_photo))
    d.run("update public.photos set caption = 'the long way round' where id = :id", id=undated_photo)
    check(db.run("select caption from public.photos where id = :id", id=undated_photo)[0][0]
          == "the long way round", "a contributor writes the word on their own photograph")
    c.try_run("update public.photos set caption = 'not hers to write' where id = :id",
              id=undated_photo)
    check(db.run("select caption from public.photos where id = :id", id=undated_photo)[0][0]
          == "the long way round", "and a co-member cannot rewrite it")
    status, rows = c.try_run(
        "select caption from public.photos where id = :id", id=undated_photo)
    check(status == "ok" and rows and rows[0][0] == "the long way round",
          "though she can read it -- the word travels with the photograph", repr(rows)[:60])
    status, rows = d.try_run(
        "update public.photos set caption = repeat('x', 281) where id = :id", id=undated_photo)
    check(status == "err" and "photos_caption_length_check" in str(rows),
          "and the column is bounded, so one phone cannot post a novel to seven others",
          repr(rows)[:80])

    # ------------------------------------------ what the download signs, 0011
    #
    # `r2-download-url` signs the row's own stored `r2_object_key` and never a
    # key derived from caller input. That promise is only worth anything if the
    # stored key is not itself caller input: `photos_update_contributor` places
    # no restriction on which columns a contributor may write, and `unique`
    # only stops a row taking a key another *photo row* holds -- a day page's
    # key lives in another table with another unique index.
    print("\n== an original is immutable, so a signed key cannot be repointed ==")
    status, rows = d.try_run(
        "update public.photos set r2_object_key = 'k/somewhere-else' where id = :id",
        id=undated_photo)
    check(status == "err" and "cannot be changed" in str(rows),
          "even its own contributor cannot repoint a row at another object", repr(rows)[:80])
    status, rows = d.try_run(
        """update public.photos set r2_object_key = 'trips/' || :t || '/pages/stolen.jpg'
           where id = :id""", t=iceland, id=undated_photo)
    check(status == "err" and "cannot be changed" in str(rows),
          "including at another trip's composed page, which no unique index would have caught",
          repr(rows)[:80])
    check(db.run("select r2_object_key from public.photos where id = :id",
                 id=undated_photo)[0][0] == photo_key(japan, undated_photo),
          "and the row still points where it always did")

    # ...and the other half of that, which the trigger structurally cannot do:
    # a BEFORE UPDATE trigger has no old row to compare against on INSERT, so
    # until `0011`'s CHECK a member could simply *start* with a foreign key.
    # `unique` catches only a key another `photos` row already holds -- a day
    # page's key lives in another table with another unique index -- and
    # `r2-download-url` would then sign it faithfully, because signing the
    # row's own stored key is exactly its promise. The promise is worth what
    # the stored key is worth, so the stored key is now bounded to the row's
    # own trip and its own id.
    print("\n== nor was the first claim free: a row may only claim its own folder ==")
    own = "ffffffff-0000-0000-0000-0000000000a1"
    status, rows = d.try_run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                      content_type, byte_size, day_number)
           values (:id, :t, :u, :k, 'image/jpeg', 100, :n)""",
        id=own, t=japan, u=dave, n=PAST_DAY, k=photo_key(japan, own))
    check(status == "ok",
          "a key built from the row's own trip and its own id is what the outbox mints",
          repr(rows)[:80])

    bad = "ffffffff-0000-0000-0000-0000000000b1"
    forgeries = (
        (photo_key(iceland, own),
         "another trip's folder, even for a photo id that is genuinely mine"),
        (photo_key(japan, PHOTO_C),
         "a co-member's photograph in my own trip -- the id is not a secret"),
        (f"trips/{japan}/pages/{own}.jpg",
         "a day page, whose key no unique index on photos would ever have caught"),
        (f"trips/{japan}/photos/{own}",
         "the folder itself rather than something inside it"),
        (f"x/trips/{japan}/photos/{own}/original.jpg",
         "the right folder with something prefixed in front of it"),
        (f"trips/{japan}/photos/{bad}/../../../../secret.jpg",
         "traversal segments that escape its own pinned folder"),
        (f"trips/{japan}/photos/{bad}//original.jpg",
         "an empty segment inside its own pinned folder"),
    )
    for key, what in forgeries:
        status, rows = d.try_run(
            """insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                          content_type, byte_size, day_number)
               values (:id, :t, :u, :k, 'image/jpeg', 100, :n)""",
            id=bad, t=japan, u=dave, n=PAST_DAY, k=key)
        check(status == "err" and "photos_object_key_own_prefix_check" in str(rows),
              f"but not {what}", repr(rows)[:90])
    check(db.run("select count(*) from public.photos where id = :id",
                 id="ffffffff-0000-0000-0000-0000000000b1")[0][0] == 0,
          "and none of them landed")

    # The `i` flag on `r2-upload-url`'s `UUID_RE` means it will sign a key whose
    # uuid segments are spelled in upper case, while `photos.id` renders lower.
    # The CHECK normalises deliberately: refusing that spelling would take the
    # bytes and *then* refuse the row, leaving an orphan and a retry that
    # re-mints the same rejected key forever.
    upper = "ffffffff-0000-0000-0000-0000000000c1"
    status, rows = d.try_run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                      content_type, byte_size, day_number)
           values (:id, :t, :u, :k, 'image/jpeg', 100, :n)""",
        id=upper, t=japan, u=dave, n=PAST_DAY,
        k=photo_key(japan, upper).upper())
    check(status == "ok",
          "an upper-cased spelling of the same folder is accepted, so no PUT is stranded",
          repr(rows)[:90])
    d.run("delete from public.photos where id = :id", id=upper)

    # The same class of free claim existed on `r2_thumbnail_key` -- nullable,
    # `unique`, no shape -- and it is the one the lock trigger deliberately
    # leaves open, because filling it in later from null is a legitimate write.
    # So the CHECK is the only thing guarding it, on INSERT and on that UPDATE.
    print("\n== a thumbnail is bounded to the same folder, or it is nothing ==")
    check(db.run("select r2_thumbnail_key from public.photos where id = :id",
                 id=own)[0][0] is None,
          "nothing generates one, so null is the ordinary state and stays allowed")
    status, rows = d.try_run(
        "update public.photos set r2_thumbnail_key = :k where id = :id",
        id=own, k=photo_key(iceland, own, "thumbnail.jpg"))
    check(status == "err" and "photos_thumbnail_key_own_prefix_check" in str(rows),
          "a thumbnail cannot be filled in with another trip's object", repr(rows)[:90])
    for key, what in (
        (photo_key(japan, own, "../stolen.jpg"), "a traversal segment"),
        (photo_key(japan, own, "/thumbnail.jpg"), "an empty segment"),
    ):
        status, rows = d.try_run(
            "update public.photos set r2_thumbnail_key = :k where id = :id",
            id=own, k=key)
        check(status == "err" and "photos_thumbnail_key_own_prefix_check" in str(rows),
              f"nor can a thumbnail contain {what}", repr(rows)[:90])
    status, rows = d.try_run(
        "update public.photos set r2_thumbnail_key = :k where id = :id",
        id=own, k=photo_key(japan, own, "thumbnail.jpg"))
    check(status == "ok" and db.run("select r2_thumbnail_key from public.photos where id = :id",
                                    id=own)[0][0] == photo_key(japan, own, "thumbnail.jpg"),
          "and one beside the original is what the column is for", repr(rows)[:90])
    d.run("delete from public.photos where id = :id", id=own)

    # ----------------------------------------------------- tombstones, 0011
    #
    # A person can always delete their own photograph and the row goes with no
    # visible gap. The object does not go anywhere -- RLS cannot reach R2 --
    # so the key is recorded for the sweeper, and for nobody else.
    print("\n== a deleted row leaves its object findable, and only to the sweeper ==")
    db.run("delete from public.photo_tombstones")
    d.run("delete from public.photos where id = :id", id=undated_photo)
    check(db.run("""select count(*) from public.photo_tombstones
                    where r2_object_key = :k and trip_id = :t""",
                 t=japan, k=photo_key(japan, undated_photo))[0][0] == 1,
          "deleting a photograph records its object key")
    status, rows = d.try_run("select count(*) from public.photo_tombstones")
    check(status == "ok" and rows[0][0] == 0,
          "which not even the person who deleted it can read -- RLS on, no policies at all",
          repr(rows)[:60])
    status, rows = d.try_run("delete from public.photo_tombstones")
    check(db.run("select count(*) from public.photo_tombstones")[0][0] == 1,
          "and nobody can clear one either", repr(rows)[:60])
    check(not db.run("""select 1 from information_schema.table_constraints
                        where table_schema = 'public' and table_name = 'photo_tombstones'
                          and constraint_type = 'FOREIGN KEY'"""),
          "and it carries no foreign key: deleting a trip must not delete the "
          "tombstones that delete cascade just wrote")

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
    c.run(
        "insert into public.trip_invites (trip_id, code, created_by) values (:t, 'puffin quartz 63', :u)",
        t=japan, u=carol)
    b.try_run("delete from public.trip_invites where code = 'puffin quartz 63'")
    check(db.run("select count(*) from public.trip_invites where code = 'puffin quartz 63'")[0][0]
          == 1, "a stranger still cannot revoke a member's code")
    c.run("delete from public.trip_invites where code = 'puffin quartz 63'")
    check(db.run("select count(*) from public.trip_invites where code = 'puffin quartz 63'")[0][0]
          == 0, "the member who minted a code can still revoke it")
    b.run("insert into public.trip_members (trip_id, user_id) values (:t, :u)",
          t=iceland, u=carol)
    c.run(
        "insert into public.trip_invites (trip_id, code, created_by) values (:t, 'puffin quartz 64', :u)",
        t=iceland, u=carol)
    b.run("delete from public.trip_invites where code = 'puffin quartz 64'")
    check(db.run("select count(*) from public.trip_invites where code = 'puffin quartz 64'")[0][0]
          == 0, "the starter can still revoke a member's code")
    c.run("delete from public.trip_members where trip_id = :t and user_id = :u",
          t=iceland, u=carol)
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
    grace = dart_grace_hours()
    check(db.run("select extract(epoch from public.trip_grace_after_end())")[0][0]
          == grace * 3600,
          f"the grace after a trip is the phone's {grace} hours, not a second number",
          repr(db.run("select public.trip_grace_after_end()")[0][0]))
    # Iceland has no itinerary rows, so it is 0016's fallback arm: a trip whose
    # plan has never reached the server closes exactly where `trips.end_date`
    # put it. Japan is no good for that here -- the gate section above has
    # already given it plan days dated off Asia/Tokyo's calendar, which runs a
    # day ahead of `current_date` for part of every UTC day, so pinning the
    # fallback on it fails whenever the probe runs late enough in the UTC day.
    # The arm that reads the plan is its own section further down.
    check(db.run("""select public.trip_closes_at(t.id)
                           = ((public.trip_last_planned_day(t.id) + 1)::timestamp
                              at time zone t.timezone)
                             + make_interval(hours => :g)
                    from public.trips t where t.id = :t""", t=japan, g=grace)[0][0] is True,
          "and a trip closes a grace after its last day ends, in its own clock, not UTC")
    check(db.run("select public.trip_last_planned_day(t.id) = t.end_date "
                 "from public.trips t where t.id = :t", t=iceland)[0][0] is True,
          "with a trip that has never synced a plan taking its recorded end date")

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

    # Ended yesterday, so it is inside the seventy-two hours whatever hour of
    # the day this probe is run at.
    fresh = str(b.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('Just back', :u, 'Atlantic/Reykjavik', current_date - 5, current_date - 1)
           returning id""", u=bob)[0][0])
    b.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, 'puffin quartz 62', :u)",
          t=fresh, u=bob)
    status, rows = d.try_run("select public.redeem_trip_invite('puffin quartz 62')")
    check(status == "ok", "a trip that ended inside the grace still lets someone in", repr(rows)[:90])
    check(db.run("select count(*) from public.trip_members where trip_id = :t and user_id = :u",
                 t=fresh, u=dave)[0][0] == 1,
          "which is what the grace is for: the photos are still coming")

    # ------------------------------------------ and the close shuts the pool
    print("\n== the grace takes photographs; the close takes none ==")
    late = "ffffffff-0000-0000-0000-000000000002"
    status, rows = d.try_run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key, content_type,
                                      byte_size, day_number)
           values (:id, :t, :u, :k, 'image/jpeg', 10, 1)""",
        id=late, t=fresh, u=dave, k=photo_key(fresh, late))
    check(status == "ok",
          "a photo taken on the way home still lands, days after the trip ended",
          repr(rows)[:90])

    # Bob is on last year's trip: he started it. So this refusal is the close
    # and nothing else -- not membership, and not a trip he cannot see.
    too_late = "ffffffff-0000-0000-0000-000000000003"
    status, rows = b.try_run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key, content_type,
                                      byte_size, day_number)
           values (:id, :t, :u, :k, 'image/jpeg', 10, 1)""",
        id=too_late, t=stale, u=bob, k=photo_key(stale, too_late))
    check(status == "err" and "row-level security" in str(rows),
          "and a member of a closed trip cannot add to it -- the record is fixed",
          repr(rows)[:90])
    check(db.run("select count(*) from public.photos where trip_id = :t", t=stale)[0][0] == 0,
          "so nothing landed in last year's archive")

    # What the close does not take: your own photograph stays yours.
    db.run("update public.trips set end_date = current_date - 40, start_date = current_date - 44 "
           "where id = :t", t=fresh)
    status, _ = d.try_run("update public.photos set trip_day = current_date - 42 where id = :id", id=late)
    check(status == "ok",
          "a person can still correct which day their own photo landed on, after the close")
    status, _ = d.try_run("delete from public.photos where id = :id", id=late)
    check(status == "ok" and db.run("select count(*) from public.photos where id = :id",
                                    id=late)[0][0] == 0,
          "and can still take it out -- the close shuts the door on new photographs, "
          "not on your hold over your own")

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

    b.run("""insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                       content_type, byte_size, day_number)
             values (:id, :t, :u, :k, 'image/jpeg', 10, 1)""",
          id=PHOTO_B, t=iceland, u=bob, k=photo_key(iceland, PHOTO_B))
    db.run("insert into public.trip_members (trip_id, user_id) values (:t, :u)", t=iceland, u=carol)
    status, rows = c.try_run(
        "insert into public.day_page_photos (day_page_id, ordinal, photo_id) values (:p, 6, :ph)",
        p=page, ph=PHOTO_B)
    check(status == "err", "but not one from another trip, even one it is also a member of",
          repr(rows)[:80])

    status, rows = c.try_run(
        "update public.day_pages set trip_id = :t where id = :p",
        t=iceland, p=page)
    check(status == "err" and "day_pages.trip_id cannot be changed" in str(rows),
          "and a composed page cannot be moved to another trip", repr(rows)[:90])
    check(str(db.run("select trip_id from public.day_pages where id = :p", p=page)[0][0])
          == str(japan), "so it remains in the trip where it was composed")

    print("\n== an invite cannot be repointed to another trip ==")
    before_trip = db.run("select trip_id from public.trip_invites where code = 'cedar willow 27'")[0][0]
    status, rows = c.try_run(
        "update public.trip_invites set trip_id = :t where code = 'cedar willow 27'", t=iceland)
    check(status == "err", "even by its own creator, to a trip she also belongs to", repr(rows)[:80])
    after_trip = db.run("select trip_id from public.trip_invites where code = 'cedar willow 27'")[0][0]
    check(str(after_trip) == str(before_trip), "and the row's trip_id is unchanged",
          f"{before_trip} -> {after_trip}")

    # The same lock, for the same reason, on the row the close actually
    # freezes. `photos_insert_trip_member` shuts a closed trip's pool, and a
    # photo that could be repointed afterwards would walk straight round it.
    print("\n== nor can a photo be repointed to another trip ==")
    c.run("""insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                       content_type, byte_size, day_number)
             values (:id, :t, :u, :k, 'image/jpeg', 10, 1)""",
          id=PHOTO_D, t=iceland, u=carol, k=photo_key(iceland, PHOTO_D))
    status, rows = c.try_run(
        "update public.photos set trip_id = :t where id = :id", t=japan, id=PHOTO_D)
    check(status == "err" and "cannot be changed" in str(rows),
          "even by the person who took it, into a trip she is also on", repr(rows)[:80])
    check(str(db.run("select trip_id from public.photos where id = :id", id=PHOTO_D)[0][0])
          == str(iceland),
          "and it is still in the trip it was taken on")

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

    # The merged plan comes back in the plan's own order, and the day number is
    # a number. Ordering it as text hands back 1, 10, 11, 12, 2, 3... which the
    # phone's settled-check reads as a plan that disagrees with its own, so it
    # writes, and its own stream asks for the next sync, forever. Every check
    # above indexes the days into a dict before asserting, which is exactly why
    # none of them could see it -- so assert the array itself, and with enough
    # days for a text sort to differ from a numeric one.
    long_plan = [day(n, T3, f"Stop {n}") for n in range(1, 13)]
    status, plan = sync(b, norway, T3, long_plan)
    returned = [d["day_number"] for d in plan["days"]]
    check(status == "ok" and returned == list(range(1, 13)),
          "a plan of twelve days comes back in ascending numeric day order",
          repr(returned))
    status, plan = sync(c, norway, "-infinity", [])
    returned = [d["day_number"] for d in plan["days"]]
    check(returned == list(range(1, 13)),
          "and a pure pull is ordered the same way, not by the text of the number",
          repr(returned))

    # ---- the tap-to-Maps areas ride the same cargo (0012 columns, 0013 sync) --
    #
    # 0012 added the columns; until 0013 the function inserted and returned the
    # old column set, so an area corrected on one phone was stripped on push
    # and absent on pull -- a correction that never left the phone that made
    # it. The columns being present in the table is not the property; the
    # round trip is.
    print("\n== a corrected area travels between phones ==")
    T4 = "2027-06-04T00:00:00Z"
    corrected = {
        "day_number": 1, "day_date": None, "place": "Oslo", "revised_at": T4,
        "stops": [
            {"position": 0, "stop_text": "Vigeland", "time_of_day": None,
             "kind": "place", "area_text": "Frogner", "area_source": "human"},
            {"position": 1, "stop_text": "lunch", "time_of_day": None,
             "kind": "meal", "area_text": None, "area_source": None},
        ],
    }
    status, plan = sync(b, norway, T4, [corrected])
    stops = numbered(plan)[1]["stops"]
    check(status == "ok"
          and [(s["kind"], s["area_text"], s["area_source"]) for s in stops]
              == [("place", "Frogner", "human"), ("meal", None, None)],
          "a pushed area comes back off the same round trip, source and all",
          repr(stops))

    # Carol never touched the plan: what she pulls is the only evidence the
    # correction actually crossed between two phones.
    status, plan = sync(c, norway, "-infinity", [])
    stops = numbered(plan)[1]["stops"]
    check([(s["kind"], s["area_text"]) for s in stops]
          == [("place", "Frogner"), ("meal", None)],
          "and another member's pure pull carries it, which is the whole point",
          repr(stops))

    # Every key is emitted even when the value is null. `RemoteStop.carriesAreas`
    # reads the key's *absence* as "this server does not know about areas" and
    # leaves a local correction standing; a function that dropped the null key
    # would make clearing an area impossible from any other phone.
    check(all({"kind", "area_text", "area_source"} <= set(s) for s in stops),
          "a stop with no area still carries all three keys, spelled null",
          repr(sorted(stops[1])))

    # A phone built before 0012 sends no `kind` at all. The column is
    # `not null default 'place'`, and an insert list naming the column defeats
    # that default, so the function says it instead.
    old_phone = {
        "day_number": 2, "day_date": None, "place": "Bergen", "revised_at": T4,
        "stops": [{"position": 0, "stop_text": "Bryggen", "time_of_day": None}],
    }
    status, plan = sync(b, norway, T4, [corrected, old_phone])
    stops = numbered(plan)[2]["stops"]
    check(status == "ok" and stops[0]["kind"] == "place"
          and stops[0]["area_text"] is None,
          "a push from a phone that predates the columns still stores a kind",
          repr(stops))

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

    # ---------------------------------------- and a closed trip's plan is fixed
    #
    # The phone refuses first (`TripSync._reconcile` -> `SyncStanding.archived`),
    # and this is the other half of it, for the reason the pool's close has two:
    # eight phones means one wrong clock. Judged on the table afterwards and not
    # only on the raise, per invariant 6 -- the refusal has to happen before the
    # first insert, not after a half-written merge.
    print("\n== a closed trip's plan is the record, and takes no more pushes ==")
    before_days = db.run("select day_number, place, day_date from public.trip_itinerary_days "
                         "where trip_id = :t order by day_number", t=norway)
    db.run("update public.trips set start_date = current_date - 44, "
           "end_date = current_date - 40 where id = :t", t=norway)
    status, rows = sync(b, norway, T3, [day(1, T3, "Rewritten"), day(9, T3, "Invented")])
    check(status == "err" and "closed" in str(rows),
          "pushing a plan into a closed trip is refused", repr(rows)[:90])
    after_days = db.run("select day_number, place, day_date from public.trip_itinerary_days "
                        "where trip_id = :t order by day_number", t=norway)
    check(after_days == before_days,
          "and nothing was written -- no day rewritten and no day invented",
          f"{before_days} -> {after_days}")
    status, rows = sync(c, norway, "-infinity", [])
    check(status == "err" and "closed" in str(rows),
          "and the pull is refused with it: after the close there is nothing to reconcile",
          repr(rows)[:90])
    db.run("update public.trips set start_date = current_date, "
           "end_date = current_date + 4 where id = :t", t=norway)
    status, rows = sync(c, norway, "-infinity", [])
    check(status == "ok", "while the same call on the same trip, still open, goes through",
          repr(rows)[:90])

    # ---------------------------------------------- the close follows the plan
    #
    # 0016. `trips.start_date`/`end_date`/`timezone` are written once by
    # `_createSharedTrip` and never again, so before 0016 a trip postponed or
    # extended after its first sync was refused by every one of the four gated
    # paths from its OLD last day plus the grace onward, while every phone drew
    # it as live. The close is now derived from `trip_itinerary_days`, which is
    # the same sentence `cairn_model`'s `tripEndsAtFrom` says on the phone.
    #
    # Each shape below is built the only way the gate permits: the trip is
    # created open, a member pushes the plan through the real function, and
    # then the frozen columns are moved to what they were at creation. That
    # last step stands in for the days passing since first sync -- it writes
    # nothing the app would not already have written, because the app writes
    # those columns once and the itinerary is what moves afterwards.
    print("\n== the close follows the plan, not the snapshot the trip was created with ==")

    grace_hours = dart_grace_hours()

    def offset(n):
        """A bare calendar date n days from today, as the plan would carry it."""
        return (db.run("select (current_date + (:n)::integer)::text", n=n)[0][0])

    def dated(n, date, revised="2027-07-01T00:00:00Z", place="Somewhere"):
        return {"day_number": n, "day_date": date, "place": place,
                "revised_at": revised, "stops": []}

    plan_shapes = []

    def trip_with(label, frozen_start, frozen_end, day_dates, code):
        """A trip whose `trips` row froze at one span while its plan says another."""
        trip = str(b.run(
            """insert into public.trips (name, created_by, timezone, start_date, end_date)
               values (:n, :u, 'Europe/Oslo', current_date, current_date + 4)
               returning id""", n=label, u=bob)[0][0])
        b.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, :c, :u)",
              t=trip, c=code, u=bob)
        c.run("select public.redeem_trip_invite(:c)", c=code)
        status, rows = sync(b, trip, "2027-07-01T00:00:00Z",
                            [dated(i + 1, d) for i, d in enumerate(day_dates)])
        check(status == "ok", f"[{label}] the plan reaches the server while the trip is open",
              repr(rows)[:90])
        db.run("update public.trips set start_date = :s, end_date = :e where id = :t",
               s=frozen_start, e=frozen_end, t=trip)
        plan_shapes.append((label, trip))
        return trip

    def all_four_gates(label, trip, day_dates, joiner_code, expect_open):
        """Every path `trip_closes_at` gates, asked at once.

        The four are `sync_trip_itinerary` (0010), `photos_insert_trip_member`
        (0006), `redeem_trip_invite` (0005) and `guard_member_trip_rename` /
        `sync_trip_name` (0014). Fixing one and leaving three reading the old
        column is exactly the failure this asks about, so they are asked
        together and never one at a time.
        """
        word = "still open" if expect_open else "refused"

        # The trip's own shape, re-pushed with a newer clock. Pushing a
        # *shorter* plan here would delete the days that make this shape what it
        # is (0010's deletion rule) and quietly turn every later check into a
        # check about one day.
        status, rows = sync(b, trip, "2027-08-01T00:00:00Z",
                            [dated(i + 1, d, revised="2027-08-01T00:00:00Z")
                             for i, d in enumerate(day_dates)])
        check((status == "ok") == expect_open,
              f"[{label}] pushing the itinerary is {word}", repr(rows)[:90])

        photo = "0016%s-0000-0000-0000-%012d" % ("0000", len(plan_shapes) * 10 + 1)
        status, rows = b.try_run(
            """insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                          content_type, byte_size, day_number)
               values (:id, :t, :u, :k, 'image/jpeg', 10, 1)""",
            id=photo, t=trip, u=bob, k=photo_key(trip, photo))
        landed = db.run("select count(*) from public.photos where id = :id", id=photo)[0][0]
        check((landed == 1) == expect_open,
              f"[{label}] taking a photograph is {word}", repr(rows)[:90])

        b.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, :c, :u)",
              t=trip, c=joiner_code, u=bob)
        d.try_run("select public.redeem_trip_invite(:c)", c=joiner_code)
        joined = db.run("select count(*) from public.trip_members where trip_id = :t and user_id = :u",
                        t=trip, u=dave)[0][0]
        check((joined == 1) == expect_open,
              f"[{label}] redeeming a code is {word}",
              f"members with dave: {joined}")

        wanted = label + " renamed"
        c.try_run("select public.sync_trip_name(:t, :n, now())", t=trip, n=wanted)
        named = db.run("select name from public.trips where id = :t", t=trip)[0][0]
        check((named == wanted) == expect_open,
              f"[{label}] renaming through sync_trip_name is {word}", repr(named))

        patched = label + " patched"
        b.try_run("update public.trips set name = :n, name_revised_at = now() where id = :t",
                  t=trip, n=patched)
        named = db.run("select name from public.trips where id = :t", t=trip)[0][0]
        check((named == patched) == expect_open,
              f"[{label}] and the bare PATCH round it is {word} too", repr(named))

    def closes_on(trip, expected_date):
        """The close is that date's next midnight in the *trip's* zone, plus the grace.

        Asserted in SQL against `trips.timezone` rather than recomputed in
        Python, because the zone the derivation resolves in is the whole of
        what 0016 had to state: not UTC, and not the caller's.
        """
        return db.run(
            """select public.trip_closes_at(t.id)
                      = (((:d)::date + 1)::timestamp at time zone t.timezone)
                        + make_interval(hours => :g)
               from public.trips t where t.id = :t""",
            t=trip, d=expected_date, g=grace_hours)[0][0] is True

    # ---- postponed by a week ------------------------------------------------
    # The plan the trips row froze ran 11 to 7 days ago; the itinerary now runs
    # 4 days ago to today. Before 0016 every gate below was shut.
    postponed = trip_with("postponed", offset(-11), offset(-7),
                          [offset(-4), offset(-3), offset(-2), offset(-1), offset(0)],
                          "dolphin lagoon 11")
    check(closes_on(postponed, offset(0)),
          "a plan postponed after first sync closes a grace after its NEW last day")
    all_four_gates("postponed", postponed,
                   [offset(-4), offset(-3), offset(-2), offset(-1), offset(0)],
                   "dolphin lagoon 12", expect_open=True)

    # ---- extended ----------------------------------------------------------
    extended = trip_with("extended", offset(-8), offset(-4),
                         [offset(-8), offset(-4), offset(0), offset(3)],
                         "kestrel juniper 11")
    check(closes_on(extended, offset(3)),
          "and days added past the frozen end keep the trip open to the end of them")
    all_four_gates("extended", extended,
                   [offset(-8), offset(-4), offset(0), offset(3)],
                   "kestrel juniper 12", expect_open=True)

    # ---- shortened: the floor holds, by design -----------------------------
    # The close follows the plan upward only. `trips.end_date` is an
    # unconditional floor under the derivation (0016), so a plan cut short
    # keeps the window it froze with rather than closing on its new last day.
    # That is what makes a mis-dated plan repairable: `sync_trip_itinerary`
    # asks `trip_closes_at` before it merges a day, so a close that could move
    # earlier would refuse the very push that corrects it -- including another
    # phone's. This shape is the regression test for that floor.
    shortened = trip_with("shortened", offset(-2), offset(14),
                          [offset(-2), offset(-1)],
                          "narwhal orchard 11")
    check(closes_on(shortened, offset(14)),
          "a plan cut short does not close earlier -- the frozen end is a floor, by design")
    check(db.run("select public.trip_closes_at(:t) > "
                 "(((current_date - 1 + 1)::timestamp at time zone 'Europe/Oslo')"
                 " + make_interval(hours => :g))", t=shortened, g=grace_hours)[0][0] is True,
          "which is strictly later than the shortened plan's own last day would have given")
    all_four_gates("shortened", shortened, [offset(-2), offset(-1)],
                   "narwhal orchard 12", expect_open=True)

    # ---- a wholly undated plan ---------------------------------------------
    # The documented fallback (0016): an itinerary that states no date at all
    # says nothing about when the trip ends, so the close falls back to
    # `trips.end_date` -- bounded, never unbounded, and the same answer the
    # trip had before this migration. That is what makes 0016 need no backfill.
    undated_open = trip_with("undated and open", offset(-2), offset(2),
                             [None, None, None], "pebble thistle 11")
    check(closes_on(undated_open, offset(2)),
          "an undated plan falls back to the trip's own recorded end -- not to never")
    all_four_gates("undated and open", undated_open, [None, None, None],
                   "pebble thistle 12", expect_open=True)

    undated_past = trip_with("undated and over", offset(-11), offset(-7),
                             [None, None, None], "velvet zephyr 11")
    check(closes_on(undated_past, offset(-7)),
          "and an undated plan whose recorded end is long past is closed, exactly as before")
    all_four_gates("undated and over", undated_past, [None, None, None],
                   "velvet zephyr 12", expect_open=False)

    # ---- an undated tail ---------------------------------------------------
    # The plan does not state its end, and the dated days it does carry are
    # evidence too, so the later of those and the frozen floor wins. Both
    # directions of that `greatest` are exercised below, because the floor is
    # unconditional and either arm may be the one that answers.
    tail = trip_with("undated tail", offset(-11), offset(-7),
                     [offset(-1), offset(0), None], "urchin yarrow 11")
    check(closes_on(tail, offset(0)),
          "an undated tail takes the furthest date the plan does state, over a stale frozen end")
    all_four_gates("undated tail", tail, [offset(-1), offset(0), None],
                   "urchin yarrow 12", expect_open=True)

    tail_floor = trip_with("undated tail, later floor", offset(-2), offset(6),
                           [offset(-2), offset(-1), None], "tapir quokka 11")
    check(closes_on(tail_floor, offset(6)),
          "and keeps the frozen end when that is the later of the two -- a floor, never a cut")

    # ---- a trip with no itinerary at all -----------------------------------
    # Every trip that has never synced a plan, which on the hosted project is
    # most of them, and the reason a live trip survives this migration.
    bare = str(b.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('No plan yet', :u, 'Europe/Oslo', current_date, current_date + 4)
           returning id""", u=bob)[0][0])
    check(db.run("select count(*) from public.trip_itinerary_days where trip_id = :t",
                 t=bare)[0][0] == 0,
          "a trip whose itinerary has never reached the server has no days at all")
    check(closes_on(bare, offset(4)),
          "and closes exactly where it closed before 0016 -- no backfill, nothing to survive")

    # ---- one rule, written twice -------------------------------------------
    # `tripEndsAtFrom` takes the LAST day in plan order and this takes the
    # furthest date in the plan. They agree on every plan a person can build by
    # dating one and letting the fill run down it, and where they can differ --
    # a middle day dated past the last one -- the server is deliberately the
    # later of the two. The server refusing a trip a phone draws as live is the
    # defect 0016 exists to end, so the asymmetry only ever runs this way.
    print("\n== the server's close is never earlier than the phone's ending ==")
    crooked = trip_with("out of order", offset(-2), offset(1),
                        [offset(-2), offset(6), offset(0)], "summit ribbon 11")
    check(closes_on(crooked, offset(6)),
          "a middle day dated past the last one lengthens the window, never shortens it")
    for label, trip in plan_shapes:
        # `tripEndsAtFrom` takes the last day in plan order and reads an undated
        # one as an ending nobody knows, so the comparison is null there rather
        # than false: that is the one place the two halves deliberately differ,
        # and 0016's comment says so out loud.
        verdict = db.run(
            """select case
                        when (select d.day_date
                                from public.trip_itinerary_days d
                               where d.trip_id = t.id
                               order by d.day_number desc limit 1) is null
                          then null
                        else public.trip_closes_at(t.id)
                             >= ((select (d.day_date + 1)::timestamp at time zone t.timezone
                                    from public.trip_itinerary_days d
                                   where d.trip_id = t.id
                                   order by d.day_number desc limit 1)
                                 + make_interval(hours => :g))
                      end
               from public.trips t where t.id = :t""", t=trip, g=grace_hours)[0][0]
        if verdict is None:
            continue
        check(verdict is True,
              f"[{label}] the close is at or after the phone's own ending plus the grace")

    # ---- and never earlier than the close 0016 replaced ---------------------
    # The second invariant, and the one that makes every close-move repairable:
    # `trips.end_date` is an unconditional floor, so no push can ever leave the
    # server more closed than 0005's formula did -- which is what keeps a
    # mis-dated plan from shutting `sync_trip_itinerary` against its own
    # correction. This holds for every shape, undated ones included, so nothing
    # is skipped here.
    for label, trip in plan_shapes + [("no plan yet", bare)]:
        check(db.run(
            """select public.trip_closes_at(t.id)
                      >= (((t.end_date + 1)::timestamp at time zone t.timezone)
                          + make_interval(hours => :g))
               from public.trips t where t.id = :t""",
            t=trip, g=grace_hours)[0][0] is True,
            f"[{label}] and at or after the close the frozen end_date gave before 0016")

    # ---- the close is a property of the record, not of one function --------
    # Deriving the close from `trip_itinerary_days` puts it on a table clients
    # write, and 0010's policies there carry no close condition. Without a
    # guard on the table itself a member of an archived trip could date one of
    # its days forward, watch `greatest` lift the close, and re-open the
    # record. 0016's `trip_itinerary_days_guard_closed_trip` is the refusal,
    # and it is asked here through the table rather than through
    # `sync_trip_itinerary`, because a bare PATCH is the door it exists to
    # shut.
    print("\n== a closed trip's plan is the record, and the table says so ==")
    closed = str(b.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('The record', :u, 'Europe/Oslo', current_date, current_date + 4)
           returning id""", u=bob)[0][0])
    # Minted while the trip is still open, which is the only interesting case:
    # a code carries no expiry of its own and dies at `trip_closes_at`.
    b.run("insert into public.trip_invites (trip_id, code, created_by) values (:t, :c, :u)",
          t=closed, c="beacon lantern 11", u=bob)
    # The plan is pushed complete -- days, a stop under one of them and a line
    # in the set-aside pocket -- because 0017 widened the refusal from the days
    # to all four of the itinerary's tables, and a record with nothing but days
    # in it could not tell whether the other three were fixed or merely empty.
    kept_line = [{"position": 0, "source_line_number": 9,
                  "line_text": "book the cabin", "explanation": "no day named"}]
    status, rows = sync(b, closed, "2027-07-01T00:00:00Z",
                        [dated(1, offset(-11)), dated(2, offset(-9)),
                         {**dated(3, offset(-7)),
                          "stops": [{"position": 0, "stop_text": "Bryggen",
                                     "time_of_day": None}]}],
                        pocket_at="2027-07-01T00:00:00Z", pocket=kept_line)
    check(status == "ok", "[the record] the plan reaches the server while the trip is open",
          repr(rows)[:90])
    db.run("update public.trips set start_date = :s, end_date = :e where id = :t",
           s=offset(-11), e=offset(-7), t=closed)
    check(closes_on(closed, offset(-7)), "[the record] and the trip is closed afterwards")

    status, rows = b.try_run(
        "update public.trip_itinerary_days set day_date = :d "
        "where trip_id = :t and day_number = 3", d=offset(30), t=closed)
    check(status == "err" and "this trip has closed" in str(rows),
          "a member cannot re-open a closed trip by dating one of its days forward",
          repr(rows)[:90])
    check(closes_on(closed, offset(-7)), "and the close is exactly where it was")

    status, rows = b.try_run(
        """insert into public.trip_itinerary_days (trip_id, day_number, day_date, place, revised_at)
           values (:t, 4, :d, 'Somewhere', now())""", t=closed, d=offset(30))
    check(status == "err" and "this trip has closed" in str(rows),
          "nor by adding a day past the close", repr(rows)[:90])

    status, rows = b.try_run(
        "delete from public.trip_itinerary_days where trip_id = :t and day_number = 1", t=closed)
    check(status == "err" and "this trip has closed" in str(rows),
          "and a closed trip's days cannot be deleted either -- the plan is the record",
          repr(rows)[:90])
    check(db.run("select count(*) from public.trip_itinerary_days where trip_id = :t",
                 t=closed)[0][0] == 3,
          "so the stored plan is unchanged by all three attempts")

    # ---- and the other three tables of the plan, since 0017 ----------------
    # None of these can move the close -- only `day_date` does that -- so the
    # refusal here is not about the re-opening attack at all. It is the plainer
    # half of the same sentence: a closed trip's plan is the record, and the
    # record is what the trip did, which is the stops and the lines nobody
    # placed as much as the dates.
    for table, sql, params, what in (
        ("trip_itinerary_stops",
         "update public.trip_itinerary_stops set stop_text = 'Somewhere else' "
         "where trip_id = :t and day_number = 3 and position = 0", {},
         "a member cannot rewrite what a closed trip's afternoon was"),
        ("trip_itinerary_stops",
         """insert into public.trip_itinerary_stops
              (trip_id, day_number, position, stop_text, time_of_day)
            values (:t, 3, 1, 'Never happened', null)""", {},
         "nor add a stop the trip never made"),
        ("trip_itinerary_stops",
         "delete from public.trip_itinerary_stops "
         "where trip_id = :t and day_number = 3 and position = 0", {},
         "nor take one out of the record"),
        ("trip_itinerary_set_asides",
         "update public.trip_itinerary_set_asides set line_text = 'rewritten' "
         "where trip_id = :t and position = 0", {},
         "a member cannot reword a line the parser could not place"),
        ("trip_itinerary_set_asides",
         """insert into public.trip_itinerary_set_asides
              (trip_id, position, source_line_number, line_text, explanation)
            values (:t, 1, 12, 'invented', 'no day named')""", {},
         "nor add one to the pocket after the fact"),
        ("trip_itinerary_set_asides",
         "delete from public.trip_itinerary_set_asides where trip_id = :t and position = 0", {},
         "nor empty the pocket -- 'nothing the person pasted is ever deleted' "
         "outlives the trip"),
        ("trip_itineraries",
         "update public.trip_itineraries set plan_revised_at = :r where trip_id = :t",
         {"r": "2099-01-01T00:00:00Z"},
         "a member cannot wind the plan's merge clock forward"),
    ):
        status, rows = b.try_run(sql, t=closed, **params)
        check(status == "err" and "this trip has closed" in str(rows),
              f"[{table}] {what}", repr(rows)[:90])

    # The header row's DELETE is the one write of the eight that RLS refuses
    # before the guard is ever asked: 0010 gives `trip_itineraries` a SELECT, an
    # INSERT and an UPDATE policy and no DELETE policy at all. RLS refuses by
    # filtering to zero rows rather than raising, so this comes back "ok" with
    # nothing deleted -- which is why it is asserted on the row's survival and
    # not on the error the other seven raise. The trigger covers DELETE anyway,
    # because a policy is a thing a later migration can add and the guard should
    # not have to be remembered when it does.
    status, rows = b.try_run("delete from public.trip_itineraries where trip_id = :t", t=closed)
    check(db.run("select count(*) from public.trip_itineraries where trip_id = :t",
                 t=closed)[0][0] == 1,
          "[trip_itineraries] and nobody throws a closed trip's revision clocks away -- "
          "there is no DELETE policy to reach the guard through",
          repr(rows)[:90])

    survived = db.run(
        """select (select count(*) from public.trip_itinerary_stops
                    where trip_id = :t and stop_text = 'Bryggen'),
                  (select count(*) from public.trip_itinerary_set_asides
                    where trip_id = :t and line_text = 'book the cabin'),
                  (select count(*) from public.trip_itineraries
                    where trip_id = :t and plan_revised_at = :r::timestamptz)
        """, t=closed, r="2027-07-01T00:00:00Z")[0]
    check(list(survived) == [1, 1, 1],
          "and every one of those tables still says exactly what the trip left behind",
          repr(survived))

    # The header row's INSERT, which the trip above cannot show because it
    # already has one. A closed trip that never synced a plan must not gain one
    # afterwards either -- that is the same door, standing open on an emptier
    # room.
    never_synced = str(b.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('Never told anyone', :u, 'Europe/Oslo', current_date, current_date + 4)
           returning id""", u=bob)[0][0])
    db.run("update public.trips set start_date = :s, end_date = :e where id = :t",
           s=offset(-11), e=offset(-7), t=never_synced)
    status, rows = b.try_run(
        "insert into public.trip_itineraries (trip_id, plan_revised_at) values (:t, now())",
        t=never_synced)
    check(status == "err" and "this trip has closed" in str(rows),
          "[trip_itineraries] and a closed trip that never synced gains no plan now",
          repr(rows)[:90])
    status, rows = b.try_run(
        """insert into public.trip_itinerary_set_asides
             (trip_id, position, source_line_number, line_text, explanation)
           values (:t, 0, 1, 'after the fact', 'no day named')""", t=never_synced)
    check(status == "err" and "this trip has closed" in str(rows),
          "[trip_itinerary_set_asides] nor a pocket", repr(rows)[:90])
    b.run("delete from public.trips where id = :t", t=never_synced)

    # What the refusal is actually protecting, asked after the attempt rather
    # than instead of it.
    d.try_run("select public.redeem_trip_invite('beacon lantern 11')")
    check(db.run("select count(*) from public.trip_members where trip_id = :t and user_id = :u",
                 t=closed, u=dave)[0][0] == 0,
          "a code minted before the close still admits nobody after it")
    reopen_photo = "0016dead-0000-0000-0000-000000000001"
    b.try_run(
        """insert into public.photos (id, trip_id, contributor_id, r2_object_key,
                                      content_type, byte_size, day_number)
           values (:id, :t, :u, :k, 'image/jpeg', 10, 1)""",
        id=reopen_photo, t=closed, u=bob, k=photo_key(closed, reopen_photo))
    check(db.run("select count(*) from public.photos where id = :id",
                 id=reopen_photo)[0][0] == 0,
          "and the archived record still takes no new photograph")

    # The other half: an open trip is untouched, including the merge's own
    # deletions, which now pass through the same trigger.
    live = str(b.run(
        """insert into public.trips (name, created_by, timezone, start_date, end_date)
           values ('Still going', :u, 'Europe/Oslo', current_date, current_date + 4)
           returning id""", u=bob)[0][0])
    status, rows = sync(b, live, "2027-07-01T00:00:00Z",
                        [dated(1, offset(0)), dated(2, offset(1))])
    check(status == "ok", "[still going] an open trip's plan syncs exactly as before",
          repr(rows)[:90])
    status, rows = b.try_run(
        """insert into public.trip_itinerary_days (trip_id, day_number, day_date, place, revised_at)
           values (:t, 3, :d, 'Somewhere', now())""", t=live, d=offset(2))
    check(status == "ok", "a member of an open trip may still insert a day", repr(rows)[:90])
    status, rows = b.try_run(
        "update public.trip_itinerary_days set day_date = :d "
        "where trip_id = :t and day_number = 3", t=live, d=offset(3))
    check(status == "ok", "and may still re-date one", repr(rows)[:90])
    status, rows = sync(b, live, "2027-08-01T00:00:00Z",
                        [dated(1, offset(0), revised="2027-08-01T00:00:00Z"),
                         dated(2, offset(1), revised="2027-08-01T00:00:00Z")])
    check(status == "ok" and db.run(
              "select count(*) from public.trip_itinerary_days where trip_id = :t",
              t=live)[0][0] == 2,
          "and the merge's own day deletion still runs through the trigger", repr(rows)[:90])
    status, rows = b.try_run(
        "delete from public.trip_itinerary_days where trip_id = :t and day_number = 2", t=live)
    check(status == "ok" and db.run(
              "select count(*) from public.trip_itinerary_days where trip_id = :t",
              t=live)[0][0] == 1,
          "as does a member's own delete", repr(rows)[:90])

    # The same half for the three tables 0017 added, one write of each shape.
    # Nothing about an open trip may have changed: the guard is asked, answers
    # "still open", and gets out of the way.
    for table, sql, params, what in (
        ("trip_itinerary_stops",
         """insert into public.trip_itinerary_stops
              (trip_id, day_number, position, stop_text, time_of_day)
            values (:t, 1, 0, 'Holmenkollen', null)""", {},
         "a member of an open trip may still add a stop"),
        ("trip_itinerary_stops",
         "update public.trip_itinerary_stops set stop_text = 'Bryggen' "
         "where trip_id = :t and day_number = 1 and position = 0", {},
         "and reword it"),
        ("trip_itinerary_stops",
         "delete from public.trip_itinerary_stops "
         "where trip_id = :t and day_number = 1 and position = 0", {},
         "and take it out again"),
        ("trip_itinerary_set_asides",
         """insert into public.trip_itinerary_set_asides
              (trip_id, position, source_line_number, line_text, explanation)
            values (:t, 0, 3, 'book the cabin', 'no day named')""", {},
         "may still set a line aside"),
        ("trip_itinerary_set_asides",
         "update public.trip_itinerary_set_asides set explanation = 'taken out by hand' "
         "where trip_id = :t and position = 0", {},
         "and say why differently"),
        ("trip_itinerary_set_asides",
         "delete from public.trip_itinerary_set_asides where trip_id = :t and position = 0", {},
         "and empty the pocket"),
        ("trip_itineraries",
         "update public.trip_itineraries set plan_revised_at = :r where trip_id = :t",
         {"r": "2027-09-01T00:00:00Z"},
         "and the plan's merge clock still moves"),
    ):
        status, rows = b.try_run(sql, t=live, **params)
        check(status == "ok", f"[still going] [{table}] {what}", repr(rows)[:90])

    # The one path that reaches the stops' trigger without being a member's own
    # write: deleting a day cascades into its stops, and the cascade runs as the
    # referencing table's owner rather than as `authenticated`. Asserted on an
    # open trip because that is where it actually happens; the closed trip's
    # own discard below asserts the other end of the same branch.
    b.run("""insert into public.trip_itinerary_days
               (trip_id, day_number, day_date, place, revised_at)
             values (:t, 9, :d, 'Cascade', now())""", t=live, d=offset(4))
    b.run("""insert into public.trip_itinerary_stops
               (trip_id, day_number, position, stop_text, time_of_day)
             values (:t, 9, 0, 'Under a day about to go', null)""", t=live)
    status, rows = b.try_run(
        "delete from public.trip_itinerary_days where trip_id = :t and day_number = 9", t=live)
    check(status == "ok" and db.run(
              "select count(*) from public.trip_itinerary_stops "
              "where trip_id = :t and day_number = 9", t=live)[0][0] == 0,
          "and deleting an open trip's day still cascades into its stops through the guard",
          repr(rows)[:90])

    # Discarding a record is not editing it: `canDeleteTrip` is the deliberate
    # exception to the read-only rule, and the cascade into
    # `trip_itinerary_days` arrives at this trigger as a delete on a closed
    # trip -- the one shape it refuses. Both of the trigger's allowing branches
    # are what keep this working, and neither is obvious, so it is asserted.
    status, rows = b.try_run("delete from public.trips where id = :t", t=closed)
    check(status == "ok" and db.run(
              "select count(*) from public.trips where id = :t", t=closed)[0][0] == 0,
          "a closed trip can still be discarded -- the cascade is not an edit",
          repr(rows)[:90])
    left_behind = db.run(
        """select (select count(*) from public.trip_itinerary_days where trip_id = :t),
                  (select count(*) from public.trip_itinerary_stops where trip_id = :t),
                  (select count(*) from public.trip_itinerary_set_asides where trip_id = :t),
                  (select count(*) from public.trip_itineraries where trip_id = :t)
        """, t=closed)[0]
    check(list(left_behind) == [0, 0, 0, 0],
          "and it takes all four of its itinerary tables with it -- the stops through "
          "two cascades, not one",
          repr(left_behind))

    # ---- the access path ---------------------------------------------------
    # `trip_closes_at` runs inside `photos_insert_trip_member`'s WITH CHECK, so
    # it is asked once per photograph -- and, since the guard above, once per
    # itinerary day written, so a fourteen-day push asks it fourteen times.
    # What it must never become is a scan of every trip's days.
    #
    # Both plans are taken as a *member*, not over `db`: the hot path runs as
    # `authenticated`, where `trip_itinerary_days` carries an `is_trip_member`
    # security qual on top of the trip filter, and a plan taken as the
    # migration-owning superuser is not the plan that path produces. The
    # statistics are settled first, because a never-analyzed table plans off a
    # made-up ten pages and the answer would then be luck rather than evidence.
    print("\n== the derivation reads one row per trip, not the whole table ==")
    check(db.run("""select count(*) from pg_indexes
                    where schemaname = 'public' and tablename = 'trip_itinerary_days'
                      and indexname = 'trip_itinerary_days_day_date_idx'""")[0][0] == 1,
          "the index the furthest-date read is entitled to exists")
    db.run("analyze public.trip_itinerary_days")
    plan = "\n".join(row[0] for row in b.run(
        "explain (costs off) select max(d.day_date) from public.trip_itinerary_days d "
        "where d.trip_id = :t", t=postponed))
    check("Seq Scan" not in plan,
          "and the furthest-date read -- the WITH CHECK's and the trigger's alike -- "
          "is not a sequential scan under RLS",
          plan.replace("\n", " | ")[:120])
    check(sorted(row[0] for row in db.run(
              """select t.tgname from pg_trigger t
                 where t.tgrelid = 'public.trip_itinerary_days'::regclass
                   and not t.tgisinternal""")) ==
          ["trip_itinerary_days_guard_closed_trip",
           "trip_itinerary_days_record_gate_date_guard"],
          "and the guard that asks it per row is the only trigger 0016 adds here")

    # 0017: four tables, four triggers, ONE body. A second copy of this rule is
    # the thing to refuse in review, so the probe asserts there is not one --
    # and that 0016's day-shaped name is gone rather than left behind for a
    # fifth trigger to attach itself to.
    guards = db.run(
        """select c.relname, p.proname from pg_trigger t
             join pg_class c on c.oid = t.tgrelid
             join pg_proc p on p.oid = t.tgfoid
            where not t.tgisinternal and t.tgname like '%_guard_closed_trip'
            order by c.relname""")
    check([list(row) for row in guards] == [
              ["trip_itineraries", "guard_closed_trip_itinerary_write"],
              ["trip_itinerary_days", "guard_closed_trip_itinerary_write"],
              ["trip_itinerary_set_asides", "guard_closed_trip_itinerary_write"],
              ["trip_itinerary_stops", "guard_closed_trip_itinerary_write"],
          ],
          "every one of the itinerary's four tables carries the guard, and all four "
          "execute the same body",
          repr([list(row) for row in guards]))
    check(db.run("""select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public'
                      and p.proname = 'guard_closed_trip_itinerary_day'""")[0][0] == 0,
          "and 0016's day-shaped name is gone, not left beside the one that is maintained")
    plan = "\n".join(row[0] for row in b.run(
        "explain (costs off) select d.day_date from public.trip_itinerary_days d "
        "where d.trip_id = :t order by d.day_number desc limit 1", t=postponed))
    check("Seq Scan" not in plan,
          "nor is the plan-order last-day read the invariant above compares against",
          plan.replace("\n", " | ")[:120])

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
