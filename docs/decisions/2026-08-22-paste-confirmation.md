# The screen after the paste — 22 August 2026

Held open from design round seven, which found that the itinerary parser
returns a confidence and documents its own limits, while no screen existed to
show what it understood or to correct it. A parser designed to be sometimes
wrong, with nowhere to correct it, is a defect.

Resolved by commissioning design round eight, which drew four surfaces: the
confident read, the uncertain read, correcting it, and the paste that could
not be read at all. Shipped on pull request #11; the surfaces live in
`docs/design/2026-08-22-round8-handoff.zip` and are designed to
`packages/itinerary_parser/README.md`'s contract.

Follow-on discovered while drawing it: round eight draws behaviours the
parser cannot currently report. It explains why it is unsure and offers to
reinterpret a whole paste as month-first dates; the package exposes neither a
reason on a day nor a date-order parameter. That is an API extension, cheap
if done before the screen is coded around the gap.
