// Mints short-lived, single-object presigned GET URLs for R2, one batch at a
// time, and only for photographs the caller is actually allowed to see.
//
// This is the read half of the pair `supabase/README.md` describes, and the
// blank that file called *"the highest-severity blank in the backend"*. The
// bucket is private, so every read needs a signature; gating the signature
// rather than the row is what makes the shut gate a gate and not a curtain,
// because the rows of a shut day must stay readable for it to show the day's
// times and names at all.
//
// **The authorisation shape is settled** (captain, 2026-08-28): option A, the
// time-limited signed link. Not the Cloudflare Worker proxy, and not an R2
// binding -- now or later. The consequence is written on
// `DOWNLOAD_URL_TTL_SECONDS` in `handler.ts`: a minted URL cannot be
// withdrawn, so the TTL is the revocation window, and it is short.
//
// **This file is the IO half only.** Every decision -- what is refused, in
// what order, with what status -- is in `handler.ts`, which imports nothing
// remote and is tested offline by `handler_test.ts`. Nothing here has ever
// been deployed, so that test is the only thing standing behind any of it;
// keep the decisions there and the clients here. `supabase functions deploy`
// bundles a function's local imports, so the split costs the deployment
// nothing.
//
// Deploy: supabase functions deploy r2-download-url
// Secrets (set via `supabase secrets set`, never committed):
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME
// (SUPABASE_URL and SUPABASE_ANON_KEY are injected automatically by the
// Supabase Edge Functions runtime. The anon key, not the service role one:
// every read below happens *as the caller*, which is what makes RLS a second
// wall rather than a bypassed one, and what makes `may_read_trip_photos` --
// the seat the leaver rule lands in -- authoritative here without this file
// knowing it exists. The service-role key is never used here and must not
// be: with it, one bug in this file is every trip's photographs.)

import { createClient } from "jsr:@supabase/supabase-js@2";
import { AwsClient } from "npm:aws4fetch@1";

import { createHandler, type DownloadDatabase } from "./handler.ts";

function databaseAs(authHeader: string): DownloadDatabase {
  // Every query below runs as the calling user, so it reuses the exact same
  // RLS policies the rest of the schema relies on -- no separate
  // authorization logic to keep in sync.
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );

  return {
    async callerId(): Promise<string | null> {
      // The token is handed to `getUser` explicitly rather than left to the
      // client's session, because this is the one value in the whole function
      // that must be the *verified* subject of the bearer token: it is what
      // `day_page_is_open` is asked about, and that function is SECURITY
      // DEFINER and answers about whoever it is given. A uid taken from the
      // request body, or from an unverified decode of the JWT, would be a
      // caller choosing whose gate to be checked against.
      const token = authHeader.replace(/^Bearer\s+/i, "");
      const { data, error } = await userClient.auth.getUser(token);
      if (error || !data?.user?.id) return null;
      return data.user.id;
    },

    async readablePhotos(tripId: string, photoIds: string[]) {
      // `eq(trip_id)` narrows; it never widens. RLS has already filtered this
      // table to trips the caller may read photographs of, so the declared
      // trip can only ever remove rows from the answer -- which is the right
      // direction for a field the caller controls. The decision is still made
      // from each row's own columns in `handler.ts`.
      //
      // Every id in `photoIds` has already matched UUID_RE, which is what
      // makes handing them to `in` safe.
      const { data, error } = await userClient
        .from("photos")
        .select("id, trip_id, day_number, r2_object_key")
        .eq("trip_id", tripId)
        .in("id", photoIds);

      // No rows on an error, so a failed read refuses every id rather than
      // signing any. The opposite default -- treating an error as "nothing to
      // check" -- would be a leak the first time PostgREST hiccupped.
      if (error || !data) return [];

      return data.map((row) => ({
        id: row.id as string,
        tripId: row.trip_id as string,
        dayNumber: row.day_number as number,
        r2ObjectKey: row.r2_object_key as string,
      }));
    },

    async dayPageIsOpen(tripId: string, dayNumber: number, userId: string) {
      // The gate, asked of the one copy of it that lives on this side of the
      // seam (`0011_photo_transport.sql`; the phone's copy is
      // `cairn_model.GateState.decide`). It is `stable` and SECURITY DEFINER,
      // and granted to `authenticated`.
      //
      // An error is "shut", which is the safe direction for this particular
      // question and the only one: a gate that opens when the database cannot
      // answer is not a gate.
      const { data, error } = await userClient.rpc("day_page_is_open", {
        p_trip_id: tripId,
        p_day_number: dayNumber,
        p_user_id: userId,
      });
      if (error) return false;
      return data === true;
    },
  };
}

async function signGet(request: {
  objectKey: string;
  expiresInSeconds: number;
}): Promise<string> {
  const r2 = new AwsClient({
    accessKeyId: Deno.env.get("R2_ACCESS_KEY_ID")!,
    secretAccessKey: Deno.env.get("R2_SECRET_ACCESS_KEY")!,
    service: "s3",
    region: "auto",
  });
  const accountId = Deno.env.get("R2_ACCOUNT_ID")!;
  const bucket = Deno.env.get("R2_BUCKET_NAME")!;
  const endpoint =
    `https://${accountId}.r2.cloudflarestorage.com/${bucket}/${request.objectKey}`;

  // No `allHeaders: true` here, and the asymmetry with `r2-upload-url` is
  // deliberate rather than an omission. The PUT signs `content-type` and
  // `content-length` because those are *bounds on what the client may do*;
  // a GET declares nothing, carries no headers, and is already scoped to one
  // method, one key and one expiry by the query signature itself. Signing
  // headers a GET does not send would only make the URL fail.
  //
  // The client must therefore send the URL bare: no `apikey`, no
  // `Authorization`. An S3-dialect service refuses a request that carries
  // both a query signature and an auth header, which is why the fetch cannot
  // go through the adapter's ordinary `_send`.
  const signed = await r2.sign(
    new Request(`${endpoint}?X-Amz-Expires=${request.expiresInSeconds}`, {
      method: "GET",
    }),
    { aws: { signQuery: true } },
  );
  return signed.url;
}

Deno.serve(createHandler({
  database: databaseAs,
  signGet,
}));
