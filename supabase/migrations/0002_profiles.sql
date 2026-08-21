-- One row per authenticated user, mirroring auth.users.
--
-- Exists so other tables (trip_members, photos) can carry a display name
-- and avatar without ever exposing auth.users -- which holds email and
-- other auth-sensitive columns -- to client queries.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  avatar_url text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Every user can always see and edit their own profile row.
drop policy if exists "profiles_select_self" on public.profiles;
create policy "profiles_select_self"
  on public.profiles for select
  to authenticated
  using (id = auth.uid());

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- The cross-trip "see my co-members' names" policy is added in
-- 0005_profiles_trip_policy.sql, once trip_members exists.

-- Auto-create a profile row whenever a new auth.users row appears (i.e. on
-- first Sign in with Apple). display_name falls back to a generic label;
-- the app should prompt the user to set a real one after first sign-in.
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
