-- Invite codes live in their own table rather than as a column on trips.
-- That lets a code be rotated or revoked without mutating trip identity,
-- lets a trip have more than one outstanding code (e.g. one per expected
-- guest, or one said aloud and one carried in a link, so a leak can be shut
-- without shutting the door), and keeps the "how do people get in" concern
-- separate from "what is this trip" concern.
--
-- A code is THREE SPOKEN WORDS -- two words and a two-digit number, written
-- `otter maple 42` -- forgiving of the order they were said in and of one
-- letter per word (`docs/decisions/2026-08-22-grill-round-one.md` §5). It
-- replaced an eight-character generator, which was a thing you spell out
-- rather than a thing you say across a table.
--
-- The phone's half of that grammar is `packages/cairn_model`'s
-- `InviteCode` (`lib/src/invite_code.dart`); this file is the server's half,
-- and the two have to agree letter for letter, because a code minted on one
-- side is typed into the other. `supabase/tests/rls_probe.py` reads the Dart
-- vocabulary out of that file and compares it with this one, so a word added
-- on either side alone fails rather than quietly widening the code space.
--
-- **A code carries no expiry of its own.** It dies when its trip closes and
-- at no other time, so there is no `expires_at` column here: the close is
-- derived from the trip (end date plus the grace) every time it is asked
-- for. Two timestamps for one rule are two chances to disagree about when a
-- trip is over -- the same reason `cairn_model`'s `trip_close.dart` keeps it
-- one value and the phone's `trip_invite_codes` table has no expiry column
-- either.
create table if not exists public.trip_invites (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id) on delete cascade,
  code text not null,
  created_by uuid not null references public.profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  max_uses integer check (max_uses is null or max_uses > 0),
  use_count integer not null default 0
);

-- A database that was created before the code became three words carried a
-- per-invite expiry and a plain unique on the spelling. Both are wrong now
-- and both are dropped here rather than left to rot behind an
-- `if not exists` table: the expiry because the trip's close is the only
-- expiry there is, and the unique because `otter maple 42` and
-- `maple otter 42` are one code, which only the canonical index below
-- knows.
alter table public.trip_invites drop column if exists expires_at;
alter table public.trip_invites drop constraint if exists trip_invites_code_key;

create index if not exists trip_invites_trip_id_idx on public.trip_invites (trip_id);

drop trigger if exists trip_invites_touch_updated_at on public.trip_invites;
create trigger trip_invites_touch_updated_at
  before update on public.trip_invites
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- The three-word grammar
-- ---------------------------------------------------------------------------

-- The vocabulary codes are drawn from, and the only words a said word is
-- allowed to resolve to.
--
-- Every word is four to eight letters, has one obvious spelling, and is at
-- least three edits away from every other word here. Three is what makes one
-- letter of slack unambiguous: a said word within one edit of two different
-- words would be a code nobody could type. That property is pinned on the
-- phone's side by `packages/cairn_model/test/invite_code_test.dart`; this
-- list is a copy of the same words, and the probe checks the two are
-- identical rather than trusting them to stay so.
create or replace function public.invite_code_words()
returns text[]
language sql
immutable
parallel safe
as $$
  select array[
    'acorn', 'almond', 'amber', 'anchor', 'anvil', 'apricot',
    'bamboo', 'basket', 'beacon', 'bison', 'cabin', 'cactus',
    'candle', 'cedar', 'clover', 'compass', 'copper', 'dahlia',
    'daisy', 'dolphin', 'domino', 'dragon', 'drift', 'elder',
    'falcon', 'feather', 'ferry', 'fjord', 'fossil', 'garden',
    'gecko', 'ginger', 'glacier', 'hammock', 'harbour', 'harvest',
    'hazel', 'hedge', 'heron', 'honey', 'ibex', 'indigo',
    'iris', 'island', 'ivory', 'jackal', 'jasmine', 'jetty',
    'jungle', 'juniper', 'kayak', 'kelp', 'kestrel', 'kettle',
    'knoll', 'koala', 'ladder', 'lagoon', 'lantern', 'lilac',
    'llama', 'lupin', 'mammoth', 'mango', 'maple', 'marsh',
    'meadow', 'monsoon', 'narwhal', 'nectar', 'needle', 'nook',
    'nutmeg', 'oasis', 'ocelot', 'octopus', 'olive', 'orchard',
    'otter', 'parcel', 'parsnip', 'pebble', 'puffin', 'pumpkin',
    'quail', 'quartz', 'quince', 'quokka', 'rabbit', 'radish',
    'reindeer', 'ribbon', 'river', 'sorrel', 'summit', 'tapir',
    'teal', 'temple', 'thistle', 'tulip', 'tunnel', 'umbrella',
    'urchin', 'velvet', 'vessel', 'violet', 'vulture', 'walnut',
    'willow', 'wombat', 'yarrow', 'yonder', 'yucca', 'zebra',
    'zenith', 'zephyr', 'zinnia'
  ]::text[];
