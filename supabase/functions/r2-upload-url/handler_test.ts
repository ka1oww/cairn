// What `r2-upload-url` refuses, driven at the request/response boundary.
//
// Run it:
//
//   deno test supabase/functions/r2-upload-url/handler_test.ts
//
// These decisions can be exercised at all only because `handler.ts` imports
// nothing off the network -- nothing in this repository has ever been
// deployed, and there is no other way to run an edge function's refusals. CI
// pins that separately with `deno check --no-remote handler.ts`, which fails
// the moment someone teaches the handler to import `supabase-js` directly.
// The standard library is this file's one dependency; the handler's is none.
//
// What is NOT covered here, and cannot be: whether the PostgREST queries in
// `index.ts` really answer the three questions `UploadDatabase` asks, and
// whether R2 honours a signed `content-length`. Both need the thing that does
// not exist yet.

import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

import {
  createHandler,
  MAX_UPLOAD_BYTES,
  objectKeyFor,
  UPLOAD_URL_TTL_SECONDS,
  type UploadDatabase,
} from "./handler.ts";

const TRIP = "11111111-1111-4111-8111-111111111111";
const PHOTO = "22222222-2222-4222-8222-222222222222";
const NOW = new Date("2027-06-14T09:00:00Z");
const OPEN = new Date("2027-06-20T00:00:00Z");
const CLOSED = new Date("2027-06-01T00:00:00Z");

interface Recorded {
  signed: { objectKey: string; contentType: string; contentLength: number }[];
  asked: string[];
}

function harness(
  answers: {
    isTripMember?: boolean;
    closesAt?: Date | null;
    photoRowExists?: boolean;
    now?: Date;
  } = {},
) {
  const recorded: Recorded = { signed: [], asked: [] };
  const database = (_authHeader: string): UploadDatabase => ({
    isTripMember(_tripId) {
      recorded.asked.push("isTripMember");
      return Promise.resolve(answers.isTripMember ?? true);
    },
    tripClosesAt(_tripId) {
      recorded.asked.push("tripClosesAt");
      return Promise.resolve(
        answers.closesAt === undefined ? OPEN : answers.closesAt,
      );
    },
    photoRowExists(_tripId, _photoId) {
      recorded.asked.push("photoRowExists");
      return Promise.resolve(answers.photoRowExists ?? false);
    },
  });
  const handler = createHandler({
    database,
    signPut(request) {
      recorded.signed.push({
        objectKey: request.objectKey,
        contentType: request.contentType,
        contentLength: request.contentLength,
      });
      return Promise.resolve(`https://r2.test/${request.objectKey}?signed`);
    },
    now: () => answers.now ?? NOW,
  });
  return { handler, recorded };
}

