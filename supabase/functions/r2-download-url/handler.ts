// Every decision `r2-download-url` makes, with nothing that touches the
// network.
//
// This is the single worst file in the app to get wrong -- the map says so
// outright (`docs/architecture.md`: *"a version that skips the check is the
// single worst potential leak in the app"*), and the reason is that the R2
// keys are derivable from ids that flow through sync (`supabase/README.md`),
// so a function that signs any key for any authenticated caller hands over
// every trip's photographs at once. It is therefore split exactly as
// `r2-upload-url` is, and for a stronger version of the same reason: the
// decisions live here behind two injected dependencies and this file
// **imports nothing remote**, so `handler_test.ts` can watch every refusal
// refuse without a deployment. CI pins the split with
// `deno check --no-remote handler.ts`.
//
// What this file does NOT cover, said plainly: whether the PostgREST queries
// in `index.ts` really read as the caller, and whether R2 honours
// `X-Amz-Expires`. Both need a deployment, and there has never been one.
// `tool/photo_pipe_probe.dart` is what watches those, against a scratch
// project, and it has not been run either.
//
// ---------------------------------------------------------------------------
// The shape, and why it is this shape
// ---------------------------------------------------------------------------
//
// **Batched, with per-id verdicts.** One invocation asks about many
// photographs and answers about each one separately: an open day's ids come
// back signed and a shut day's come back refused, in the same response. That
// is what lets the phone skip evaluating the gate before it asks (the rule
// exists twice by decision, and a third copy on the read path is the thing to
// refuse in review), and it keeps invocation counts flat against a free tier.
//
// **A refusal carries no reason.** Not an omission -- the whole point. A
// non-member asking about a real photograph, a member asking about a
// photograph in a trip they are not on, a malformed id and an id nobody ever
// minted must all be answered identically, or the answer is an oracle that
// maps the corpus. There is one word, `refused`, and it never says which of
// those it was.
//
// **The row decides, not the caller.** The caller names a trip and some ids;
// nothing else they say is consulted. Each row is looked up server-side, the
// gate is asked about *the row's own* trip and day number, and the URL signs
// *the row's own* stored object key. A caller who could name the day would be
// choosing their own gate; a caller who could name the key would be choosing
// their own photograph.
//
// **Authorisation is inherited, not re-decided.** The rows are read as the
// caller, so RLS answers first -- and after `0011` the photos SELECT policy
// goes through `may_read_trip_photos`, which is where the leaver split lands
// when leave and remove are built. This function will need no edit for it.

/// The lower-case hyphenated spelling `photos.id` and `trips.id` are, because
/// both columns are Postgres `uuid`. The same constant as `r2-upload-url`'s,
/// deliberately duplicated rather than shared: an edge function is deployed
/// as its own directory, and a cross-function import would make one
/// function's deployment depend on another's file.
///
/// An id that does not match never reaches the database. That is a refusal,
/// but it is also the reason the ids can be put into a PostgREST `in` filter
/// at all.
export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/// Fifteen minutes, and the number is a decision rather than a default
/// (captain, 2026-08-28: option A, the time-limited signed link -- no Worker
/// proxy, no R2 binding, now or later).
///
/// A presigned GET is a bearer token for exactly as long as it lives, and
/// the TTL *is* this system's revocation granularity: there is no way to
/// withdraw a minted URL short of proxying every byte, which was the
/// alternative and was not chosen. The leaver decision is what prices it --
/// a voluntary leaver keeps their access, so nothing needs revoking when
/// somebody walks away, and the only event that needs prompt revocation is a
/// *removal*. Fifteen minutes is how long a removed person can still read,
/// and it is at the short end of the 1-6 hours the survey sketched, because
/// a phone re-asking for a fresh URL costs one batched call against an
/// already-batched loop.
///
/// R2 permits 1 second to 7 days; nothing here should ever approach the top
/// of that.
export const DOWNLOAD_URL_TTL_SECONDS = 15 * 60;

/// The most photographs one invocation will answer about.
///
/// The drain that consumes this fetches 24 objects a pass (roughly 72 MB at
/// the measured 3 MB median, `docs/storage-and-cost.md`), so this is not a
/// tuning knob for the client -- it is a bound on the work one call can ask
/// the database and the signer to do. An oversize batch is refused outright
/// rather than clamped: clamping silently drops ids, and a client that cannot
/// tell which ones it lost retries the whole batch forever.
export const MAX_BATCH = 64;

export interface RequestBody {
  tripId: string;
  photoIds: string[];
}

/// One row of `photos`, as the caller is allowed to see it.
///
/// These four fields are the whole of what this function is permitted to make
/// a decision from. They come off the row, never off the request.
export interface DownloadPhotoRow {
  id: string;
  tripId: string;
  dayNumber: number;
  r2ObjectKey: string;
}

/// The two questions this function asks Postgres, plus who is asking.
///
/// An interface rather than a `SupabaseClient` because the answers are what
/// the decisions turn on; `index.ts` is where the queries live.
export interface DownloadDatabase {
  /// The caller's user id, resolved from the bearer token by the identity
  /// service that issued it -- never from anything in the request body.
  ///
  /// It is needed because `day_page_is_open` takes a user id, and a user id
  /// this function did not verify would be a gate this function does not
  /// enforce. Null means the token did not resolve, which is a 401 and not a
  /// per-id refusal: with no caller there is no question to answer.
  callerId(): Promise<string | null>;

