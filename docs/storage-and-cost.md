# What the pool costs, measured

The pool keeps **originals**. That was settled on 2026-08-22
([grill round one](decisions/2026-08-22-grill-round-one.md) §3): resizing is
for display only, because the trip ends with a full-size set of everyone's
photographs on everyone's phone, and a promise like that cannot be kept out of
thumbnails.

The decision came with a warning that the bill had never been sized, and the
repo then carried two written guesses that disagreed with each other by about
two years. Neither had been measured. This file is the measurement, the method
that produced it, and the number it lands on.

**The plain answer: storage is not free, and it is not expensive.** At the way
Cairn actually works — one ping a day, so one photograph per person per day —
eight people on a fortnight's trip put about **0.31 GB** into the pool, and
Cloudflare R2's standing free 10 GB fits roughly **32 such trips at once**. At
five trips a year, that allowance holds until somewhere in **year six**. Let
people also import their camera roll at ten photographs each a day and the same
trip is **3.14 GB**, the free tier holds three of them, and the archive costs
about **$1 a year in year one rising to $12 a year by year five**. The heavy
reading — thirty photographs each a day — passes the free tier inside the first
trip and reaches roughly **$40 a year by year five**.

Dollars a year, then. Not free, and not a reason to store anything smaller than
the original.

## The corpus

Measured 2026-08-25 against the untouched originals of a personal macOS Photos
library — a real phone's accumulated camera roll, not a synthetic set:

| | Whole library | Camera originals (≥ 1 MB) |
|---|---|---|
| files | 6,185 | 1,362 |
| total | 4.71 GB | 3.73 GB |
| median | 0.20 MB | **2.80 MB** |
| mean | 0.76 MB | 2.74 MB |
| p10 | 0.07 MB | 1.37 MB |
| p90 | 2.91 MB | 3.93 MB |
| p99 | 4.26 MB | 5.16 MB |
| max | 7.00 MB | 7.00 MB |

The two columns are the first thing the measurement taught, and the reason a
number pulled out of the air was never going to be right. **A photo library is
mostly not photographs a camera took.** The whole-library median of 0.20 MB is
a median of messaging-app re-compressions, saved images and screenshots, and
sizing the pool from it would understate the bill by roughly fourteen times.
The 1 MB floor in the second column is a coarse instrument, chosen because the
distribution is plainly bimodal there and not because 1 MB means anything; the
format breakdown below is the check that it cut in the right place.

| format | count (≥ 1 MB) | median | mean |
|---|---|---|---|
| jpeg | 986 | **3.08 MB** | 2.92 MB |
| heic | 376 | 2.20 MB | 2.28 MB |

HEIC is what an iPhone's camera writes by default, and it lands around 2.2 MB.
JPEG of the same scenes lands around 3.1 MB — the ~1.4× is HEIC's whole point.
**Cairn's own captures are JPEG**: `package:camera`'s `takePicture` writes JPEG
on iOS, and `BackCameraSource` now asks for `ResolutionPreset.max` so the frame
is the sensor's full one. So the figure that applies to a photograph *this app
takes* is the JPEG one, about **3 MB**, and the pooled ≥ 1 MB median of 2.80 MB
used in the tables below is if anything slightly kind.

## One trip

Eight people, fourteen days, priced from the ≥ 1 MB corpus:

| photographs each, a day | photographs | pool | trips inside the free 10 GB | each beyond it |
|---|---|---|---|---|
| 1 — the ping alone | 112 | 0.31 GB | 31.9 | $0.00/month |
| 10 — ping plus a modest import | 1,120 | 3.14 GB | 3.2 | $0.05/month |
| 30 — an enthusiastic fortnight | 3,360 | 9.41 GB | 1.1 | $0.14/month |

The first row is what the app does today and the only one its design actually
promises: the ping is one a day per person, by construction
([the moment](decisions/2026-08-22-the-moment.md)). The other two are what the
pool becomes once the import sweep lands and a day's camera roll can be added
to it — which is not built, and is the single decision that moves this bill by
an order of magnitude.

## The archive, at five trips a year

R2's 10 GB is a standing monthly allowance, not a lifetime one, so the archive
bills on whatever it holds in a given month:

| | 1 photo each a day | 10 each a day | 30 each a day |
|---|---|---|---|
| year 1 | 1.6 GB — free | 15.7 GB — $1.02/year | 47.0 GB — $6.67/year |
| year 2 | 3.1 GB — free | 31.4 GB — $3.84/year | 94.1 GB — $15.13/year |
| year 3 | 4.7 GB — free | 47.0 GB — $6.67/year | 141.1 GB — $23.60/year |
| year 5 | 7.8 GB — free | 78.4 GB — $12.31/year | 235.2 GB — $40.53/year |

## What does not bill

- **Egress is free on R2 at every tier**, which is why the bytes live there and
  not in Supabase storage. A shared pool is almost entirely downloads; on a
  metered store that, and not storage, would be the bill.
- **Operations are not close to the ceiling.** A trip at the ping-only reading
  writes 112 objects (Class A, free to 1,000,000/month) and, if all eight
  people scroll the whole pool without a cache hit, reads about 900 (Class B,
  free to 10,000,000/month). Even the heavy reading is three orders of
  magnitude inside both, and `r2_object_key` is immutable so a phone's cached
  bytes never go stale and never re-fetch.
- **The Postgres index is not the constraint either.** A `photos` row is a
  couple of hundred bytes; the heavy reading at five trips a year is under
  4 MB a year against Supabase's free 500 MB.

So of everything in the backend, **object storage is the only line that will
ever produce an invoice**, and the two things that actually threaten the
project remain operational rather than financial: the Supabase free project
pausing after a week of inactivity, and unbounded accumulation over years. See
[supabase/README.md](../supabase/README.md).

## Redoing this

`tool/measure_photo_corpus.dart` is the measurement. It reads file *sizes*
only — it never opens a file, and prints no filename — so it can be pointed at
a private library without leaking anything into a terminal or a commit.

```
# the corpus tables above
dart run tool/measure_photo_corpus.dart \
  ~/Pictures/'Photos Library.photoslibrary'/originals
dart run tool/measure_photo_corpus.dart \
  ~/Pictures/'Photos Library.photoslibrary'/originals --min-bytes 1000000

# the trip and archive tables (--per-person-per-day 1, then 10, then 30)
dart run tool/measure_photo_corpus.dart \
  ~/Pictures/'Photos Library.photoslibrary'/originals \
  --min-bytes 1000000 --per-person-per-day 10
```

The pricing constants it applies (`R2Pricing` in that file) were read from
[developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/)
on 2026-08-25: 10 GB-month free, $0.015/GB-month beyond it, and no egress
charge at any tier.

Any corpus works. The one thing the measurement will get wrong if it is
repeated carelessly is the one it got wrong first: **measure camera originals,
not everything with an image extension.** Check the format breakdown before
believing a median.

## How to keep this file honest

Two numbers here go stale in different ways. The corpus is a fact about phones
and drifts slowly upward as sensors grow. Cloudflare's prices are a fact about
Cloudflare and can change on their own. Re-run the tool before quoting the
figure anywhere that matters, and re-read the pricing page when you do — and if
either has moved, change this file rather than adding a second estimate beside
it. Two disagreeing estimates is exactly the state this file was written to end.
