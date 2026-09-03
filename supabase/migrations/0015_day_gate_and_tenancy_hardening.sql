-- Close four holes around the day gate and the rows whose object keys it
-- eventually protects. This is deliberately one forward migration: every
-- earlier migration is a recorded fact and remains byte-for-byte unchanged.

-- ---------------------------------------------------------------------------
-- An object key must stay a literal path inside its photo's own folder
-- ---------------------------------------------------------------------------
--
-- The prefix checks added in 0011 accepted `../`, empty path segments, and
-- URL path metacharacters. A URL constructor normalises dot segments before
-- aws4fetch signs the request, so a row that appeared to name its own folder
-- could make the download function sign a different object in the bucket.
-- Percent is excluded as well as backslash, query and fragment delimiters:
-- each can change the URL path seen by the signer without changing the text
-- the prefix check saw. The upload function only mints UUID segments and a
-- fixed filename, so none is part of a legitimate key grammar.
alter table public.photos
  drop constraint if exists photos_object_key_own_prefix_check;
alter table public.photos
  add constraint photos_object_key_own_prefix_check check (
    lower(r2_object_key)
      like 'trips/' || trip_id::text || '/photos/' || id::text || '/%'
    and r2_object_key !~ '(^|/)(/|$)'
    and r2_object_key !~ '(^|/)[.]{1,2}(/|$)'
    and r2_object_key !~ '[%?#\\]'
  );

alter table public.photos
  drop constraint if exists photos_thumbnail_key_own_prefix_check;
alter table public.photos
  add constraint photos_thumbnail_key_own_prefix_check check (
    r2_thumbnail_key is null
    or (
      lower(r2_thumbnail_key)
        like 'trips/' || trip_id::text || '/photos/' || id::text || '/%'
      and r2_thumbnail_key !~ '(^|/)(/|$)'
      and r2_thumbnail_key !~ '(^|/)[.]{1,2}(/|$)'
      and r2_thumbnail_key !~ '[%?#\\]'
    )
  );

-- ---------------------------------------------------------------------------
-- An unlock follows a moved photograph, but survives a deleted one
-- ---------------------------------------------------------------------------
--
-- 0011 chose an accumulating unlock: moving one photo through every day left
-- every one permanently open. The narrower repair would forbid moving a
-- photograph after it opened a day. This migration chooses the truer repair
-- instead, because the decision record says people retain ownership of where
-- their own photographs landed and may correct it even after the trip closes
-- (`docs/decisions/2026-08-26-the-ending.md`). A move withdraws the old
-- unlock when no other photo or retained deletion supports it, then opens the
-- new day. Deletion remains different by decision: deleting a disliked photo
-- must not re-lock the day (`docs/decisions/2026-08-22-last-calls.md`).
--
-- Rows that predate this migration have no provenance capable of proving
-- whether their photograph still exists, so they are conservatively marked
-- retained. The hosted project has not applied 0011 and therefore has no such
-- rows; this is for safe forward application elsewhere.
alter table public.day_unlocks
  add column if not exists retained_after_delete boolean not null default true;

create or replace function public.record_day_unlock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    update public.day_unlocks
       set retained_after_delete = true
     where trip_id = old.trip_id
       and day_number = old.day_number
       and user_id = old.contributor_id;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.day_number is distinct from new.day_number then
    delete from public.day_unlocks u
     where u.trip_id = old.trip_id
       and u.day_number = old.day_number
       and u.user_id = old.contributor_id
       and not u.retained_after_delete
       and not exists (
         select 1
           from public.photos p
          where p.trip_id = old.trip_id
            and p.day_number = old.day_number
            and p.contributor_id = old.contributor_id
       );
  end if;

  insert into public.day_unlocks
    (trip_id, day_number, user_id, day_date, retained_after_delete)
  values
    (new.trip_id, new.day_number, new.contributor_id, new.trip_day, false)
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_photo_unlocks_day on public.photos;
create trigger on_photo_unlocks_day
  after insert or update of trip_id, day_number or delete on public.photos
  for each row execute function public.record_day_unlock();

