-- The gate, as a fact the database can be asked about.
--
-- The product rule: today's page stays shut until you have put your own photo
-- into it, and opens the instant you do. Three further decisions constrain
-- how that can be stored:
--
--   * You can delete your own photo, and the day stays open. No re-lock, no
--     marker, no visible gap. Contributing happened; re-shutting the day
--     would be punitive.
--   * Joining mid-trip opens every past day freely. The gate is about the day
--     in progress, never about days already walked.
--   * A shut gate still shows the shape of the day -- the times and the names,
--     with the images withheld -- so it is the bytes that are gated, not the
--     rows.
--
-- The first of those rules out deriving the gate from the photos table. "Have
-- you contributed to this day" cannot be `exists (select 1 from photos ...)`,
-- because deleting your photo would make that false again and slam a day shut
-- that you had already opened. So the unlock is recorded as its own fact,
-- once, and nothing ever takes it back.
create table if not exists public.day_unlocks (
  trip_id uuid not null references public.trips (id) on delete cascade,
  day_date date not null,
  user_id uuid not null references public.profiles (id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  primary key (trip_id, day_date, user_id)
);

create index if not exists day_unlocks_trip_day_idx on public.day_unlocks (trip_id, day_date);

alter table public.day_unlocks enable row level security;

-- Members can read who has opened which day -- the same information a shut
-- gate already shows on its face.
--
-- There is no INSERT, UPDATE or DELETE policy, and all three omissions are
-- load-bearing. No client can forge an unlock for a day it did not
-- contribute to, and no client -- not even the person it belongs to, and not
-- the trip's starter -- can take one away. "The day stays open" is not a rule
-- the app has to remember to honour; it is the only behaviour this table
-- permits. The rows are written by the trigger below and by nothing else.
drop policy if exists "day_unlocks_select_trip_member" on public.day_unlocks;
create policy "day_unlocks_select_trip_member"
  on public.day_unlocks for select
  to authenticated
  using ( public.is_trip_member(day_unlocks.trip_id, auth.uid()) );

-- Contributing to a day opens it, in the database, at the moment the photo
-- row lands. Fires on placement as well as insert, because a photo can arrive
-- with no day (the assignment ladder can fail) and be placed by hand later;
-- that placement is a contribution to the day it is placed on.
--
-- Unlocks only accumulate. Moving a photo from day three to day four opens
-- day four and leaves day three open, which is right: you did contribute to
-- day three, and the deletion rule says an opened day never shuts.
create or replace function public.record_day_unlock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.trip_day is not null then
    insert into public.day_unlocks (trip_id, day_date, user_id)
    values (new.trip_id, new.trip_day, new.contributor_id)
    on conflict do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists on_photo_unlocks_day on public.photos;
create trigger on_photo_unlocks_day
  after insert or update of trip_id, trip_day on public.photos
  for each row execute function public.record_day_unlock();

-- The one authoritative answer to "may this person see this day's pictures".
--
-- Nothing in this schema calls it: RLS gates rows, and the rows of a shut day
-- must stay readable so the gate can show its times and names. What it gates
-- is the bytes -- it is the check the not-yet-written `r2-download-url` edge
-- function must make before it signs a GET for a photo, exactly as
-- `r2-upload-url` re-checks membership before it signs a PUT. It lives here,
-- in SQL, so that check is one call against the same tables rather than a
-- second copy of the rule written in TypeScript.
--
-- "Today" is read in the trip's own timezone (0003_trips.sql), not the
-- server's and not the caller's, so every phone on the trip agrees on which
-- day is still in progress.
create or replace function public.day_page_is_open(p_trip_id uuid, p_day date, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_trip_member(p_trip_id, p_user_id)
    and (
      -- Any day already finished on the trip's clock is open to every member,
      -- including one who joined this morning.
      coalesce(
        p_day < (select (now() at time zone t.timezone)::date
                 from public.trips t where t.id = p_trip_id),
        false
      )
      -- Otherwise: the day in progress, open only to those who have put
      -- something into it. A future day is neither, and stays shut.
      or exists (
        select 1
        from public.day_unlocks u
        where u.trip_id = p_trip_id
          and u.day_date = p_day
          and u.user_id = p_user_id
      )
    );
$$;

revoke all on function public.day_page_is_open(uuid, date, uuid) from public;
grant execute on function public.day_page_is_open(uuid, date, uuid) to authenticated, service_role;
