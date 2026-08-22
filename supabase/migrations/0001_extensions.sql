-- Extensions and schema-wide utilities.
--
-- pgcrypto gives us gen_random_uuid() for primary keys.
create extension if not exists pgcrypto;

-- Every client-synced table carries an updated_at that this one trigger
-- function bumps.
--
-- It exists because the phone pulls with a high-water mark per (table, trip):
-- `where trip_id = $1 and updated_at > cursor order by updated_at`. A cursor
-- over created_at can only ever see rows that are new, so an *edit* -- a
-- hand-corrected trip_day, a renamed trip, a recomposed day page -- would
-- never reach the other phones. Bumping updated_at on write is what makes a
-- correction syncable.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
