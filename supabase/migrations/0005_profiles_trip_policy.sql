-- Deferred from 0002_profiles.sql: now that trip_members exists, let a
-- user see the display name/avatar of anyone they share a trip with (the
-- Pool needs to show "who took this photo").
drop policy if exists "profiles_select_trip_co_member" on public.profiles;
create policy "profiles_select_trip_co_member"
  on public.profiles for select
  to authenticated
  using (
    exists (
      select 1
      from public.trip_members mine
      join public.trip_members theirs
        on theirs.trip_id = mine.trip_id
      where mine.user_id = auth.uid()
        and theirs.user_id = profiles.id
    )
  );
