-- What a photograph's day is, what word rides with it, and what happens to
-- its bytes when its row goes away.
--
-- Three settled captain decisions land here (2026-08-27), and one of them
-- re-keys a table and a function that were written against the calendar:
--
--   * **A photograph belongs to its day by ordinal day number.** Which day a
--     photograph is on is a fact about the trip's *shape*; whether you may
--     see it yet is a fact about the *calendar*. Move the trip a week later
--     and a day-3 photograph is still on day 3. So `photos` gains
--     `day_number` as its identity, `day_unlocks` is re-keyed off it, and
--     `day_page_is_open` takes a day number and resolves the calendar
--     through the synced itinerary (`0010_trip_itinerary.sql`) rather than
--     being handed a date by its caller.
--
--     The consequence the upload path depends on: **contributing never
--     requires a day to have a date.** The old trigger only recorded an
--     unlock when `trip_day` was non-null, so a photograph on an undated day
--     opened nothing and its taker was gated out of their own day. A day
--     number is always known, so the gate now always has its fact.
--
--   * **The word travels**, as a single-owner field. `photos.caption` needs
--     no new machinery at all: `photos_update_contributor` (`0006`) is
--     already contributor-only with an explicit `WITH CHECK`, so exactly one
--     person can ever write a given caption and "the owner's most recent
--     write wins" is what the row's own `updated_at` already says.
--
--   * **A leaver's photographs stay in the pool, and access splits by how
--     they left** -- walking away keeps it, being removed does not. Neither
--     event can be recorded yet, so nothing here decides between them. What
--     this migration builds is the *seat*: `may_read_trip_photos`, which
--     today answers `is_trip_member` and nothing else, and which the photos
--     SELECT policy and `r2-download-url` both go through from day one. When
--     leave/remove land, the split is one function body in one migration
--     with no scattered checks to hunt down.
--
-- And one thing that is not a decision but a bill: a deleted row's object is
-- unreachable and un-deletable, because RLS cannot touch R2.
-- `photo_tombstones` records the key so the sweeper can.

-- ---------------------------------------------------------------------------
-- photos: the day number, and the word
-- ---------------------------------------------------------------------------

-- The photograph's identity, and the key the gate is asked about.
--
-- `not null` and `>= 1`, matching `cairn_model.PhotoRef.dayNumber` (which
-- refuses anything less in its constructor) and
-- `trip_itinerary_days.day_number` (which the gate joins to). There is no
-- such thing here as a photograph with no day: the phone decides the day at
-- capture and a person may correct it afterwards, but neither path can leave
-- it blank.
--
-- `trip_day` is *retained* beside it, still nullable, and still means what
-- `0006` says it means: the derived calendar day, absent when
-- `packages/photo_day_assignment` legitimately placed nothing. It is now a
-- historical convenience -- the day's own date is the itinerary's to say,
-- and the itinerary is the shared fact eight phones agree on -- so nothing
-- decides anything from it any more. Dropping it would throw away the
-- provenance of an assignment that a person may later want to challenge, and
-- it costs a date per row.
alter table public.photos add column if not exists day_number integer;

-- Backfill, for a project that already holds rows. The date is resolved
-- through the itinerary, which is the only thing that knows which ordinal a
-- calendar day was; `order by day_number limit 1` rather than a join because
-- two days of a plan may legitimately carry the same date and an arbitrary
-- pick is not a thing to leave to the planner.
update public.photos p
   set day_number = (
     select d.day_number
       from public.trip_itinerary_days d
      where d.trip_id = p.trip_id
        and d.day_date = p.trip_day
      order by d.day_number
      limit 1
   )
 where p.day_number is null
   and p.trip_day is not null;

-- Anything left is a photograph whose day this migration cannot name: it had
-- no date, or its date matches no day of the synced plan. Guessing one would
-- put a photograph on a day it does not belong to, which is exactly what
-- `trip_day`'s nullability exists to refuse. Stop loudly instead, and let a
-- person decide -- a migration that silently invents a day number is worse
-- than one that will not apply.
do $$
declare
  n bigint;
