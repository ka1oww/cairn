-- One row per person, and the durable home of the name credited under every
-- photo.
--
-- `profiles.id` IS the `auth.users` id, so `auth.uid()` can be compared to it
-- directly in every policy in this schema. But there is deliberately **no
-- foreign key to auth.users**, and that is the whole point of this table.
--
-- The design record credits every photo with a name
-- (docs/decisions/2026-08-22-design-calls.md, "Each photo is credited"), and
-- the captain's deletion call is the tombstone model: deleting an account
-- removes the *login*, while the name-only profile survives underneath the
-- photos so credit is never erased. The original shape --
-- `id references auth.users on delete cascade` -- made that impossible twice
-- over:
--
--   1. Deleting the login cascaded into this table and erased the name, so
--      every photo that person contributed lost its byline.
--   2. Three `on delete restrict` references to this table (photos.
--      contributor_id, trips.created_by, trip_invites.created_by) then
--      blocked that cascade outright, so anyone who had ever taken a photo,
--      started a trip or minted an invite -- in practice every real user --
--      could not be deleted at all.
--
-- Dropping the constraint fixes both at once and costs nothing else: this row
-- is created by the trigger at the bottom of this file, has no INSERT or
-- DELETE policy (so no client can forge or remove one), and its id is still
-- exactly the auth id every policy compares against.
create table if not exists public.profiles (
  id uuid primary key,
  display_name text not null,
  avatar_url text,

  -- Tombstone markers, both null for a live account.
  --
  -- A person asks to be deleted by stamping deletion_requested_at on their
  -- own row. The external 30-day sweep purges the auth.users login and
  -- scrubs its email when the grace period expires, and stamps deleted_at
  -- here. This row itself is never deleted -- it is the credit.
  deletion_requested_at timestamptz,
  deleted_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

alter table public.profiles enable row level security;

-- Every user can always see and edit their own profile row.
--
-- There is no INSERT policy (rows come only from handle_new_user below) and
-- no DELETE policy (a profile is the credit under a photo and must outlive
-- the account). Both omissions are deny-all, and deliberate.
drop policy if exists "profiles_select_self" on public.profiles;
create policy "profiles_select_self"
  on public.profiles for select
  to authenticated
  using (id = auth.uid());

-- Self-update covers the display name the sign-in provider seeded (providers
-- hand back full legal names, so this is expected to be edited), the avatar,
-- and deletion_requested_at, which is how a person asks to be forgotten.
-- deleted_at is stamped by the sweep rather than the person, but is not
-- pinned here: a stray value on your own row changes only how your own name
-- renders, and is reversible.
drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- The "see the names of the people I travel with, and of whoever is credited
-- on a photo in my trips" policy is added in 0009_profile_visibility.sql,
-- once trips and photos exist to be credited on.

-- Auto-create a profile row whenever a new auth.users row appears (i.e. on
-- first Sign in with Apple / Google). display_name falls back to a generic
-- label; the app should prompt the user to set a real one after first
-- sign-in. Apple in particular returns a name only on the very first
-- authorization, so the fallback is a normal case, not an edge one.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', 'New traveller'))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
