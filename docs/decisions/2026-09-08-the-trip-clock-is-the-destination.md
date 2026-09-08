# The trip clock is the destination's IANA zone — 8 September 2026

**Captain's decision:** Cairn's one trip clock is the destination's real IANA
zone, not the phone's current zone and not a fixed UTC offset. A Singapore
phone holding a Milan plan therefore reads and schedules Milan time.

`trip_facts.time_zone` is the durable on-device copy. The server already owns
the same immutable `trips.timezone` field, so a reconcile copies the server's
value locally and a later offline launch derives exactly the same schedule.
`trip_moments` converts every dated wall-clock slot through that IANA zone;
the offset is selected for the specific date, so the spring and autumn DST
changes do not shift a day's wake-up window.

## Establishing the zone

For an existing shared trip, the server row is authoritative. For a new one,
the composition root currently accepts only an explicit
`CAIRN_TRIP_TIMEZONE=Europe/Rome` destination value. A place name in the
plan is not a timezone: inferring one would need a geocoder or a global
gazetteer and would silently guess for ambiguous or unsupported places. The
existing `TimeZoneEdge` remains the single seam for an IANA name, but the
phone's `DeviceTimeZone` is deliberately not used as destination evidence.

Until a person-facing destination selector supplies that explicit IANA name,
an unset new trip stays local and reports `awaitingTripRow`; its ping schedule
is empty. That is intentional, visible degradation, never a fallback to the
phone's zone. Rows from before the local migration also start as unknown and
remain quiet until a reconcile copies their server clock.

No Supabase migration accompanies this change: `trips.timezone` already
exists, is validated by the server, and is immutable after trip creation.
