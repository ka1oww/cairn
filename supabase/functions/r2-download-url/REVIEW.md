# The download function, read against the checklist

`r2-download-url` is the one security-relevant file in this repository. The
transport plan (§7.3) says it gets, before it is deployed anywhere anybody
cares about, two things: **a human review of the file in isolation against a
nine-item checklist**, and **the probe watching every line of it refuse against
a scratch project**.

This is the first half. The second half does not exist yet: there is no scratch
project, no R2 bucket and no deployment, so **not one refusal below has ever
been observed happening**. `tool/photo_pipe_probe.dart` is written and carries
the checklist as its S3 section; it is unrun for the same reason.

Read that sentence before reading the verdicts. "Verified" below never means
"observed in production"; it means one of three specific, weaker things, and
each verdict says which:

| Evidence | What it is | What it cannot reach |
| --- | --- | --- |
| **offline** | `handler_test.ts` under `deno test` — the real request/response boundary, with the database and the signer stubbed. | Whether the queries in `index.ts` answer what the handler asked. |
| **local SQL** | `supabase/tests/rls_probe.py` against a throwaway Postgres 17, driven the way PostgREST drives it. | GoTrue, R2, the edge runtime. |
| **by reading** | A property of the source that is decidable by looking, and mechanically re-checkable. | Anything that depends on how another system behaves. |
| **unobserved** | Nothing in this repository can answer it. It is in the probe. | — |

---

## 1. A non-member asking for a real photo id is refused, and cannot tell that from nonexistent

**Shape verified offline; the refusal itself unobserved.**

