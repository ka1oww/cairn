-- A trip is just a named container that photos and membership hang off.
-- The itinerary itself is never stored here -- it is computed and kept on
-- the phone. This table exists only so photos/membership have somewhere
-- to point.
create table if not exists public.trips (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table public.trips enable row level security;

-- Policies are added in 0004_trip_members.sql, once trip_members exists
-- (membership is what "trip member" checks are defined against). RLS is
-- enabled here already, so until that migration runs this table is
-- deny-all -- never briefly open.