begin
  select count(*) into n from public.photos where day_number is null;
  if n > 0 then
    raise exception
      'cannot re-key % photo row(s) onto a day number: no synced itinerary day '
      'matches their trip_day (or they have none). Place them by hand, or sync '
      'the itinerary, before applying 0011.', n;
  end if;
end;
$$;

alter table public.photos alter column day_number set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.photos'::regclass and conname = 'photos_day_number_check'
  ) then
    alter table public.photos add constraint photos_day_number_check check (day_number >= 1);
  end if;
end;
$$;

-- The word under the photograph, written at the capture breath and printed
-- by the book as it stands (docs/decisions/2026-08-22-book-no-editor.md: the
-- writing was never happening in the book, so there is no book editor and
-- this is the only place a person authors anything).
--
-- Single-owner by the policy that already exists, not by anything new:
-- `photos_update_contributor` is `contributor_id = auth.uid()` with an
-- explicit `WITH CHECK`, so six of seven phones cannot write it and there is
-- nothing for them to disagree about. No per-field clock, and no general
-- editable-shared-field mechanism -- the row's `updated_at`, which the pull
-- cursor already reads, is the whole of it.
--
-- The bound is a sanity bound on the wire and not a design constraint, in
-- the same spirit as `r2-upload-url`'s 64 MiB: a caption is a line under a
-- photograph, the book prints it into a fixed measure, and the column is
-- replicated to every phone on the trip. What a person may actually type is
-- the interface's to decide, and it will be smaller than this.
alter table public.photos add column if not exists caption text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.photos'::regclass and conname = 'photos_caption_length_check'
  ) then
    alter table public.photos
      add constraint photos_caption_length_check check (char_length(caption) <= 280);
  end if;
end;
$$;

-- The day number is what the pool groups by and what the gate is asked
-- about, so it is what the index should be on. The date-keyed index stays:
-- `trip_day` is still read for provenance.
create index if not exists photos_trip_id_day_number_idx
  on public.photos (trip_id, day_number);

-- An original is immutable, and this is the half of that a database can
-- enforce that `0006` did not.
--
-- `r2_object_key` is `unique`, so no *second* row may claim an original --
-- but nothing stopped a row from changing which original it claims, and
-- `photos_update_contributor` places no restriction on which columns a
-- contributor may write. That matters more than it sounds now that
-- `r2-download-url` exists: the function's whole discipline is that it signs
-- the row's own stored key and never a key derived from caller input, and a
-- key the caller can PATCH *is* caller input. `unique` blocks repointing at
-- another photograph (its row holds that key), but a day page's key lives in
-- another table with another unique index, so without this a member could
-- point their own row at `trips/<someone else's trip>/pages/<id>.jpg` and
-- have it signed.
--
-- This is the *second* half of the pair. The trigger stops a key changing;
-- the CHECK below stops the first claim being a foreign one in the first
-- place. Neither is sufficient alone -- a locked key that was free to be
-- anything at INSERT is just a permanent theft rather than a revocable one.
--
-- WITH CHECK cannot see the old row, so the lock is a trigger -- exactly as
-- `photos_lock_trip_id` is, and as `trip_invites.trip_id`'s is in `0005`.
-- The day number is deliberately *not* locked: correcting which day a
-- photograph landed on is the one edit a person really makes, and the unlock
-- trigger below is written to follow it.
create or replace function public.photos_lock_object_keys()
returns trigger
language plpgsql
as $$
begin
  if new.r2_object_key is distinct from old.r2_object_key then
    raise exception 'photos.r2_object_key cannot be changed once set';
  end if;
  if new.r2_thumbnail_key is distinct from old.r2_thumbnail_key
     and old.r2_thumbnail_key is not null then
    raise exception 'photos.r2_thumbnail_key cannot be changed once set';
  end if;
  return new;
end;
$$;

drop trigger if exists photos_lock_object_keys on public.photos;
create trigger photos_lock_object_keys
  before update on public.photos
  for each row execute function public.photos_lock_object_keys();