function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request("https://fn.test/r2-upload-url", {
    method: "POST",
    headers: { Authorization: "Bearer jwt", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function wellFormed(overrides: Record<string, unknown> = {}) {
  return {
    tripId: TRIP,
    photoId: PHOTO,
    contentType: "image/jpeg",
    contentLength: 3_080_000, // the measured JPEG median, docs/storage-and-cost.md
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// The shape of the request
// ---------------------------------------------------------------------------

Deno.test("a GET is not a way in", async () => {
  const { handler } = harness();
  const res = await handler(
    new Request("https://fn.test/r2-upload-url", { method: "GET" }),
  );
  assertEquals(res.status, 405);
});

Deno.test("no Authorization header is refused before anything is read", async () => {
  const { handler, recorded } = harness();
  const res = await handler(
    new Request("https://fn.test/r2-upload-url", {
      method: "POST",
      body: JSON.stringify(wellFormed()),
    }),
  );
  assertEquals(res.status, 401);
  assertEquals(recorded.asked, []);
});

Deno.test("a body that is not JSON is refused", async () => {
  const { handler } = harness();
  assertEquals((await handler(post("not json at all"))).status, 400);
});

Deno.test("an unsupported content type is refused", async () => {
  const { handler, recorded } = harness();
  const res = await handler(post(wellFormed({ contentType: "image/gif" })));
  assertEquals(res.status, 400);
  assertEquals(recorded.signed, []);
});

// ---------------------------------------------------------------------------
// Finding 3: the two halves of the seam spell an id the same way
// ---------------------------------------------------------------------------

Deno.test("an undashed 32-character id is refused, which is what the phone used to mint", async () => {
  const { handler } = harness();
  const res = await handler(
    post(wellFormed({ photoId: "2222222222224222822222222222222a" })),
  );
  assertEquals(res.status, 400);
});

Deno.test("the hyphenated spelling of a minted uuid is accepted", async () => {
  const { handler } = harness();
  assertEquals((await handler(post(wellFormed()))).status, 200);
});

// ---------------------------------------------------------------------------
// Finding 6: a signed upload is bounded
// ---------------------------------------------------------------------------

Deno.test("an upload with no declared size is refused", async () => {
  const { handler, recorded } = harness();
  const body = wellFormed();
  delete (body as Record<string, unknown>).contentLength;
  const res = await handler(post(body));
  assertEquals(res.status, 400);
  assertStringIncludes(await res.text(), "contentLength");
  assertEquals(recorded.signed, []);
});

Deno.test("a zero, negative or fractional size is refused", async () => {
  for (const contentLength of [0, -1, 1.5, "3080000"]) {
    const { handler, recorded } = harness();
    const res = await handler(post(wellFormed({ contentLength })));
    assertEquals(res.status, 400, `contentLength ${contentLength}`);
    assertEquals(recorded.signed, []);
  }
});

Deno.test("a size past the ceiling is refused and nothing is signed", async () => {
  const { handler, recorded } = harness();
  const res = await handler(
    post(wellFormed({ contentLength: MAX_UPLOAD_BYTES + 1 })),
  );
  assertEquals(res.status, 400);
  assertEquals(recorded.signed, []);
});

Deno.test("a size exactly at the ceiling is signed", async () => {
  const { handler, recorded } = harness();
  const res = await handler(
    post(wellFormed({ contentLength: MAX_UPLOAD_BYTES })),
  );
  assertEquals(res.status, 200);
  assertEquals(recorded.signed.length, 1);
  assertEquals(recorded.signed[0].contentLength, MAX_UPLOAD_BYTES);
});

Deno.test("the ceiling clears the largest photograph this repo has measured", () => {
  // docs/storage-and-cost.md: JPEG median 3.08 MB, p99 5.16 MB, max 7.00 MB.
  assert(
    MAX_UPLOAD_BYTES > 7_000_000 * 8,
    "64 MiB is real headroom, not a tight fit",
  );
});

Deno.test("the declared size and type reach the signer, because that is what binds them", async () => {
  const { handler, recorded } = harness();
  await handler(
    post(wellFormed({ contentType: "image/heic", contentLength: 2_200_000 })),
  );
  assertEquals(recorded.signed, [{
    objectKey: `trips/${TRIP}/photos/${PHOTO}/original.heic`,
    contentType: "image/heic",
    contentLength: 2_200_000,
  }]);
});

// ---------------------------------------------------------------------------
// Membership
// ---------------------------------------------------------------------------

Deno.test("a non-member gets no URL and is asked nothing further", async () => {
  const { handler, recorded } = harness({ isTripMember: false });
  const res = await handler(post(wellFormed()));
  assertEquals(res.status, 403);
  assertEquals(recorded.signed, []);
  // A stranger must not learn whether this trip holds a photo with this id.
  assertEquals(recorded.asked, ["isTripMember"]);
});

// ---------------------------------------------------------------------------
// Finding 2: the trip's close is on this write path too
// ---------------------------------------------------------------------------

Deno.test("a closed trip gets no URL, so no byte can land that no row could claim", async () => {
  const { handler, recorded } = harness({ closesAt: CLOSED });
  const res = await handler(post(wellFormed()));
  assertEquals(res.status, 403);
  assertStringIncludes(await res.text(), "closed");
  assertEquals(recorded.signed, []);
});

Deno.test("the grace is open right up to the closing instant and shut on it", async () => {
  const justBefore = harness({
    closesAt: OPEN,
    now: new Date(OPEN.getTime() - 1),
  });
  assertEquals((await justBefore.handler(post(wellFormed()))).status, 200);

  const exactly = harness({ closesAt: OPEN, now: OPEN });
  assertEquals((await exactly.handler(post(wellFormed()))).status, 403);
  assertEquals(exactly.recorded.signed, []);
});

Deno.test("a null closes-at is refused, never read as 'never closes'", async () => {
  const { handler, recorded } = harness({ closesAt: null });
  assertEquals((await handler(post(wellFormed()))).status, 403);
  assertEquals(recorded.signed, []);
});

// ---------------------------------------------------------------------------
// Finding 1: an original is claimed once, and a claimed original is nobody's
// to overwrite
// ---------------------------------------------------------------------------

Deno.test("a photo id another member's row already holds is refused", async () => {
  const { handler, recorded } = harness({ photoRowExists: true });
  const res = await handler(post(wellFormed()));
  assertEquals(res.status, 409);
  assertEquals(
    recorded.signed,
    [],
    "no URL may be minted over a claimed original",
  );
});

Deno.test("a photo id your OWN row already holds is refused too, because an original is immutable", async () => {
  // The refusal is flat on purpose. A contributor re-uploading would make
  // every cached copy of those bytes silently stale, and caching forever is
  // what `r2_object_key` being immutable buys (0006_photos.sql).
  const { handler, recorded } = harness({ photoRowExists: true });
  assertEquals((await handler(post(wellFormed()))).status, 409);
  assertEquals(recorded.signed, []);
});

Deno.test("a retry before the row exists is still signed, which is the whole ordering", async () => {
  // Bytes first, row second (docs/architecture.md). An upload that failed
  // halfway left no row, so the same id must still be signable.
  const { handler, recorded } = harness({ photoRowExists: false });
  assertEquals((await handler(post(wellFormed()))).status, 200);
  assertEquals((await handler(post(wellFormed()))).status, 200);
  assertEquals(recorded.signed.length, 2);
  assertEquals(recorded.signed[0].objectKey, recorded.signed[1].objectKey);
});

Deno.test("the claim is checked after membership, because RLS refuses by filtering", async () => {
  const { handler, recorded } = harness();
  await handler(post(wellFormed()));
  assertEquals(recorded.asked, [
    "isTripMember",
    "tripClosesAt",
    "photoRowExists",
  ]);
});

// ---------------------------------------------------------------------------
// What a signed answer looks like
// ---------------------------------------------------------------------------

Deno.test("the answer names the key it signed and how long it lasts", async () => {
  const { handler } = harness();
  const res = await handler(post(wellFormed()));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "application/json");
  const answer = await res.json();
  assertEquals(answer.objectKey, `trips/${TRIP}/photos/${PHOTO}/original.jpg`);
  assertEquals(answer.uploadUrl, `https://r2.test/${answer.objectKey}?signed`);
  assertEquals(answer.expiresInSeconds, UPLOAD_URL_TTL_SECONDS);
});

Deno.test("the extension follows the content type, and only the original is ever keyed", () => {
  assertEquals(
    objectKeyFor(TRIP, PHOTO, "image/png"),
    `trips/${TRIP}/photos/${PHOTO}/original.png`,
  );
  assertEquals(
    objectKeyFor(TRIP, PHOTO, "image/heic"),
    `trips/${TRIP}/photos/${PHOTO}/original.heic`,
  );
  assertEquals(
    objectKeyFor(TRIP, PHOTO, "image/jpeg"),
    `trips/${TRIP}/photos/${PHOTO}/original.jpg`,
  );
});