$$;

-- How many edits a said word may be from a real one and still be that word.
create or replace function public.invite_code_spelling_slack()
returns integer
language sql
immutable
parallel safe
as $$ select 1; $$;

-- How far apart two words are, **counting a swapped pair of adjacent letters
-- as one edit** rather than two: the optimal string alignment distance.
--
-- Written out rather than taken from `fuzzystrmatch`, whose `levenshtein()`
-- prices `mapel` for `maple` at two and would therefore refuse the most
-- ordinary way there is to mistype a word -- while the phone accepts it.
-- The two halves of one grammar cannot disagree about which near-spellings
-- are the same code, so this is the same algorithm as `_editDistance` in
-- `packages/cairn_model/lib/src/invite_code.dart`, and not a near relative
-- of it.
create or replace function public.invite_word_distance(a text, b text)
returns integer
language plpgsql
immutable
parallel safe
as $$
declare
  la integer := length(a);
  lb integer := length(b);
  prev2 integer[];
  prev integer[];
  cur integer[];
  i integer;
  j integer;
  cost integer;
  best integer;
  candidate integer;
begin
  if la = 0 then return lb; end if;
  if lb = 0 then return la; end if;

  prev := array(select generate_series(0, lb));
  for i in 1..la loop
    cur := array_fill(0, array[lb + 1]);
    cur[1] := i;
    for j in 1..lb loop
      cost := case when substr(a, i, 1) = substr(b, j, 1) then 0 else 1 end;
      best := prev[j + 1] + 1;                 -- deletion
      candidate := cur[j] + 1;                 -- insertion
      if candidate < best then best := candidate; end if;
      candidate := prev[j] + cost;             -- substitution
      if candidate < best then best := candidate; end if;
      if i > 1 and j > 1
         and substr(a, i, 1) = substr(b, j - 1, 1)
         and substr(a, i - 1, 1) = substr(b, j, 1) then
        candidate := prev2[j - 1] + 1;         -- transposition
        if candidate < best then best := candidate; end if;
      end if;
      cur[j + 1] := best;
    end loop;
    prev2 := prev;
    prev := cur;
  end loop;
  return prev[lb + 1];
end;
$$;

-- The word [said] was reaching for, or null if it was not reaching for one.
create or replace function public.invite_code_word(said text)
returns text
language plpgsql
immutable
parallel safe
as $$
declare
  v_slack integer := public.invite_code_spelling_slack();
  w text;
begin
  if said is null then return null; end if;
  foreach w in array public.invite_code_words() loop
    if w = said then return w; end if;
  end loop;
  foreach w in array public.invite_code_words() loop
    if abs(length(w) - length(said)) > v_slack then continue; end if;
    if public.invite_word_distance(w, said) <= v_slack then return w; end if;
  end loop;
  return null;
end;
$$;

