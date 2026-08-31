-- 0012: tap-to-Maps area columns on trip_itinerary_stops.
-- Additive only. Applied to the hosted project 2026-08-31.
-- Validated locally via rls_probe double-apply.

alter table trip_itinerary_stops
  add column if not exists kind text not null default 'place',
  add column if not exists area_text text,
  add column if not exists area_source text;

-- sync_trip_itinerary's insert list and pull-side jsonb_build_object
-- gain the three columns. The function is recreated in full to avoid
-- patching a moving target; the body is otherwise identical to 0010.
-- For this scaffold the columns ride the cargo as stored; the function
-- update is 0013, applied separately (see 0010 lines 384-392, 442-455).