-- ---------------------------------------------------------------------------
-- A date edit cannot turn a shut day into a walked day early
-- ---------------------------------------------------------------------------
--
-- Missing and honestly undated itinerary days remain permissive, exactly as
-- 0011 requires for first sync and as the phone reads them. A date that was
-- already known is different: if a member changes today's or a future day's
-- date to the past or to null, the edit still lands, but the permissive
-- "walked" branch cannot open it before the date it previously carried has
-- actually passed. This keeps flat itinerary editing intact and refuses only
-- the forged early unlock. A real contribution still opens the day at once.
create table if not exists public.day_gate_date_guards (
  trip_id uuid not null,
  day_number integer not null check (day_number >= 1),
  not_before date not null,
  primary key (trip_id, day_number),
  foreign key (trip_id, day_number)
    references public.trip_itinerary_days (trip_id, day_number)
    on update cascade on delete cascade
);

alter table public.day_gate_date_guards enable row level security;

-- There are intentionally no client policies. The photo trigger's pattern is
-- repeated here: a SECURITY DEFINER trigger records the guard and the
-- SECURITY DEFINER gate reads it. A member can neither erase nor shorten it.
create or replace function public.record_day_gate_date_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date;
begin
  if new.day_date is not distinct from old.day_date then
    return new;
  end if;

  select (now() at time zone t.timezone)::date
    into v_today
    from public.trips t
   where t.id = old.trip_id;

  if old.day_date >= v_today
     and coalesce(new.day_date < v_today, true) then
    insert into public.day_gate_date_guards (trip_id, day_number, not_before)
    values (old.trip_id, old.day_number, old.day_date)
    on conflict (trip_id, day_number) do update
      set not_before = greatest(
        public.day_gate_date_guards.not_before,
        excluded.not_before
      );
  end if;

  return new;
end;
$$;

drop trigger if exists trip_itinerary_days_record_gate_date_guard
  on public.trip_itinerary_days;
create trigger trip_itinerary_days_record_gate_date_guard
  after update of day_date on public.trip_itinerary_days
  for each row execute function public.record_day_gate_date_guard();

create or replace function public.day_page_is_open(
  p_trip_id uuid,
  p_day_number integer,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with clock as (
    select (now() at time zone t.timezone)::date as today
      from public.trips t
     where t.id = p_trip_id
  )
  select public.is_trip_member(p_trip_id, p_user_id)
    and (
      (
        coalesce(
          (select d.day_date
             from public.trip_itinerary_days d
            where d.trip_id = p_trip_id
              and d.day_number = p_day_number)
          < (select today from clock),
          true
        )
        and not exists (
          select 1
            from public.day_gate_date_guards g
           where g.trip_id = p_trip_id
             and g.day_number = p_day_number
             and g.not_before >= (select today from clock)
        )
      )
      or exists (
        select 1
          from public.day_unlocks u
         where u.trip_id = p_trip_id
           and u.day_number = p_day_number
           and u.user_id = p_user_id
      )
    );
$$;

-- ---------------------------------------------------------------------------
-- A composed page stays in the trip where it was created
-- ---------------------------------------------------------------------------
--
-- Same shape as photos_lock_trip_id in 0006: WITH CHECK sees only the proposed
-- row, so immutability belongs in a BEFORE UPDATE trigger comparing old and
-- new.
create or replace function public.day_pages_lock_trip_id()
returns trigger
language plpgsql
as $$
begin
  if new.trip_id is distinct from old.trip_id then
    raise exception 'day_pages.trip_id cannot be changed once set';
  end if;
  return new;
end;
$$;

drop trigger if exists day_pages_lock_trip_id on public.day_pages;
create trigger day_pages_lock_trip_id
  before update on public.day_pages
  for each row execute function public.day_pages_lock_trip_id();