-- The one spelling of the code somebody said, or null if they did not say a
-- code.
--
-- Everything that is not a letter or a digit is a gap, so `otter-maple-42`,
-- `Otter Maple 42` and `otter, maple, 42` are one code said three ways. The
-- two words come back in alphabetical order, which is what makes the code
-- forgiving of the order it was said in: this is the value uniqueness and
-- lookup are both defined over, never the spelling as it was written down.
create or replace function public.invite_code_key(p_text text)
returns text
language plpgsql
immutable
parallel safe
as $$
declare
  v_tokens text[];
  v_token text;
  v_number integer;
  v_said text[] := array[]::text[];
  v_first text;
  v_second text;
begin
  if p_text is null then return null; end if;
  select array_agg(t) into v_tokens
  from unnest(regexp_split_to_array(lower(p_text), '[^a-z0-9]+')) t
  where t <> '';
  if v_tokens is null or array_length(v_tokens, 1) <> 3 then return null; end if;

  -- `{1,9}` rather than `+` so a run of forty digits falls through to the
  -- word branch and fails to resolve, the way the phone reads it as a number
  -- and then fails the range. Casting it would overflow instead, and an
  -- overflow inside an immutable function is an error where a refusal
  -- belongs.
  foreach v_token in array v_tokens loop
    if v_number is null and v_token ~ '^[0-9]{1,9}$' then
      v_number := v_token::integer;
    else
      v_said := v_said || v_token;
    end if;
  end loop;

  if v_number is null or v_number < 10 or v_number > 99 then return null; end if;
  if array_length(v_said, 1) <> 2 then return null; end if;

  v_first := public.invite_code_word(v_said[1]);
  v_second := public.invite_code_word(v_said[2]);
  if v_first is null or v_second is null or v_first = v_second then
    return null;
  end if;

  if v_first > v_second then
    return v_second || ' ' || v_first || ' ' || v_number::text;
  end if;
  return v_first || ' ' || v_second || ' ' || v_number::text;
end;
$$;

-- A row whose code is not a code at all would be a code nobody could ever
-- redeem, sitting in the table looking live.
alter table public.trip_invites drop constraint if exists trip_invites_code_is_sayable;
alter table public.trip_invites
  add constraint trip_invites_code_is_sayable
  check (public.invite_code_key(code) is not null);

-- Uniqueness is over the canonical spelling, not the written one: two rows
-- that differ only in the order their words were written down are one code
-- with two histories.
create unique index if not exists trip_invites_code_key_idx
  on public.trip_invites (public.invite_code_key(code));

-- Draws a code the way `InviteCode.draw` does: two distinct words and a
-- two-digit number. The second word is drawn from what is left after the
-- first is taken out, so no draw can produce `otter otter 42`.
--
-- A little over six hundred thousand codes, which is sized against two
-- people on the same trip minting codes minutes apart rather than against
-- somebody guessing at a server -- see the collision note in
-- `supabase/README.md`, which this space made a real case rather than a
-- theoretical one.
create or replace function public.generate_invite_code()
returns text
language plpgsql
volatile
as $$
declare
  v_words text[] := public.invite_code_words();
  v_remaining text[];
  v_first text;
  v_second text;
begin
  v_first := v_words[1 + floor(random() * array_length(v_words, 1))::int];
  select array_agg(w order by w) into v_remaining
  from unnest(v_words) w where w <> v_first;
  v_second := v_remaining[1 + floor(random() * array_length(v_remaining, 1))::int];
  return v_first || ' ' || v_second || ' ' || (10 + floor(random() * 90)::int)::text;
end;
$$;

alter table public.trip_invites
  alter column code set default public.generate_invite_code();

-- ---------------------------------------------------------------------------
-- When a code dies
-- ---------------------------------------------------------------------------

