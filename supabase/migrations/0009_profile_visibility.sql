-- Deferred from 0002_profiles.sql: who can read someone else's name.
--
-- This is last in the sequence rather than first because it now depends on
-- photos and trips as well as membership, and a migration should never
-- reference a table that does not exist yet. It used to sit at 0005 and check
-- shared membership only.
--
-- Shared membership alone is not enough, because it is exactly the thing that
-- ends. Someone leaves a trip, or is removed after a wrong join, or deletes
-- their account and is left as a name-only tombstone -- and in every one of
-- those cases their photos stay in the pool by decision, while the row that
-- proved you shared a trip with them is gone. A membership-only policy would
-- have left those photos rendering a blank byline, which is the same defect
-- the profiles/auth.users cascade caused, arriving by a different route.
--
-- So visibility follows the credit: you can read the name of anyone you are
-- travelling with, and of anyone whose name is printed on something in a trip
-- you are in.
create or replace function public.profile_is_visible_to(p_profile_id uuid, p_viewer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    -- On a trip with me.
    exists (
      select 1
      from public.trip_members mine
      join public.trip_members theirs on theirs.trip_id = mine.trip_id
      where mine.user_id = p_viewer_id
        and theirs.user_id = p_profile_id
    )
    -- Credited under a photo in a trip I am in.
    or exists (
      select 1
      from public.photos ph
      join public.trip_members mine on mine.trip_id = ph.trip_id
      where ph.contributor_id = p_profile_id
        and mine.user_id = p_viewer_id
    )
    -- Or started a trip I am in.
    or exists (
      select 1
      from public.trips t
      join public.trip_members mine on mine.trip_id = t.id
      where t.created_by = p_profile_id
        and mine.user_id = p_viewer_id
    );
$$;

revoke all on function public.profile_is_visible_to(uuid, uuid) from public;
grant execute on function public.profile_is_visible_to(uuid, uuid) to authenticated, service_role;

drop policy if exists "profiles_select_trip_co_member" on public.profiles;
drop policy if exists "profiles_select_credited_or_co_member" on public.profiles;
create policy "profiles_select_credited_or_co_member"
  on public.profiles for select
  to authenticated
  using ( public.profile_is_visible_to(profiles.id, auth.uid()) );