-- ---------------------------------------------------------------------------
-- ...and the first claim is not free either
-- ---------------------------------------------------------------------------
--
-- The lock above froze the key. It did not say what the key may be, and the
-- trigger cannot: it only runs on UPDATE, because on INSERT there is no old
-- row to compare against. So until this constraint, `photos_insert_trip_member`
-- let a member state *any* key on the row they inserted -- including
-- `trips/<someone else's trip>/pages/<their day page>.jpg`, which no unique
-- index catches (that key lives in `day_pages`, a different table with a
-- different unique index) -- and `r2-download-url` would then sign it,
-- faithfully, because signing the row's own stored key is exactly what it
-- promises to do. The promise is only worth what the stored key is worth.
-- That was the finding in `supabase/functions/r2-download-url/REVIEW.md` §4,
-- and this closes it: a row may only claim a key built from **its own trip
-- and its own id**.
--
-- The shape is `r2-upload-url`'s `objectKeyFor` said in SQL, and the two must
-- agree letter for letter, because the client mints the key and the database
-- is what refuses it:
--
--     trips/<trip_id>/photos/<photo_id>/<whatever>
--
-- Everything past that prefix is deliberately unconstrained. Naming the file
-- (`original.jpg`, `thumbnail.heic`) is the upload function's business, and a
-- database that also spelled out the extension list would have to be migrated
-- every time a format is added. What the prefix buys is the only thing that
-- matters here: whatever the object is, it is inside this photograph's own
-- folder, so a signature over it can only ever hand back this row's own bytes.
--
-- Three details, each of which was a decision:
--
-- * **`lower()`, not a bare comparison.** `r2-upload-url`'s `UUID_RE` carries
--   the `i` flag, so it will happily sign a key whose uuid segments are spelled
--   in upper case, while `photos.id` and `photos.trip_id` are `uuid` columns
--   and always render lower. A case-sensitive check would therefore accept the
--   PUT, take the bytes, and *then* refuse the row -- an orphaned object plus a
--   retry that can never succeed, since the client would re-mint the same
--   rejected key forever. Normalising here costs nothing: the case of the
--   literal segments is not a permission, and `trips/` and `TRIPS/` are two
--   different R2 namespaces that are both still bound to this trip and this id.
--
-- * **No LIKE-metacharacter hazard.** The pattern is built from two `uuid`
--   columns, whose text form is hexadecimal and hyphens. Neither `%` nor `_`
--   can appear in it, so a row cannot widen its own pattern.
--
-- * **The client must now mint the id.** A key that must contain the row's own
--   id cannot be written by a client that let `gen_random_uuid()` supply it.
--   That is already how the app works (`PhotoId.mint`, and
--   `test/photo_id_format_test.dart` pins the spelling), and the fixtures in
--   `supabase/tests/` were updated to match rather than the constraint being
--   loosened to accommodate them.
--
-- `day_pages.r2_object_key` has the identical latent freedom and is
-- deliberately left alone: nothing signs a day-page key today (no composer
-- exists, and `r2-download-url` reads `photos` only), so constraining it now
-- would be guessing at a shape no writer has yet had to agree to.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.photos'::regclass
       and conname = 'photos_object_key_own_prefix_check'
  ) then
    alter table public.photos
      add constraint photos_object_key_own_prefix_check check (
        lower(r2_object_key)
          like 'trips/' || trip_id::text || '/photos/' || id::text || '/%'
      );
  end if;
end;
$$;

