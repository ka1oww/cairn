// Every decision `r2-upload-url` makes, with nothing that touches the network.
//
// Why this file exists at all: an edge function cannot be tested without
// deploying it, and nothing in this repository has ever been deployed. So the
// function is split at the only seam that helps -- the *decisions* live here
// behind three injected dependencies, and `index.ts` is the twenty lines that
// build the real ones out of `supabase-js`, `aws4fetch` and `Deno.env`. That
// makes `handler_test.ts` a real test of the refusals rather than a mock of a
// client library: it can drive the whole request/response boundary offline,
// which is why CI runs it with `--no-remote` (see .github/workflows/ci.yml).
// **Nothing here may grow an import of anything remote** -- that flag is what
// keeps this file honest, and an import would fail CI rather than slow it.
//
// What this file does NOT cover, said plainly: the shape of the PostgREST
// queries in `index.ts` (whether `.limit(1).maybeSingle()` really answers "am
// I a member"), and whether R2 honours a signed `content-length`. Both need a
// deployment, and there has never been one.

/// The three content types the pool accepts. A phone camera writes HEIC and
/// `package:camera` writes JPEG; PNG is here for a screenshot dropped in by
/// the import sweep.
export const ALLOWED_CONTENT_TYPES = new Set([
  "image/jpeg",
  "image/heic",
  "image/png",
]);

/// The lower-case hyphenated spelling `photos.id` and `trips.id` are, because
/// both columns are Postgres `uuid` (`0006_photos.sql`, `0003_trips.sql`).
///
/// The phone mints ids in exactly this form on both sides of the seam --
/// `TripId.mint` (`packages/cairn_model/lib/src/ids.dart`) and `PhotoId.mint`
/// beside it. `test/photo_id_format_test.dart` reads this very line out of
/// this file and applies it to a freshly minted photo id, because the two
/// halves are one rule written twice and the only way to notice one of them
/// drifting is to compare them.
export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const UPLOAD_URL_TTL_SECONDS = 300;

/// The largest object this function will ever sign for: 64 MiB.
///
/// Storage is the only line in this backend that ever produces an invoice
/// (`docs/storage-and-cost.md`), and a presigned PUT that names no size lets
/// a member park an object of any size at all. The number is chosen from this
/// repository's own measured corpus rather than from the air: the JPEG median
/// is 3.08 MB, the p99 is 5.16 MB and the largest photograph measured was
/// 7.00 MB (`docs/storage-and-cost.md`). 64 MiB is nine times that largest
/// one and twenty times the median -- generous enough that no photograph a
/// phone camera writes can reach it, including a full-resolution PNG, which
/// is the fattest of the three types above.
///
/// It is a sanity bound and not a quota, and saying otherwise would be
/// dishonest: a member who wants to fill the bucket does it with ordinary
/// photographs, and how many of those a trip may hold is a question this
/// function cannot answer.
export const MAX_UPLOAD_BYTES = 64 * 1024 * 1024;

export interface RequestBody {
  tripId: string;
  /// Client-minted uuid. It becomes the object key and, once the bytes have
  /// landed, the primary key of the `photos` row the client inserts.
  photoId: string;
  contentType: string;
  /// Exactly how many bytes the client is about to PUT. It is signed into the
  /// URL, so a PUT of any other length is refused by R2 rather than by us.
  contentLength: number;
}

/// The three questions this function asks Postgres, as the calling user.
///
/// An interface rather than a `SupabaseClient` because the answers are what
/// the decisions turn on; `index.ts` is where the queries live.
export interface UploadDatabase {
  /// Whether the caller is on this trip, decided by the same RLS policy every
  /// other read in the schema goes through.
  isTripMember(tripId: string): Promise<boolean>;

  /// When this trip stops accepting new contributions, or null for a trip the
  /// caller cannot see -- which is not the same as "never closes" and must
  /// never be read as one (`0005_trip_invites.sql`).
  tripClosesAt(tripId: string): Promise<Date | null>;

  /// Whether a `photos` row already exists in this trip with this id.
  photoRowExists(tripId: string, photoId: string): Promise<boolean>;
}

export interface SignPutRequest {
  objectKey: string;
  contentType: string;
  contentLength: number;
  expiresInSeconds: number;
}

export interface UploadDeps {
  database(authHeader: string): UploadDatabase;
  signPut(request: SignPutRequest): Promise<string>;
  /// Injected so a test can stand on either side of a trip's close.
  now(): Date;
}