-- How long after a trip ends it still takes photographs, and therefore how
-- long its codes still open it.
--
-- Seventy-two hours, confirmed on 26 August 2026
-- (`docs/decisions/2026-08-26-the-ending.md`). People empty their camera roll
-- within days of getting home or they never do, so the length of the window
-- buys silence rather than photographs: three days covers the flight home and
-- the first evening back, and then the trip becomes a keepsake instead of
-- trailing off. This is the same number as `graceAfterATrip` in
-- `packages/cairn_model/lib/src/trip_close.dart`, and the probe compares the
-- two: one rule, written twice, is two chances to disagree about when a trip
-- is over.
create or replace function public.trip_grace_after_end()
returns interval
language sql
immutable
parallel safe
as $$ select interval '72 hours'; $$;

-- The instant a trip stops accepting new contributions, and with it the
-- instant its invite codes stop opening anything.
--
-- The trip's last day ends at midnight *in the trip's own clock*, not at
-- midnight UTC, which is why this reads `timezone` rather than adding a day
-- to a date. It mirrors `cairn_model`'s `Trip.closesAt`
-- (`tripClosesAt(endsAt)`, where `endsAt` is the last day's start plus a
-- day). The one place the two can still differ is a trip that crosses zones:
-- the phone can hold a per-day clock and `trips` deliberately holds one --
-- see the comment in `0003_trips.sql`.
--
-- Null for a trip this caller cannot see, which is not the same as "never
-- expires" and is never read as one.
create or replace function public.trip_closes_at(p_trip_id uuid)
returns timestamptz
language sql
stable
as $$
  select ((t.end_date + 1)::timestamp at time zone t.timezone)
         + public.trip_grace_after_end()
  from public.trips t
  where t.id = p_trip_id;
$$;

-- The grammar helpers above read nothing and are left executable by anyone:
-- they turn text into text, and a caller who can already say a code learns
-- nothing from being told how it is spelled. `trip_closes_at` is different --
-- it reads `trips` -- so it is narrowed to signed-in callers, where the
-- table's own row-level security then decides whether they see the trip at
-- all.
revoke all on function public.trip_closes_at(uuid) from public;
grant execute on function public.trip_closes_at(uuid) to authenticated, service_role;
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


-- ---------------------------------------------------------------------------
-- Redeeming
-- ---------------------------------------------------------------------------

-- Redeeming a code is the only way to join a trip you don't already own.
-- This has to run as SECURITY DEFINER: a not-yet-member cannot be granted
-- SELECT on trip_invites (that would let anyone enumerate/guess codes by
-- reading the table), and cannot INSERT into trip_members directly, so the
-- lookup-and-join has to happen inside a function that runs with the
-- table owner's privileges, bypassing both policies for this one
-- validated operation.
--
-- It takes the code as it was *said*, not as it was written: the caller
-- hands over whatever somebody typed and the canonical spelling is derived
-- here, so word order and one letter per word are forgiven by the same rule
-- the phone forgives them by.
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
  v_key text;
  v_closes_at timestamptz;
begin
  -- An elevated-privilege function must never run for a caller it cannot
  -- name. Without this the anonymous case reaches the insert below and fails
  -- on a not-null violation, which reads like a bug rather than a refusal.
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  -- Text that is not a code at all and a code nobody minted are refused with
  -- the same sentence on purpose: telling them apart would tell a guesser
  -- which of the two halves of their guess was wrong.
  v_key := public.invite_code_key(p_code);
  if v_key is null then
    raise exception 'invite code not found';
  end if;

  select * into v_invite
  from public.trip_invites
  where public.invite_code_key(code) = v_key
  for update;

  if not found then
    raise exception 'invite code not found';
  end if;

  -- A code dies with its trip and at no other moment. After the close every
  -- day of the trip is past, so a code that outlived it would open the whole
  -- archive to whoever still remembered three words
  -- (`docs/decisions/2026-08-22-grill-round-one.md` §5).
  v_closes_at := public.trip_closes_at(v_invite.trip_id);
  if v_closes_at is not null and now() >= v_closes_at then
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
