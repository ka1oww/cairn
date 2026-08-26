// Supabase keepalive worker.
//
// Supabase's free tier auto-pauses a project after about a week with no API
// activity. This Worker makes one authenticated REST call twice a week
// (wrangler.jsonc's cron trigger) so the hosted project never goes quiet
// long enough to be paused. See supabase/README.md's Free-tier limits
// section for why this lives here rather than in GitHub Actions (whose
// scheduled workflows disable themselves after 60 days of repo inactivity)
// or in pg_cron (which is paused along with the rest of a paused project).
//
// A failed run throws, which Cloudflare records as an error on the
// scheduled invocation -- check the Worker's dashboard/logs if the trip
// pool ever looks stale; that is what a paused project looks like from
// here. There is no dead-man's-switch alerting yet: see the ops note in
// supabase/README.md for why, and as a follow-up.

async function ping(env) {
  const url = `${env.SUPABASE_URL}/rest/v1/trips?select=id&limit=1`;
  const response = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`,
    },
  });

  if (!response.ok) {
    throw new Error(
      `keepalive ping failed: HTTP ${response.status} ${await response.text()}`,
    );
  }

  return response.status;
}

export default {
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(ping(env));
  },

  // Manual trigger: `curl https://<worker>.workers.dev/` after deploy, or
  // the dashboard's "Trigger" button, both exercise the same code path.
  async fetch(_request, env) {
    const status = await ping(env);
    return new Response(`keepalive ok: HTTP ${status}\n`);
  },
};
