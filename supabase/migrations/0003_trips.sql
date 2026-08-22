-- A trip is a named container that photos and membership hang off, plus the
-- one thing every phone on the trip has to agree on: the clock.
--
-- The itinerary itself is still never stored here -- it is pasted, parsed and
-- kept on the phone. This table holds no stops, no places and no times of
-- day; it holds the trip's clock and its dates, which are a different thing.
create table if not exists public.trips (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references public.profiles (id) on delete restrict,

  -- ---- The shared trip clock -------------------------------------------
  --
  -- packages/trip_moments derives each person's daily ping slot as a pure
  -- function of (trip id, date) mapped into a waking window "in the trip's
  -- own timezone", and packages/photo_day_assignment falls back to the trip's
  -- timezone (rung 2) for any photo whose GPS will not resolve. Both take
  -- that timezone as a caller-supplied parameter.
  --
  -- Before this column existed the only source for it was each phone's own
  -- parse of its own copy of the pasted itinerary. Two phones that inferred
  -- even slightly different zones -- a different paste, an ambiguous city, a
  -- daylight-saving edge -- would map the identical fraction to different
  -- absolute instants, and the ping schedule would drift apart with nothing
  -- raising an error. The captain's call is that the clock lives here, on the
  -- server, authored once at trip creation, so there is exactly one of it.
  --
  -- The app does not ask anyone to pick a zone: it asks for country and city
  -- and derives the IANA name from that. Both are kept so the question can be
  -- re-asked and the derivation re-run.
  timezone text not null,
  country text,
  city text,

  start_date date not null,
  end_date date not null,

  -- The waking window the daily ping slots are spread across: 08:00 to 22:30
  -- by default, one slot per person. 22:30 rather than 22:00 deliberately, so
  -- the last slot can still catch dinner; anything later is the late-photo
  -- path, which is always open. Stored per trip rather than hard-coded so a
  -- trip that genuinely wakes at a different hour can say so, and so every
  -- phone reads the same bounds.
  ping_window_start time not null default '08:00',
  ping_window_end time not null default '22:30',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint trips_dates_ordered check (end_date >= start_date),
  constraint trips_ping_window_ordered check (ping_window_end > ping_window_start)
);

-- v1 keeps ONE fixed clock per trip. Two refinements from the planning record
-- are deliberately not modelled here:
--
--   * first and last day following the itinerary's real arrival/departure
--     time, and
--   * a day that changes country holding the clock it started in.
--
-- Both need the itinerary, which stays on the phone by decision, so putting
-- them in this table would mean syncing the itinerary -- a bigger change than
-- this correctness pass, and one the captain has not asked for. Until then a
-- trip that crosses zones runs on the clock it was created with, and the
-- daylight-saving slide is documented rather than solved.

drop trigger if exists trips_touch_updated_at on public.trips;
create trigger trips_touch_updated_at
  before update on public.trips
  for each row execute function public.touch_updated_at();

-- A bad timezone would not fail loudly at write time -- it would fail later,
-- on every device at once, the first time anything did `at time zone`. Since
-- the entire reason this column exists is that the clock must not silently
-- diverge, it is validated where it is written. A check constraint cannot do
-- this (pg_timezone_names is a view, so the lookup is not immutable), hence
-- the trigger.
create or replace function public.validate_trip_timezone()
returns trigger
language plpgsql
as $$
begin
  if not exists (select 1 from pg_timezone_names where name = new.timezone) then
    raise exception 'unknown IANA timezone: %', new.timezone
      using errcode = 'invalid_parameter_value';
  end if;
  return new;
end;
$$;

drop trigger if exists trips_validate_timezone on public.trips;
create trigger trips_validate_timezone
  before insert or update of timezone on public.trips
  for each row execute function public.validate_trip_timezone();

alter table public.trips enable row level security;

-- Policies are added in 0004_trip_members.sql, once trip_members exists
-- (membership is what "trip member" checks are defined against). RLS is
-- enabled here already, so until that migration runs this table is
-- deny-all -- never briefly open.
