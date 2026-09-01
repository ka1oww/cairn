# The starter, the trip, and who can invite — 22 August 2026

Three questions the implementation work surfaced, answered together because they
are the same question seen from three sides: what, exactly, is the one asymmetry
in a flat group?

## 1. When the starter leaves, the power passes to the longest-standing member

There is no handover dialog and no successor to name. If the person who started
the trip leaves, the removal power belongs to whoever has been on the trip
longest. There is always exactly one holder and it is never nobody.

**Why.** The removal power exists for one narrow reason: the join code is three
spoken words, so a wrong join is genuinely possible and somebody has to be able
to undo it. That need does not disappear when the starter leaves, so letting the
power vanish is the only option that leaves a real hole. Naming a successor is a
modal dialog at the worst possible moment, and it can be dismissed. Refusing to
let the starter leave traps someone who has fallen out with the group.

**It is narrower than a group admin, and that distinction is load-bearing.** A
group chat admin typically renames the group, pins things, moderates, and
promotes others. This role does exactly one thing: remove a member. It cannot
promote anyone, cannot moderate a photo, cannot touch anyone else's
contribution, and cannot make another person into a starter. Calling it "admin"
in the interface would over-promise it; it should not be surfaced as a title at
all.

**Implementation note.** The backend already treats the starter as a fact about
the trip (`trips.created_by`) rather than a membership row, so succession is a
change to one predicate: the starter, or the earliest-joined remaining member
if the starter has left. That succession remains pending.

## 2. Renaming is flat; deleting is not

Any member can rename the trip. Deleting it stays with the starter, **and only
while the trip holds nobody else's photos.** Once other people have contributed,
nobody can delete the trip, the starter included. Leaving is the action a person
actually needs.

Changing the trip's **timezone** belongs with delete, not with rename: it
silently re-times everyone's pings.

**Captain's ruling recorded 1 September 2026:** “sure let them rename it.”
Migration `0014_member_trip_rename.sql` brings the server up to this decision:
current members get a name-only update path and `name_revised_at` resolves
offline renames. The starter's broader update and delete policies are
unchanged, and so is the ending: a closed trip refuses a rename from anybody,
starter included, because what a trip was called is part of what it closed as
(`canRenameTrip` takes a `TripStanding` for exactly this). The refusal is
written on the *rename* and not on the member path — `guard_member_trip_rename`
asks `trip_closes_at` before it lets the starter past, and `sync_trip_name`
asks again — so it is a property of the record rather than of the one function
the app happens to call, and a bare `PATCH` round that function is refused
with it. It takes nothing else off the starter: everything they could already
do to a closed trip under `trips_update_starter` they still can.

**Why.** These look like one permission and are not remotely the same act.
Renaming is reversible, visible to everyone, and harmless - making somebody wait
for the starter to fix a typo is precisely the hierarchy the flat-roles decision
was meant to avoid. Deleting cascades every photo on the trip: the irreversible
destruction of eight people's memories by one tap. That is not a thing to make
convenient for anyone.

## 3. Inviting is flat

Any member can mint an invite code. Revoking one stays with whoever created it,
or with the starter.

**Why.** Restricting it buys almost nothing. The code is three spoken words, so
anybody already on the trip knows a working one and can repeat it across a
table. Starter-only creation does not prevent that; it only makes the starter a
bottleneck when someone's flatmate joins late, which is itself an asymmetry the
record never granted them.

This is safer than it was before the validation pipeline ran. An invite code
could previously be **repointed at a different trip while already circulating**,
so a code handed out for one trip could quietly become a key to another. That is
now refused at the database level: rotating a code means minting a new one and
revoking the old.

**Flat invites and decision 1 are linked.** More people able to admit someone
means the wrong-join case matters slightly more, which is a further reason the
removal power must never vanish.