-- The same class of free claim exists on `r2_thumbnail_key`, and is closed the
-- same way. It is a *nullable* `unique text` with no shape constraint, so a
-- member could state a foreign key there on insert exactly as on the original
-- -- and although nothing generates a thumbnail yet and nothing signs one, the
-- lock trigger permits filling it in later from null, which is precisely the
-- window a future reader would inherit. A thumbnail lives beside the original
-- (`.../thumbnail.<ext>`, `supabase/README.md`), so it shares the prefix; null
-- is still allowed, because the column means "no smaller variant exists".
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.photos'::regclass
       and conname = 'photos_thumbnail_key_own_prefix_check'
  ) then
    alter table public.photos
      add constraint photos_thumbnail_key_own_prefix_check check (
        r2_thumbnail_key is null
        or lower(r2_thumbnail_key)
             like 'trips/' || trip_id::text || '/photos/' || id::text || '/%'
      );
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- The single seat: may this person read this trip's photographs at all
-- ---------------------------------------------------------------------------
--
-- Today this is `is_trip_member` and nothing more, and saying so plainly is
-- the point: it exists so that the leaver split has exactly one place to
-- land. *"If you leave, you keep the trip you were on; if you are removed,
-- you do not"* -- two different events with two different outcomes, neither
-- of which `trip_members` can currently tell apart (a row is either there or
-- it is not). When leave and remove are built, this function body changes
-- and every photo read in the system changes with it: the SELECT policy
-- below, and `r2-download-url`, which inherits it by reading the row *as the
-- caller* rather than deciding access for itself.
--
-- `security definer` for the same reason `is_trip_member` is: a membership
-- test inlined into a policy on a membership-gated table recurses (`0004`,
-- and `supabase/tests/recursion_mechanism.py` both ways round).
create or replace function public.may_read_trip_photos(p_trip_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_trip_member(p_trip_id, p_user_id);
$$;

revoke all on function public.may_read_trip_photos(uuid, uuid) from public;
grant execute on function public.may_read_trip_photos(uuid, uuid) to authenticated, service_role;

-- Same policy it always was -- membership, and no day predicate, so a shut
-- gate can still render the day's times and names (`0006` says why at
-- length) -- routed through the seat above.
drop policy if exists "photos_select_trip_member" on public.photos;
create policy "photos_select_trip_member"
  on public.photos for select
  to authenticated
  using ( public.may_read_trip_photos(photos.trip_id, auth.uid()) );

-- ---------------------------------------------------------------------------
-- day_unlocks, re-keyed off the day number
-- ---------------------------------------------------------------------------
--
-- Everything `0007` says about this table still holds and none of it is
-- softened here: no INSERT policy, no UPDATE policy, no DELETE policy, rows
-- written by the trigger below and by nothing else, and nothing ever takes
-- one away. Only the column that names the day changes.
alter table public.day_unlocks add column if not exists day_number integer;

update public.day_unlocks u
   set day_number = (
     select d.day_number
       from public.trip_itinerary_days d
      where d.trip_id = u.trip_id
        and d.day_date = u.day_date
      order by d.day_number
      limit 1
   )
 where u.day_number is null;

-- An unlock that cannot be re-keyed cannot be dropped either: *"an opened day
-- never shuts"* is the one thing this table promises, and deleting the row
-- would break it silently. Stop, exactly as `photos` does above.
do $$
declare
  n bigint;
begin
  select count(*) into n from public.day_unlocks where day_number is null;
  if n > 0 then
    raise exception
      'cannot re-key % day_unlock row(s) onto a day number: no synced itinerary '
      'day matches their day_date. An unlock is never dropped, so 0011 will not '
      'apply until the itinerary that names those days has been synced.', n;
  end if;
end;
$$;

alter table public.day_unlocks alter column day_number set not null;

-- The key becomes the ordinal. `day_date` is *retained* beside it, exactly as
-- `photos.trip_day` is retained beside `photos.day_number` and for the same
-- reason: it is what the calendar said when the day was opened, and throwing
-- it away throws away the provenance of an unlock somebody may one day want
-- to challenge. It becomes nullable, because contributing to an undated day
-- is now the ordinary case, and **nothing reads it** -- `day_page_is_open`
-- resolves the calendar through the itinerary and never through this column.
--
-- Retaining it also keeps every migration re-appliable, which is a property
-- this repo checks (`supabase/tests/rls_probe.py`, "every migration applies
-- cleanly, twice"). Dropping the column would make `0007`'s own body
-- unre-runnable -- a `language sql` function is validated when it is created,
-- so the date-keyed `day_page_is_open` cannot be recreated once the column it
-- reads is gone -- and the only way to keep the property would have been to
-- edit a migration that is already applied to a hosted project.
do $$
begin
  if exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
     where t.relname = 'day_unlocks' and c.conname = 'day_unlocks_pkey'
       and pg_get_constraintdef(c.oid) not like '%day_number%'
  ) then
    alter table public.day_unlocks drop constraint day_unlocks_pkey;
    alter table public.day_unlocks add primary key (trip_id, day_number, user_id);
  end if;