  /// The rows among [photoIds] that this caller may actually read, in this
  /// trip, **read as the caller** so that row-level security decides.
  ///
  /// After `0011` that policy runs through `may_read_trip_photos`, so this
  /// call is also how the function inherits the leaver rule instead of
  /// keeping its own copy of it. An id whose row does not come back is
  /// refused, and the four reasons it might not (no such photo; not in this
  /// trip; not a member; not permitted to read this trip's photographs) are
  /// deliberately indistinguishable from here.
  ///
  /// An implementation that cannot answer must return no rows. A failed read
  /// is a refusal, never a signature.
  readablePhotos(
    tripId: string,
    photoIds: string[],
  ): Promise<DownloadPhotoRow[]>;

  /// The gate: `day_page_is_open(trip_id, day_number, user_id)` in SQL, which
  /// is the one server-side copy of a rule that exists exactly twice
  /// (`docs/architecture.md`, invariant 2). It is asked, never re-implemented
  /// here -- a third copy written in TypeScript is the thing to refuse in
  /// review.
  ///
  /// An implementation that cannot answer must return false. The gate fails
  /// shut.
  dayPageIsOpen(
    tripId: string,
    dayNumber: number,
    userId: string,
  ): Promise<boolean>;
}

export interface SignGetRequest {
  objectKey: string;
  expiresInSeconds: number;
}

export interface DownloadDeps {
  database(authHeader: string): DownloadDatabase;
  signGet(request: SignGetRequest): Promise<string>;
}

function refuse(status: number, message: string): Response {
  return new Response(message, { status });
}

export function createHandler(
  deps: DownloadDeps,
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

    const { tripId, photoIds } = body;
    if (!tripId || typeof tripId !== "string" || !UUID_RE.test(tripId)) {
      return refuse(400, "tripId must be a UUID");
    }
    if (!Array.isArray(photoIds) || photoIds.length === 0) {
      return refuse(400, "photoIds must be a non-empty array");
    }
    // Counted before de-duplication, so a caller cannot smuggle a large batch
    // past the bound by repeating an id.
    if (photoIds.length > MAX_BATCH) {
      return refuse(400, `photoIds must name at most ${MAX_BATCH} photos`);
    }

    // De-duplicated so that one id asked for twice costs one lookup and one
    // signature, and appears once in the answer. Insertion order is kept, so
    // the response is a function of the request and not of a hash seed.
    const asked: string[] = [];
    for (const id of photoIds) {
      if (typeof id === "string" && !asked.includes(id)) asked.push(id);
    }
    if (asked.length === 0) {
      return refuse(400, "photoIds must name at least one photo");
    }

    const db = deps.database(authHeader);

    const callerId = await db.callerId();
    if (!callerId) {
      return refuse(401, "the Authorization header did not resolve to a user");
    }

    // A malformed id is refused here and never reaches the database, which is
    // both the honest answer (no such photograph) and the reason the survivors
    // can be handed to a PostgREST `in` filter at all.
    const wellFormed = asked.filter((id) => UUID_RE.test(id));

    const rows = wellFormed.length === 0
      ? []
      : await db.readablePhotos(tripId, wellFormed);
    const byId = new Map<string, DownloadPhotoRow>();
    for (const row of rows) {
      // A row for an id nobody asked about is not a thing a correct
      // implementation returns; ignoring it costs nothing and means a widened
      // query can never widen the answer.
      if (asked.includes(row.id)) byId.set(row.id, row);
    }

    const urls: Record<string, string> = {};
    const refused: string[] = [];

    // The gate is a pure function of (trip, day, caller) for the length of one
    // request, and a batch of a day's photographs asks the same question of it
    // twenty times. Asked once per distinct day instead -- which changes no
    // answer, only the number of round trips.
    const gate = new Map<string, boolean>();

    for (const id of asked) {
      const row = byId.get(id);
      if (!row) {
        refused.push(id);
        continue;
      }

      // The row's own trip and day, never the caller's. The lookup was already
      // narrowed to the declared trip -- narrowing can only ever refuse more --
      // but the decision is made from the row so that it stays correct if that
      // narrowing is ever loosened.
      const key = `${row.tripId}:${row.dayNumber}`;
      let open = gate.get(key);
      if (open === undefined) {
        open = await db.dayPageIsOpen(row.tripId, row.dayNumber, callerId);
        gate.set(key, open);
      }
      if (!open) {
        refused.push(id);
        continue;
      }

      // Only now, and only the row's own key. Nothing derived from the request
      // reaches the signer.
      urls[id] = await deps.signGet({
        objectKey: row.r2ObjectKey,
        expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS,
      });
    }

    return new Response(
      JSON.stringify({
        urls,
        refused,
        expiresInSeconds: DOWNLOAD_URL_TTL_SECONDS,
      }),
      { headers: { "content-type": "application/json" } },
    );
  };
}
