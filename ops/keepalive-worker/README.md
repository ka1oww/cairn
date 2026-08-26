# cairn-keepalive

A Cloudflare Worker that pings the hosted Supabase project's PostgREST
endpoint three times a week so the free-tier project is never idle long
enough to auto-pause. See `supabase/README.md`'s Free-tier limits section for why this
exists and why it lives here rather than in GitHub Actions or `pg_cron`.

## Deploy

```sh
cd ops/keepalive-worker
wrangler deploy
```

Requires `wrangler` authenticated against the Cloudflare account that should
own the Worker (`wrangler whoami` to check).

## Verify

The Worker has no HTTP endpoint on purpose — a public URL that proxies into
the hosted project can be driven by anyone, and exhausting the free-tier
request quota that way would stop the scheduled run too. Trigger a run one
of these two ways instead:

```sh
cd ops/keepalive-worker
wrangler dev --test-scheduled
# then, in another shell:
# the cron must be spelled exactly as wrangler.jsonc has it:
curl 'http://localhost:8787/__scheduled?cron=0+1+*+*+1,3,5'
```

or, against the deployed Worker, use the **Trigger** button on its
Cloudflare dashboard page (Workers → `cairn-keepalive` → Settings → Trigger
Events → Cron Triggers). Either way, a run that logs no error means the
hosted project answered; a thrown `keepalive ping failed: HTTP …` is
recorded as a failed invocation in the Worker's logs.

## Config

`SUPABASE_URL` and `SUPABASE_ANON_KEY` in `wrangler.jsonc` must match
`lib/storage/remote/shared_facts.dart`'s `hostedUrl` / `hostedAnonKey`
exactly — see the comment above them in `wrangler.jsonc`. Both are
public-safe (see that Dart file's header); never add the service-role key or
a database password here.