end;
$$;

alter table public.day_unlocks alter column day_date drop not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.day_unlocks'::regclass and conname = 'day_unlocks_day_number_check'
  ) then
    alter table public.day_unlocks
      add constraint day_unlocks_day_number_check check (day_number >= 1);
  end if;
end;
$$;

create index if not exists day_unlocks_trip_day_number_idx
  on public.day_unlocks (trip_id, day_number);

-- Contributing to a day opens it, and now it opens it whether or not anyone
-- has said what date that day is.
--
-- The old body was `if new.trip_day is not null`, which was right while the
-- gate was keyed by date and is a hole now that it is not: a photograph
-- taken on a day whose date is still open recorded no unlock, so its own
-- taker was held out of it. A day number is always present, so the guard is
-- gone rather than replaced.
--
-- Unlocks still only accumulate. Moving a photograph from day three to day
-- four opens day four and leaves day three open, which is right: you did
-- contribute to day three.
create or replace function public.record_day_unlock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.day_unlocks (trip_id, day_number, user_id, day_date)
  values (new.trip_id, new.day_number, new.contributor_id, new.trip_day)
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_photo_unlocks_day on public.photos;
create trigger on_photo_unlocks_day
  after insert or update of trip_id, day_number on public.photos
  for each row execute function public.record_day_unlock();

-- ---------------------------------------------------------------------------
-- The gate, asked by day number
-- ---------------------------------------------------------------------------
--
-- Dropped rather than overloaded. Two functions named `day_page_is_open`,
-- one taking a date and one taking an ordinal, is a coin toss every caller
-- has to win -- and the caller that matters is the one thing in this app
-- whose mistake is unrecoverable (`docs/architecture.md`: a download
-- function that skips this check is the single worst potential leak in the
-- app). There is one gate.
drop function if exists public.day_page_is_open(uuid, date, uuid);

