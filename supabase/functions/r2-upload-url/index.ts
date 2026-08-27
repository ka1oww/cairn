// Mints a short-lived, single-object presigned PUT URL for R2.
//
// This function exists ONLY because the R2 secret access key cannot ship
// inside the iOS app binary. Everything else about "does this person get
// to write here" is still enforced by Postgres RLS: this function checks
// trip membership and the trip's close itself (see below) before it will
// mint a URL, and the eventual `photos` row insert is separately checked by
// the photos_insert_trip_member policy. If this function is ever compromised
// or misconfigured, the blast radius is "can upload an object to a
// predictable key that no photo row has claimed yet" -- it cannot read or
// delete anything, it cannot overwrite an original that a row already points
// at, and a stray object with no matching `photos` row is invisible to every
// client, since the app only ever lists photos via the `photos` table.
//
// **This file is the IO half only.** Every decision -- what is refused, in
// what order, with what status -- is in `handler.ts`, which imports nothing
// remote and is tested offline by `handler_test.ts`. Nothing here has ever
// been deployed, so that test is the only thing standing behind any of it;
// keep the decisions there and the clients here. `supabase functions deploy`
// bundles a function's local imports, so the split costs the deployment
// nothing.
//
// Deploy: supabase functions deploy r2-upload-url
// Secrets (set via `supabase secrets set`, never committed):
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME
// (SUPABASE_URL and SUPABASE_ANON_KEY are injected automatically by the
// Supabase Edge Functions runtime. The anon key, not the service role one:
// this function reads Postgres *as the caller*, which is what makes RLS the
// single source of truth for "is this person allowed to write here". The
// service-role key is never used here and must not be.)

import { createClient } from "jsr:@supabase/supabase-js@2";
import { AwsClient } from "npm:aws4fetch@1";

import { createHandler, type UploadDatabase } from "./handler.ts";

function databaseAs(authHeader: string): UploadDatabase {
  // Every query below runs as the calling user, so it reuses the exact same
  // RLS policies the rest of the schema relies on -- no separate
  // authorization logic to keep in sync.
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );

  return {
    async isTripMember(tripId: string): Promise<boolean> {
      // .limit(1) matters: trip_members_select_co_member returns the WHOLE
      // roster to a member and nothing at all to anyone else, so this query is
      // "am I a member" only once it is capped. Without the cap, maybeSingle()
      // throws "multiple rows returned" for every trip with more than one
      // person on it -- i.e. every real trip -- and the throw is
      // indistinguishable here from a refusal, so every member would be told
      // they are not a member.
      const { data, error } = await userClient
        .from("trip_members")
        .select("trip_id")
        .eq("trip_id", tripId)
        .limit(1)
        .maybeSingle();
      return !error && !!data;
    },

    async tripClosesAt(tripId: string): Promise<Date | null> {
      // `trip_closes_at` is `stable` and `security invoker`, so `trips`' own
      // RLS decides whether this caller sees the trip at all; it returns null
      // when they do not (`0005_trip_invites.sql`).
      const { data, error } = await userClient.rpc("trip_closes_at", {
        p_trip_id: tripId,
      });
      if (error || data === null || data === undefined) return null;
      const closesAt = new Date(data as string);
      return Number.isNaN(closesAt.getTime()) ? null : closesAt;
    },

    async photoRowExists(tripId: string, photoId: string): Promise<boolean> {
      // Keyed on (trip, photo) because that pair is exactly what the object
      // key is built from: a row is what claims an original.
      //
      // An error is treated as "it exists", which is the safe direction for
      // this particular question -- a failed lookup must not become a licence
      // to overwrite. It costs a refused upload the client can retry.
      const { data, error } = await userClient
        .from("photos")
        .select("id")
        .eq("trip_id", tripId)
        .eq("id", photoId)
        .limit(1)
        .maybeSingle();
      return error ? true : !!data;
    },
  };
}

async function signPut(request: {
  objectKey: string;
  contentType: string;
  contentLength: number;
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

  // `allHeaders: true` is load-bearing and easy to delete by accident.
  // aws4fetch's default signable set excludes `content-type` and
  // `content-length` (its UNSIGNABLE_HEADERS), so without this flag neither
  // one is in X-Amz-SignedHeaders and the URL constrains only the method and
  // the key: any content type, any number of bytes. With it, R2 verifies both
  // against the signature and refuses a PUT that declares anything else,
  // which is what gives MAX_UPLOAD_BYTES teeth and what makes the content
  // type allowlist a real constraint rather than a note.
  //
  // The cost is that the client must PUT with exactly these two headers --
  // in particular it must send a `content-length` and not chunked
  // transfer-encoding. Nothing has ever run this against R2.
  const signed = await r2.sign(
    new Request(`${endpoint}?X-Amz-Expires=${request.expiresInSeconds}`, {
      method: "PUT",
      headers: {
        "content-type": request.contentType,
        "content-length": String(request.contentLength),
      },
    }),
    { aws: { signQuery: true, allHeaders: true } },
  );
  return signed.url;
}

Deno.serve(createHandler({
  database: databaseAs,
  signPut,
  now: () => new Date(),
}));
