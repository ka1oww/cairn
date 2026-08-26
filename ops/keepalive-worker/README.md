# cairn-keepalive

A Cloudflare Worker that pings the hosted Supabase project's PostgREST
endpoint twice a week so the free-tier project is never idle long enough to
auto-pause. See `supabase/README.md`'s Free-tier limits section for why this
exists and why it lives here rather than in GitHub Actions or `pg_cron`.

## Deploy

```sh
cd ops/keepalive-worker
wrangler deploy
```

Requires `wrangler` authenticated against the Cloudflare account that should
own the Worker (`wrangler whoami` to check).

## Verify

```sh
curl https://cairn-keepalive.embereducation.workers.dev/
```

Triggers the same code path as the cron (`fetch` and `scheduled` both call
the same `ping`). A `keepalive ok: HTTP 200` response means the hosted
project answered.

## Config

`SUPABASE_URL` and `SUPABASE_ANON_KEY` in `wrangler.jsonc` must match
`lib/storage/remote/shared_facts.dart`'s `hostedUrl` / `hostedAnonKey`
exactly — see the comment above them in `wrangler.jsonc`. Both are
public-safe (see that Dart file's header); never add the service-role key or
a database password here.