-- The one authoritative answer to "may this person see this day's pictures",
-- now keyed by the day's ordinal and resolving the calendar itself.
--
-- Nothing in this schema calls it: RLS gates rows, and the rows of a shut
-- day must stay readable so the gate can show its times and names. What it
-- gates is the bytes -- it is the check `r2-download-url` makes before it
-- signs a GET, exactly as `r2-upload-url` re-checks membership before it
-- signs a PUT. It lives here, in SQL, so that check is one call against the
-- same tables rather than a second copy of the rule written in TypeScript
-- (`docs/architecture.md`, invariant 2: the rule exists twice, deliberately,
-- and this is the second).
--
-- **The undated day reads as walked, and that mirrors the phone
-- deliberately.** `lib/app_state/day_gate.dart`'s `standingOfPlanDay` takes
-- `planDay?.date` and answers `walked` when it is null -- which collapses two
-- cases into one on purpose: a day the plan has stopped claiming, and a day
-- whose date nobody has answered for yet. Its reasoning transfers exactly:
-- the gate is about the day you are living, today has a date, so a day with
-- none is certainly not it, and the gate has no business shutting any other
-- day. So `coalesce(..., true)`, where `0007` had `coalesce(..., false)`.
--
-- The consequence is worth stating rather than discovering: **a trip whose
-- itinerary has not reached the server has no shut days at all**, because
-- the server cannot name the day in progress. Membership is still required
-- for every one of them, and the alternative -- failing shut -- would hold
-- back days that ended a week ago from the whole party, which is the thing
-- the gate is most explicitly not for. The itinerary is pushed by the same
-- reconcile loop the photographs are, so the window is a first sync and not
-- a state a trip sits in.
--
-- "Today" is read in the trip's own timezone (`0003_trips.sql`), not the
-- server's and not the caller's, so every phone on the trip agrees on which
-- day is still in progress.
create or replace function public.day_page_is_open(p_trip_id uuid, p_day_number integer, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_trip_member(p_trip_id, p_user_id)
    and (
      -- Walked: the day finished on the trip's clock, or carries no date at
      -- all. Open to every member, including one who joined this morning.
      coalesce(
        (select d.day_date
           from public.trip_itinerary_days d
          where d.trip_id = p_trip_id
            and d.day_number = p_day_number)
        < (select (now() at time zone t.timezone)::date
             from public.trips t where t.id = p_trip_id),
        true
      )
      -- Otherwise: the day in progress, open only to those who have put
      -- something into it. A future day is neither, and stays shut -- unless
      -- something of theirs is already on it, which is what the phone's own
      -- `GateState.decide` answers first and for the same reason.
      or exists (
        select 1
        from public.day_unlocks u
        where u.trip_id = p_trip_id
          and u.day_number = p_day_number
          and u.user_id = p_user_id
      )
    );
$$;

revoke all on function public.day_page_is_open(uuid, integer, uuid) from public;
grant execute on function public.day_page_is_open(uuid, integer, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- What a deleted row leaves behind in R2
-- ---------------------------------------------------------------------------
--
-- A person can always delete their own photograph (`0006`), and the row goes
-- with no tombstone -- the day leaves no visible gap, which is the point.
-- The *object* does not go anywhere: RLS cannot reach R2, and nothing in
-- Postgres can. Without this table the key is simply lost, and the bytes sit
-- in the bucket forever, on the one line of this backend that ever invoices
-- (`docs/storage-and-cost.md`).
--
-- So the row's disappearance is recorded here, for one reader: the sweeper
-- Worker (`ops/`, not yet built), which reconciles the bucket against the
-- database on a cron.
--
-- **No client reads this table, so it has RLS enabled and no policies at
-- all.** Every omission is deliberate, exactly as `day_unlocks`' are: the
-- trigger below is `security definer` and writes it, the service role reads
-- it, and there is no statement an authenticated caller can issue against it
-- at all. It carries no photo id and no contributor: it is a note about an
-- object, not a record of who deleted what.
--
-- **`trip_id` carries no foreign key, and that is not an oversight.**
-- Deleting a trip cascades its photographs, which fires this trigger --
-- and then a cascading foreign key here would delete every tombstone it just
-- wrote, in the one case that produces the most objects to sweep. A tombstone
-- outlives the thing it is a tombstone for, or it is not one.
create table if not exists public.photo_tombstones (
  r2_object_key text primary key,
  trip_id uuid not null,
  deleted_at timestamptz not null default now()
);

create index if not exists photo_tombstones_deleted_at_idx
  on public.photo_tombstones (deleted_at);

alter table public.photo_tombstones enable row level security;

-- Every key the vanished row was pointing at. `r2_thumbnail_key` is always
-- null today -- nothing generates a variant -- and it is written anyway, so
-- that the day something does, its objects are already swept rather than
-- leaked by an omission nobody would think to look for.
--
-- `on conflict ... do update` because a key freed by a delete can be claimed
-- again: `r2-upload-url` refuses a photo id a row holds, and after a delete
-- no row holds it. Which is also the rule the sweeper must keep, and the
-- reason it is written here rather than left implicit: **a tombstone is a
-- candidate, not an instruction.** The sweeper deletes an object only after
-- re-checking that no `photos` row claims that key, or it will one day
-- delete live bytes out from under a re-upload.
create or replace function public.record_photo_tombstone()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.photo_tombstones (r2_object_key, trip_id)
  values (old.r2_object_key, old.trip_id)
  on conflict (r2_object_key) do update set deleted_at = now();

  if old.r2_thumbnail_key is not null then
    insert into public.photo_tombstones (r2_object_key, trip_id)
    values (old.r2_thumbnail_key, old.trip_id)
    on conflict (r2_object_key) do update set deleted_at = now();
  end if;

  return old;
end;
$$;

drop trigger if exists on_photo_deleted_tombstone on public.photos;
create trigger on_photo_deleted_tombstone
  after delete on public.photos
  for each row execute function public.record_photo_tombstone();
