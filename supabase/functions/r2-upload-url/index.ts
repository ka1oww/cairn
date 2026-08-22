// Mints a short-lived, single-object presigned PUT URL for R2.
//
// This function exists ONLY because the R2 secret access key cannot ship
// inside the iOS app binary. Everything else about "does this person get
// to write here" is still enforced by Postgres RLS: this function checks
// trip membership itself (see below) before it will mint a URL, and the
// eventual `photos` row insert is separately checked by the
// photos_insert_trip_member policy. If this function is ever compromised
// or misconfigured, the blast radius is "can upload an object to a
// predictable key" -- it cannot read or delete anything, and a stray
// object with no matching `photos` row is invisible to every client,
// since the app only ever lists photos via the `photos` table.
//
// Deploy: supabase functions deploy r2-upload-url
// Secrets (set via `supabase secrets set`, never committed):
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically
// by the Supabase Edge Functions runtime.)

import { createClient } from "jsr:@supabase/supabase-js@2";
import { AwsClient } from "npm:aws4fetch@1";

interface RequestBody {
  tripId: string;
  photoId: string; // client-generated UUID; becomes the object key and,
  // if the upload succeeds, the primary key of the photos row the client
  // inserts afterwards.
  contentType: string;
}

const ALLOWED_CONTENT_TYPES = new Set(["image/jpeg", "image/heic", "image/png"]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UPLOAD_URL_TTL_SECONDS = 300;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response("missing Authorization header", { status: 401 });
  }

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response("invalid JSON body", { status: 400 });
  }

  const { tripId, photoId, contentType } = body;
  if (!tripId || !UUID_RE.test(tripId) || !photoId || !UUID_RE.test(photoId)) {
    return new Response("tripId and photoId must be UUIDs", { status: 400 });
  }
  if (!ALLOWED_CONTENT_TYPES.has(contentType)) {
    return new Response("unsupported content type", { status: 400 });
  }

  // Check membership as the calling user, so this reuses the exact same
  // RLS policy the rest of the schema relies on -- no separate
  // authorization logic to keep in sync.
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  // .limit(1) matters: trip_members_select_co_member returns the WHOLE roster
  // to a member and nothing at all to anyone else, so this query is "am I a
  // member" only once it is capped. Without the cap, maybeSingle() throws
  // "multiple rows returned" for every trip with more than one person on it --
  // i.e. every real trip -- and the throw is indistinguishable here from a
  // refusal, so every member would be told they are not a member.
  const { data: membership, error: membershipError } = await userClient
    .from("trip_members")
    .select("trip_id")
    .eq("trip_id", tripId)
    .limit(1)
    .maybeSingle();

  if (membershipError || !membership) {
    return new Response("not a member of this trip", { status: 403 });
  }

  const ext = contentType === "image/png" ? "png" : contentType === "image/heic" ? "heic" : "jpg";
  const objectKey = `trips/${tripId}/photos/${photoId}/original.${ext}`;

  const r2 = new AwsClient({
    accessKeyId: Deno.env.get("R2_ACCESS_KEY_ID")!,
    secretAccessKey: Deno.env.get("R2_SECRET_ACCESS_KEY")!,
    service: "s3",
    region: "auto",
  });
  const accountId = Deno.env.get("R2_ACCOUNT_ID")!;
  const bucket = Deno.env.get("R2_BUCKET_NAME")!;
  const endpoint = `https://${accountId}.r2.cloudflarestorage.com/${bucket}/${objectKey}`;

  const signed = await r2.sign(
    new Request(`${endpoint}?X-Amz-Expires=${UPLOAD_URL_TTL_SECONDS}`, {
      method: "PUT",
      headers: { "content-type": contentType },
    }),
    { aws: { signQuery: true } },
  );

  return new Response(
    JSON.stringify({
      uploadUrl: signed.url,
      objectKey,
      expiresInSeconds: UPLOAD_URL_TTL_SECONDS,
    }),
    { headers: { "content-type": "application/json" } },
  );
});
