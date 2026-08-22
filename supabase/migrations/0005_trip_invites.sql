-- Invite codes live in their own table rather than as a column on trips.
-- That lets a code be rotated or revoked without mutating trip identity,
-- lets a trip have more than one outstanding code (e.g. one per expected
-- guest, or a permanent one and a time-boxed one), and keeps the "how do
-- people get in" concern separate from "what is this trip" concern.
--
-- Codes are short, human-typeable strings (8 chars, uppercase, an
-- unambiguous alphabet) meant to be shared as a code OR embedded in a
-- deep link (traveling-app://join/<code>) -- same code, two delivery mechanisms,
-- so we only need one artifact.
create table if not exists public.trip_invites (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  code text not null unique,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz,
  max_uses integer check (max_uses is null or max_uses > 0),
  use_count integer not null default 0
);

create index if not exists trip_invites_trip_id_idx on public.trip_invites (trip_id);

drop trigger if exists trip_invites_touch_updated_at on public.trip_invites;
create trigger trip_invites_touch_updated_at
  before update on public.trip_invites
  for each row execute function public.touch_updated_at();

-- An invite belongs to the trip it was minted for. Rotating a code means
-- minting a new one and revoking the old, not repointing an existing one --
-- otherwise a code already circulating for one trip could be redirected
-- to admit people into another.
create or replace function public.trip_invites_lock_trip_id()
returns trigger
language plpgsql
as $$
begin
  if new.trip_id is distinct from old.trip_id then
    raise exception 'trip_invites.trip_id cannot be changed once set';
  end if;
  return new;
end;
$$;

drop trigger if exists trip_invites_lock_trip_id on public.trip_invites;
create trigger trip_invites_lock_trip_id
  before update on public.trip_invites
  for each row execute function public.trip_invites_lock_trip_id();

alter table public.trip_invites enable row level security;

-- Inviting is flat: any member of a trip can mint a code for it and read the
-- trip's codes. These policies used to be owner-only, which read as tighter
-- than it was -- anyone who joined by code already knows a working code and
-- can simply repeat it aloud, so restricting who may *create* one bought
-- almost no safety while making the trip's starter a bottleneck, which is
-- itself an asymmetry the decision record does not grant them. The undo for a
-- wrong join is removal, and removal is the starter's.
drop policy if exists "trip_invites_select_owner" on public.trip_invites;
drop policy if exists "trip_invites_select_member" on public.trip_invites;
create policy "trip_invites_select_member"
  on public.trip_invites for select
  to authenticated
  using ( public.is_trip_member(trip_invites.trip_id, auth.uid()) );

drop policy if exists "trip_invites_insert_owner" on public.trip_invites;
drop policy if exists "trip_invites_insert_member" on public.trip_invites;
create policy "trip_invites_insert_member"
  on public.trip_invites for insert
  to authenticated
  with check (
    created_by = auth.uid()
    and public.is_trip_member(trip_invites.trip_id, auth.uid())
  );

-- Revoking or time-boxing a code is for whoever minted it, plus the trip's
-- starter, who has to be able to shut a leaked code they did not create.
drop policy if exists "trip_invites_update_owner" on public.trip_invites;
drop policy if exists "trip_invites_update_creator_or_starter" on public.trip_invites;
create policy "trip_invites_update_creator_or_starter"
  on public.trip_invites for update
  to authenticated
  using (
    trip_invites.created_by = auth.uid()
    or public.is_trip_starter(trip_invites.trip_id, auth.uid())
  )
  with check (
    created_by = auth.uid()
    or public.is_trip_starter(trip_invites.trip_id, auth.uid())
  );

drop policy if exists "trip_invites_delete_owner" on public.trip_invites;
drop policy if exists "trip_invites_delete_creator_or_starter" on public.trip_invites;
create policy "trip_invites_delete_creator_or_starter"
  on public.trip_invites for delete
  to authenticated
  using (
    trip_invites.created_by = auth.uid()
    or public.is_trip_starter(trip_invites.trip_id, auth.uid())
  );

-- Generates an 8-char code from an alphabet with ambiguous characters
-- (0/O, 1/I/L) removed, since these are read aloud and typed by hand.
create or replace function public.generate_invite_code()
returns text
language plpgsql
as $$
declare
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  result text := '';
  i integer;
begin
  for i in 1..8 loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end;
$$;

alter table public.trip_invites
  alter column code set default public.generate_invite_code();

-- Redeeming a code is the only way to join a trip you don't already own.
-- This has to run as SECURITY DEFINER: a not-yet-member cannot be granted
-- SELECT on trip_invites (that would let anyone enumerate/guess codes by
-- reading the table), and cannot INSERT into trip_members directly, so the
-- lookup-and-join has to happen inside a function that runs with the
-- table owner's privileges, bypassing both policies for this one
-- validated operation.
--
-- search_path is pinned to prevent search_path hijacking of a
-- SECURITY DEFINER function.
create or replace function public.redeem_trip_invite(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invite public.trip_invites%rowtype;
  v_uid uuid := auth.uid();
begin
  -- An elevated-privilege function must never run for a caller it cannot
  -- name. Without this the anonymous case reaches the insert below and fails
  -- on a not-null violation, which reads like a bug rather than a refusal.
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select * into v_invite
  from public.trip_invites
  where code = upper(trim(p_code))
  for update;

  if not found then
    raise exception 'invite code not found';
  end if;

  if v_invite.expires_at is not null and v_invite.expires_at < now() then
    raise exception 'invite code has expired';
  end if;

  if v_invite.max_uses is not null and v_invite.use_count >= v_invite.max_uses then
    raise exception 'invite code has been used up';
  end if;

  insert into public.trip_members (trip_id, user_id)
  values (v_invite.trip_id, v_uid)
  on conflict (trip_id, user_id) do nothing;

  -- Only a redemption that actually added someone spends a use. Re-running a
  -- deep link, or redeeming a code for a trip you are already on, is a no-op
  -- rather than a way to burn a limited code down to zero.
  if found then
    update public.trip_invites
    set use_count = use_count + 1
    where id = v_invite.id;
  end if;

  return v_invite.trip_id;
end;
$$;

revoke all on function public.redeem_trip_invite(text) from public;
grant execute on function public.redeem_trip_invite(text) to authenticated;