/// `original.<ext>`, and only that. The pool stores the frame the camera
/// wrote, untouched (`docs/decisions/2026-08-22-grill-round-one.md` §3) --
/// this function signs a PUT and transforms nothing, and it must never be
/// taught to sign a downsized or re-encoded object under this key. A derived
/// variant, if one is ever generated, gets `thumbnail.<ext>` beside it.
export function objectKeyFor(
  tripId: string,
  photoId: string,
  contentType: string,
): string {
  const ext = contentType === "image/png"
    ? "png"
    : contentType === "image/heic"
    ? "heic"
    : "jpg";
  return `trips/${tripId}/photos/${photoId}/original.${ext}`;
}

function refuse(status: number, message: string): Response {
  return new Response(message, { status });
}

export function createHandler(
  deps: UploadDeps,
): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") {
      return refuse(405, "method not allowed");
    }

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return refuse(401, "missing Authorization header");
    }

    let body: RequestBody;
    try {
      body = await req.json();
    } catch {
      return refuse(400, "invalid JSON body");
    }

    const { tripId, photoId, contentType, contentLength } = body;
    if (!tripId || !UUID_RE.test(tripId) || !photoId || !UUID_RE.test(photoId)) {
      return refuse(400, "tripId and photoId must be UUIDs");
    }
    if (!ALLOWED_CONTENT_TYPES.has(contentType)) {
      return refuse(400, "unsupported content type");
    }
    if (
      typeof contentLength !== "number" ||
      !Number.isInteger(contentLength) ||
      contentLength <= 0
    ) {
      return refuse(400, "contentLength must be a positive whole number");
    }
    if (contentLength > MAX_UPLOAD_BYTES) {
      return refuse(
        400,
        `contentLength must be at most ${MAX_UPLOAD_BYTES} bytes`,
      );
    }

    const db = deps.database(authHeader);

    // Membership first, and not only because it is the cheapest refusal: the
    // two questions below are about this trip's photographs, and a stranger
    // learns nothing from either.
    if (!await db.isTripMember(tripId)) {
      return refuse(403, "not a member of this trip");
    }

    // The trip's ending, on the write path. `photos_insert_trip_member`
    // (`0006_photos.sql`) already requires `now() < trip_closes_at(...)`, so
    // without this check a phone can obtain a URL and land bytes for a trip
    // that can never accept the matching row -- a guaranteed orphan, in the
    // one class nothing sweeps up (`supabase/README.md`).
    //
    // The comparison happens in this function's clock rather than Postgres's,
    // which is a second clock and worth naming: both are server clocks, and
    // the authority is still the insert policy. This check exists to stop
    // bytes landing that can never acquire a row, not to be the ending.
    //
    // A null closes-at is a trip this caller cannot see, and refusing on it
    // is right twice over -- a caller who cannot see the trip is not a member
    // of it either, so this can only fire on a trip deleted between the two
    // queries.
    const closesAt = await db.tripClosesAt(tripId);
    if (closesAt === null || deps.now() >= closesAt) {
      return refuse(403, "this trip is closed");
    }

    // The overwrite hole. Without this, member B can ask for an upload URL
    // for member A's `photoId` -- every member can read every photo row in
    // the trip, `id` included (`photos_select_trip_member`, `0006`) -- and
    // PUT arbitrary bytes over A's original. A's row is untouched, so the
    // swap is invisible to the index and to every RLS policy:
    // `photos_update_contributor` protects the row and nothing protected the
    // object.
    //
    // The refusal is flat: a claimed id is refused to *everyone*, its own
    // contributor included. An original is immutable, which is the whole
    // reason a client may cache its bytes forever (`0006_photos.sql` on
    // `r2_object_key`), and letting the contributor re-upload would make a
    // cached copy silently stale. It costs nothing that is needed, because
    // the ordering is bytes-first-row-second (`docs/architecture.md`): a
    // retry of an upload that never landed happens while no row exists and is
    // still signed. What a row means is "these bytes are the record now".
    //
    // Row-level security refuses by filtering to zero rows rather than
    // raising, so "no row came back" is only "no such photo" once the caller
    // is known to be a member -- which is why this query is below that check
    // and not above it.
    if (await db.photoRowExists(tripId, photoId)) {
      return refuse(409, "a photo with this id already exists");
    }

    const objectKey = objectKeyFor(tripId, photoId, contentType);
    const uploadUrl = await deps.signPut({
      objectKey,
      contentType,
      contentLength,
      expiresInSeconds: UPLOAD_URL_TTL_SECONDS,
    });

    // The client must PUT with exactly the `content-type` and
    // `content-length` it declared here: both are signed into the URL, so R2
    // refuses anything else. They are not echoed back because the client is
    // the one that named them.
    return new Response(
      JSON.stringify({
        uploadUrl,
        objectKey,
        expiresInSeconds: UPLOAD_URL_TTL_SECONDS,
      }),
      { headers: { "content-type": "application/json" } },
    );
  };
}