The handler refuses any id whose row does not come back, and never asks why it
did not: no row, wrong trip, not a member and no such photograph enter the same
branch. `handler_test.ts` (*"nonexistent, unreadable and malformed are one
answer"*) asserts the three responses are the same status, the same three keys,
and the same empty `urls`, and a separate test asserts the body contains none
of the words that would explain a refusal.

What is **not** verified is the part that does the refusing. The handler is
handed the rows a non-member may read; that a non-member may read none of them
is row-level security's answer, and no RLS refusal has ever been observed on a
hosted project (`supabase/README.md`). `rls_probe.py` observes it against a
throwaway Postgres, which is as close as anything here gets.

One honest caveat the checklist does not ask about. The responses are
identical, but the *timings* are not: an id with no readable row costs one
database round trip, while an id whose row is readable and whose day is shut
costs two. That distinguishes "exists, and you are on its trip" from "does not
exist" — but only for a caller who is already a member of the trip they named,
and a member can already see the day's shape and its rows. It tells them
nothing they do not have. The pair §7.3.1 actually names — non-member versus
nonexistent — takes the identical path and is not separable this way.

## 2. A member asking for another trip's photo id is refused

**Shape verified offline; the refusal itself unobserved.** This is *the*
cross-trip leak, and the reason the whole file is shaped the way it is: R2 keys
are derivable from ids that flow through sync, so a function that signed a key
it was handed would hand over every trip at once.

Two independent barriers, and the second is the real one:

1. The lookup is narrowed to the declared trip (`eq(trip_id)`), so naming trip
   A and a photo id from trip B returns nothing.
2. The lookup runs **as the caller**, so RLS returns nothing for a trip the
   caller is not on — whichever trip they name.

`handler_test.ts` covers both directions (*"a photograph in another trip is
refused, not signed"*, *"declaring the other trip does not help"*). The second
barrier is again RLS, and again unobserved outside the local probe.

## 3. A shut day is refused per-id while the same batch's open-day ids succeed

**Verified offline, and the SQL it depends on is verified locally. The wiring
between them is unobserved.**

This is the best-covered item on the list, because it splits cleanly:

- *That the gate sits inside the per-id loop*: offline. `handler_test.ts`
  asserts a two-id batch comes back half signed and half refused, that the gate
  is called before anything is signed, and that a gate which cannot answer
  fails shut.
- *That `day_page_is_open` returns the right answer*: local SQL. `rls_probe.py`
  drives it against a real Postgres — a walked day open to a joiner who never
  contributed, today's day shut until you contribute and open forever after, a
  future day shut, an undated day walked.

What remains is the RPC call in `index.ts` — that `day_page_is_open` is
actually reached, with those three arguments, over PostgREST. Unobserved.

## 4. Caller-supplied trip/day fields are ignored, and only the row's own key is signed

**Verified offline — and see the finding below, which is about the stored key
rather than about this function.**

Three tests: the gate is asked about the row's trip and day rather than the
request's; a body carrying `dayNumber`, `r2ObjectKey` and `userId` changes
nothing (the shut day stays shut, the caller stays the caller, nothing is
signed); and the string handed to the signer is byte-for-byte the row's own
`r2_object_key`. The handler's `DownloadPhotoRow` has exactly four fields, and
they are the whole of what any decision is made from.

**The finding.** "Only the row's own stored key is signed" is only as strong as
what may be stored. `photos_insert_trip_member` (`0006`) places **no constraint
on `r2_object_key`**: a member may insert a row for their own trip claiming any
key that is not already taken. `unique` stops them claiming a key another
`photos` row holds — so no other photograph can be stolen this way — but a
`day_pages` key lives in a different table under a different unique index, and
nothing stops a `photos` row pointing at one. The download function would then
sign it, correctly, as that row's own key.

It is guess-bounded rather than open: day-page keys are built from ids that
never leave the trip they belong to, so the only composites reachable are ones
the caller could already read. It is still a weaker invariant than the sentence
above reads, and closing it is one line —

```sql
check (r2_object_key like 'trips/' || trip_id || '/photos/' || id || '/%')
```

— which was deliberately **not** added here, because it changes what a
legitimate insert may say and the client outbox being built in parallel would
have to match it exactly. It is a decision, not an oversight, and it is the
captain's to make.

`photos_lock_object_keys` (`0011`) closes the adjacent hole and not this one:
it stops a key being *changed* after the fact, which matters because a key a
caller can PATCH is caller input by another route. It does not constrain the
first claim.

## 5. Nonexistent id, malformed id, oversize batch — refused without error-text leakage

**Verified offline.**

- A malformed id is refused *and never reaches the database*, which is both the
  honest answer and what makes the survivors safe to hand to a PostgREST `in`
  filter.
- An oversize batch is refused **whole, with a 400**, rather than clamped.
  Clamping silently drops ids and a client that cannot tell which ones it lost
  retries the whole batch forever. The 400's body names the bound and no row.
- The cap is counted **before** de-duplication, so repeating an id cannot
  smuggle a large batch past it.
- A repeated id costs one lookup, one gate call and one signature, and appears
  once in the answer.

## 6. An expired URL is rejected by R2

**Unobserved, and not observable anywhere in this repository.**

What is decidable: the TTL constant is 900 seconds (a test pins it, so the
settled fifteen-minute decision cannot drift silently), and `index.ts` does put
`X-Amz-Expires` on the signed URL. Whether R2 honours it is a fact about
Cloudflare. It is check §7.3.6 in the probe, behind `--slow` because it costs a
fifteen-minute wait; the same mechanism on the five-minute upload ticket runs
by default.

Worth stating plainly rather than leaving implied: a presigned GET is a bearer
capability. Anyone holding the URL has the bytes until it lapses, and there is
no way to withdraw one. **The TTL is this system's entire revocation
granularity** — that is the cost of option A, and it was accepted knowingly.

## 7. Access decisions observably route through `may_read_trip_photos`

**Half verified locally; the observable half unobserved.**

`rls_probe.py` asserts that the `photos` SELECT policy's stored `qual` names
`may_read_trip_photos`, and that the function is `security definer`. That is
the structural half, and it is real evidence against a real Postgres: the seat
exists and the policy sits in it.

The behavioural half — delete a membership row, watch the very next batch
refuse — needs the function running. It is in the probe and it is unrun.

The other half of the leaver decision, that a *voluntary* leaver keeps their
access, is testable nowhere yet: nothing in this schema can record a departure
as distinct from a removal. When it can, the change is one function body, which
is the whole reason the seat exists.

## 8. A co-member cannot write another contributor's caption

**Verified locally, and this is the one item on the list that is fully closed
today.**

It is a schema property rather than a property of this function.
`photos_update_contributor` (`0006`) already restricted every UPDATE to the
contributor, so `caption` (`0011`) needed no new policy — but "needed no new
policy" is exactly the kind of claim that should be watched refusing rather
than assumed, so `rls_probe.py` watches it: a co-member's PATCH changes no row,
and the caption still reads what its owner wrote. The 280-character bound is
checked in the same section.

## 9. No service-role key, and rows are read as the caller

**Verified by reading, and mechanically re-checkable.**

`index.ts` reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` and forwards the
caller's own `Authorization` header into the client. It never mentions
`SERVICE_ROLE`, and there is no other route to elevated rights in a Supabase
edge function. The probe's first §7.3 check asserts both halves as a source
check, so it holds even in a run that never reaches a project.

One detail that is easy to get wrong and is not: `callerId()` passes the bearer
token to `auth.getUser(token)` explicitly. The uid must be the *verified*
subject of the token; a uid read out of the request body would be a caller
choosing whose gate to be measured against.

What is unobserved: that PostgREST honours the forwarded header, and therefore
that "as the caller" is true in fact and not only in intent. That is item 1's
gap said a different way, and one deployment closes both.

---

## The tally

| # | Item | Verdict |
| --- | --- | --- |
| 1 | Non-member refused, indistinguishable from nonexistent | shape offline; refusal unobserved |
| 2 | Cross-trip id refused | shape offline; refusal unobserved |
| 3 | Shut day refused inside a mixed batch | offline + local SQL; wiring unobserved |
| 4 | Caller's trip/day/key ignored; only the row's key signed | offline — **with a finding on what may be stored** |
| 5 | Malformed, nonexistent, oversize — refused, no leakage | offline |
| 6 | Expired URL rejected by R2 | unobserved, and unobservable here |
| 7 | Reads route through `may_read_trip_photos` | structure local SQL; behaviour unobserved |
| 8 | Caption is single-owner | **local SQL — closed** |
| 9 | No service-role key; reads as the caller | by reading |

Four of the nine are closed as far as anything in this repository can close
them (3 partially, 4, 5, 8, 9). Four are verified in shape and unobserved in
substance, all four waiting on the same thing: one scratch project where an RLS
refusal can be watched happening. One (6) waits on a bucket.

**The single highest-value next action is not another check. It is a scratch
Supabase project and a scratch R2 bucket**, at which point
`tool/photo_pipe_probe.dart` turns most of this table into observations, and
the transcript goes in the pull request.
