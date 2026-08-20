-- Invite codes live in their own table rather than as a column on trips.
-- That lets a code be rotated or revoked without mutating trip identity,
-- lets a trip have more than one outstanding code (e.g. one per expected
-- guest, or a permanent one and a time-boxed one), and keeps the "how do
-- people get in" concern separate from "what is this trip" concern.
--
-- Codes are short, human-typeable strings (8 chars, uppercase, an
-- unambiguous alphabet) meant to be shared as a code OR embedded in a
-- deep link (traveling-app://join/<code>) -- same code, two delivery
-- mechanisms, so we only need one artifact.
create table if not exists public.trip_invites (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  code text not null unique,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  max_uses integer check (max_uses is null or max_uses > 0),
  use_count integer not null default 0
);

create index if not exists trip_invites_trip_id_idx on public.trip_invites (trip_id);

alter table public.trip_invites enable row level security;

-- Only the trip's owner(s) can view or manage invite codes. A non-member
-- (or a plain member) cannot list codes for a trip -- redemption is the
-- only way in, via the function below, which looks codes up itself and
-- does not depend on this policy.
drop policy if exists "trip_invites_select_owner" on public.trip_invites;
create policy "trip_invites_select_owner"
  on public.trip_invites for select
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = trip_invites.trip_id
        and trip_members.user_id = auth.uid()
        and trip_members.role = 'owner'
    )
  );

drop policy if exists "trip_invites_insert_owner" on public.trip_invites;
create policy "trip_invites_insert_owner"
  on public.trip_invites for insert
  to authenticated
  with check (
    created_by = auth.uid()
    and exists (
      select 1 from public.trip_members
      where trip_members.trip_id = trip_invites.trip_id
        and trip_members.user_id = auth.uid()
        and trip_members.role = 'owner'
    )
  );

drop policy if exists "trip_invites_update_owner" on public.trip_invites;
create policy "trip_invites_update_owner"
  on public.trip_invites for update
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = trip_invites.trip_id
        and trip_members.user_id = auth.uid()
        and trip_members.role = 'owner'
    )
  );

drop policy if exists "trip_invites_delete_owner" on public.trip_invites;
create policy "trip_invites_delete_owner"
  on public.trip_invites for delete
  to authenticated
  using (
    exists (
      select 1 from public.trip_members
      where trip_members.trip_id = trip_invites.trip_id
        and trip_members.user_id = auth.uid()
        and trip_members.role = 'owner'
    )
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
begin
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

  insert into public.trip_members (trip_id, user_id, role)
  values (v_invite.trip_id, auth.uid(), 'member')
  on conflict (trip_id, user_id) do nothing;

  update public.trip_invites
  set use_count = use_count + 1
  where id = v_invite.id;

  return v_invite.trip_id;
end;
$$;

grant execute on function public.redeem_trip_invite(text) to authenticated;
