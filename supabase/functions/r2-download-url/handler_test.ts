// What `r2-download-url` refuses, driven at the request/response boundary.
//
// Run it:
//
//   deno test supabase/functions/r2-download-url/handler_test.ts
//
// This is the security-critical file's only automated evidence, and it exists
// at all only because `handler.ts` imports nothing off the network -- nothing
// in this repository has ever been deployed, and there is no other way to run
// an edge function's refusals. CI pins that separately with
// `deno check --no-remote handler.ts`, which fails the moment someone teaches
// the handler to import `supabase-js` directly.
//
// The checks are named after the adversarial list in the transport plan
// (§7.3), which is the list a human review of this file runs against. Six of
// its nine items are decidable here; the rest need a live project and belong
// to `tool/photo_pipe_probe.dart`. Which is which is written up in
// `supabase/README.md`.
//
// What is NOT covered here, and cannot be: whether the PostgREST queries in
// `index.ts` really read as the caller, whether `may_read_trip_photos` is
// what the SELECT policy consults (that is `supabase/tests/rls_probe.py`),
// and whether R2 honours `X-Amz-Expires`.

import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

import {
  createHandler,
  DOWNLOAD_URL_TTL_SECONDS,
  type DownloadDatabase,
  type DownloadPhotoRow,
  MAX_BATCH,
} from "./handler.ts";

const TRIP = "11111111-1111-4111-8111-111111111111";
const OTHER_TRIP = "99999999-9999-4999-8999-999999999999";
const CALLER = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

const OPEN_DAY_PHOTO = "22222222-2222-4222-8222-222222222222";
const SHUT_DAY_PHOTO = "33333333-3333-4333-8333-333333333333";
const OTHER_TRIP_PHOTO = "44444444-4444-4444-8444-444444444444";

const OPEN_DAY = 1;
const SHUT_DAY = 4;

function row(
  id: string,
  overrides: Partial<DownloadPhotoRow> = {},
): DownloadPhotoRow {
  return {
    id,
    tripId: TRIP,
    dayNumber: OPEN_DAY,
    r2ObjectKey: `trips/${TRIP}/photos/${id}/original.jpg`,
    ...overrides,
  };
}

interface Recorded {
  signed: string[];
  gateAsked: { tripId: string; dayNumber: number; userId: string }[];
  lookups: { tripId: string; photoIds: string[] }[];
}

function harness(
  answers: {
    rows?: DownloadPhotoRow[];
    openDays?: number[];
    callerId?: string | null;
    lookupFails?: boolean;
    gateFails?: boolean;
  } = {},
) {
  const recorded: Recorded = { signed: [], gateAsked: [], lookups: [] };
  const openDays = answers.openDays ?? [OPEN_DAY];

  const database = (_authHeader: string): DownloadDatabase => ({
    callerId() {
      return Promise.resolve(
        answers.callerId === undefined ? CALLER : answers.callerId,
      );
    },
    readablePhotos(tripId, photoIds) {
      recorded.lookups.push({ tripId, photoIds });
      if (answers.lookupFails) return Promise.resolve([]);
      const all = answers.rows ?? [row(OPEN_DAY_PHOTO)];
      // Stands in for RLS plus the `eq(trip_id)` narrowing: a row is returned
      // only if it is in the declared trip and was actually asked about.
      return Promise.resolve(
        all.filter((r) => r.tripId === tripId && photoIds.includes(r.id)),
      );
    },
    dayPageIsOpen(tripId, dayNumber, userId) {
      recorded.gateAsked.push({ tripId, dayNumber, userId });
      if (answers.gateFails) return Promise.resolve(false);
      return Promise.resolve(openDays.includes(dayNumber));
    },
  });

  const handler = createHandler({
    database,
    signGet(request) {
      recorded.signed.push(request.objectKey);
      return Promise.resolve(
        `https://r2.example/${request.objectKey}?X-Amz-Expires=${request.expiresInSeconds}`,
      );
    },
  });
  return { handler, recorded };
}

function ask(tripId: string, photoIds: string[], auth = "Bearer token") {
  return new Request("https://fn.example/r2-download-url", {
    method: "POST",
    headers: auth ? { Authorization: auth } : {},
    body: JSON.stringify({ tripId, photoIds }),
  });
}

async function verdicts(response: Response) {
  const body = await response.json() as {
    urls: Record<string, string>;
    refused: string[];
    expiresInSeconds: number;
  };
  return body;
}

// ---------------------------------------------------------------------------
// The happy path, which is also the shape every refusal is measured against
// ---------------------------------------------------------------------------

Deno.test("an open day's photograph comes back signed, from the row's own key", async () => {
  const { handler, recorded } = harness();
  const body = await verdicts(await handler(ask(TRIP, [OPEN_DAY_PHOTO])));

  assertEquals(Object.keys(body.urls), [OPEN_DAY_PHOTO]);
  assertEquals(body.refused, []);
  assertEquals(body.expiresInSeconds, DOWNLOAD_URL_TTL_SECONDS);
  assertEquals(recorded.signed, [
    `trips/${TRIP}/photos/${OPEN_DAY_PHOTO}/original.jpg`,
  ]);
});

Deno.test("the TTL is fifteen minutes, the settled short end", () => {
  assertEquals(DOWNLOAD_URL_TTL_SECONDS, 900);
});

// ---------------------------------------------------------------------------
// §7.3.1 -- a non-member is refused, and cannot tell that from nonexistent
// §7.3.5 -- nor can anyone tell either from a malformed id
// ---------------------------------------------------------------------------

Deno.test("§7.3.1 a photograph the caller may not read is refused", async () => {
  // The stand-in for RLS returns nothing, which is exactly what a non-member
  // gets: a refusal by filtering, not by raising.
  const { handler, recorded } = harness({ rows: [] });
  const body = await verdicts(await handler(ask(TRIP, [OPEN_DAY_PHOTO])));

  assertEquals(body.refused, [OPEN_DAY_PHOTO]);
  assertEquals(body.urls, {});
  assertEquals(recorded.signed, []);
  assertEquals(recorded.gateAsked, [], "and the gate is never even consulted");
});

Deno.test("§7.3.1 nonexistent, unreadable and malformed are one answer", async () => {
  const nonexistent = "55555555-5555-4555-8555-555555555555";
  const malformed = "not-a-uuid";
  const { handler } = harness({ rows: [] });

  const unreadable = await verdicts(await handler(ask(TRIP, [OPEN_DAY_PHOTO])));
  const missing = await verdicts(await handler(ask(TRIP, [nonexistent])));
  const bad = await verdicts(await handler(ask(TRIP, [malformed])));

  // Same shape, same status, no reason anywhere: nothing here maps the corpus.
  assertEquals(unreadable.refused.length, 1);
  assertEquals(missing.refused.length, 1);
  assertEquals(bad.refused, [malformed]);
  for (const body of [unreadable, missing, bad]) {
    assertEquals(body.urls, {});
    assertEquals(Object.keys(body).sort(), [
      "expiresInSeconds",
      "refused",
      "urls",
    ]);
  }
});

Deno.test("§7.3.5 a malformed id never reaches the database", async () => {
  const { handler, recorded } = harness();
  await handler(ask(TRIP, ["../../etc/passwd", "%2e%2e", OPEN_DAY_PHOTO]));

  assertEquals(recorded.lookups.length, 1);
  assertEquals(recorded.lookups[0].photoIds, [OPEN_DAY_PHOTO]);
});

// ---------------------------------------------------------------------------
// §7.3.2 -- the cross-trip leak, which is the one that matters most
// ---------------------------------------------------------------------------

Deno.test("§7.3.2 a photograph in another trip is refused, not signed", async () => {
  const { handler, recorded } = harness({
    rows: [row(OTHER_TRIP_PHOTO, { tripId: OTHER_TRIP })],
  });
  const body = await verdicts(await handler(ask(TRIP, [OTHER_TRIP_PHOTO])));

  assertEquals(body.refused, [OTHER_TRIP_PHOTO]);
  assertEquals(recorded.signed, []);
});

Deno.test("§7.3.2 and declaring the other trip does not help without a readable row", async () => {
  // The caller names the trip the photograph really is in. RLS is what says
  // no, and the stand-in above only returns rows for trips it was given --
  // so a caller who is not on that trip still gets nothing.
  const { handler, recorded } = harness({ rows: [] });
  const body = await verdicts(
    await handler(ask(OTHER_TRIP, [OTHER_TRIP_PHOTO])),
  );

  assertEquals(body.refused, [OTHER_TRIP_PHOTO]);
  assertEquals(recorded.signed, []);
});

// ---------------------------------------------------------------------------
// §7.3.3 -- the gate sits inside the per-id loop
// ---------------------------------------------------------------------------

Deno.test("§7.3.3 a shut day is refused while the same batch's open day succeeds", async () => {
  const { handler, recorded } = harness({
    rows: [
      row(OPEN_DAY_PHOTO),
      row(SHUT_DAY_PHOTO, { dayNumber: SHUT_DAY }),
    ],
    openDays: [OPEN_DAY],
  });
  const body = await verdicts(
    await handler(ask(TRIP, [OPEN_DAY_PHOTO, SHUT_DAY_PHOTO])),
  );

  assertEquals(Object.keys(body.urls), [OPEN_DAY_PHOTO]);
  assertEquals(body.refused, [SHUT_DAY_PHOTO]);
  assertEquals(recorded.signed.length, 1, "the shut day's key is never signed");
});

Deno.test("§7.3.3 the gate is asked before anything is signed", async () => {
  const order: string[] = [];
  const database = (_auth: string): DownloadDatabase => ({
    callerId: () => Promise.resolve(CALLER),
    readablePhotos: () => Promise.resolve([row(OPEN_DAY_PHOTO)]),
    dayPageIsOpen: () => {
      order.push("gate");
      return Promise.resolve(true);
    },
  });
  const handler = createHandler({
    database,
    signGet: (r) => {
      order.push("sign");
      return Promise.resolve(`https://r2.example/${r.objectKey}`);
    },
  });
  await handler(ask(TRIP, [OPEN_DAY_PHOTO]));

  assertEquals(order, ["gate", "sign"]);
});

Deno.test("§7.3.3 the gate fails shut when it cannot answer", async () => {
  const { handler, recorded } = harness({ gateFails: true });
  const body = await verdicts(await handler(ask(TRIP, [OPEN_DAY_PHOTO])));

  assertEquals(body.refused, [OPEN_DAY_PHOTO]);
  assertEquals(recorded.signed, []);
});

Deno.test("a failed row read refuses everything rather than signing anything", async () => {
  const { handler, recorded } = harness({ lookupFails: true });
  const body = await verdicts(
    await handler(ask(TRIP, [OPEN_DAY_PHOTO, SHUT_DAY_PHOTO])),
  );

  assertEquals(body.refused, [OPEN_DAY_PHOTO, SHUT_DAY_PHOTO]);
  assertEquals(recorded.signed, []);
});

// ---------------------------------------------------------------------------
// §7.3.4 -- nothing the caller says chooses the gate or the key
// ---------------------------------------------------------------------------

Deno.test("§7.3.4 the gate is asked about the row's trip and day, not the request's", async () => {
  const { handler, recorded } = harness({
    rows: [row(OPEN_DAY_PHOTO, { dayNumber: SHUT_DAY })],
    openDays: [SHUT_DAY],
  });
  await handler(ask(TRIP, [OPEN_DAY_PHOTO]));

  assertEquals(recorded.gateAsked, [{
    tripId: TRIP,
    dayNumber: SHUT_DAY,
    userId: CALLER,
  }]);
});

Deno.test("§7.3.4 a day or key named in the body is not read at all", async () => {
  // The request body carries fields this function has no field for. If any of
  // them were consulted, this photograph would be signed under a key of the
  // caller's choosing on a day of the caller's choosing.
  const { handler, recorded } = harness({
    rows: [row(SHUT_DAY_PHOTO, { dayNumber: SHUT_DAY })],
    openDays: [OPEN_DAY],
  });
  const request = new Request("https://fn.example/r2-download-url", {
    method: "POST",
    headers: { Authorization: "Bearer token" },
    body: JSON.stringify({
      tripId: TRIP,
      photoIds: [SHUT_DAY_PHOTO],
      dayNumber: OPEN_DAY,
      r2ObjectKey: `trips/${OTHER_TRIP}/pages/stolen.jpg`,
      userId: "someone-else",
    }),
  });
  const body = await verdicts(await handler(request));

  assertEquals(body.refused, [SHUT_DAY_PHOTO]);
  assertEquals(recorded.signed, []);
  assertEquals(recorded.gateAsked[0].dayNumber, SHUT_DAY);
  assertEquals(recorded.gateAsked[0].userId, CALLER);
});

Deno.test("§7.3.4 only the row's own object key is ever signed", async () => {
  const stored = `trips/${TRIP}/photos/${OPEN_DAY_PHOTO}/original.heic`;
  const { handler, recorded } = harness({
    rows: [row(OPEN_DAY_PHOTO, { r2ObjectKey: stored })],
  });
  const body = await verdicts(await handler(ask(TRIP, [OPEN_DAY_PHOTO])));

  assertEquals(recorded.signed, [stored]);
  assertStringIncludes(body.urls[OPEN_DAY_PHOTO], stored);
});

Deno.test("a stored key with traversal or empty segments is refused before signing", async () => {
  const unsafe = [
    `trips/${TRIP}/photos/${OPEN_DAY_PHOTO}/../secret.jpg`,
    `trips/${TRIP}/photos/${OPEN_DAY_PHOTO}//original.jpg`,
    `trips/${TRIP}/photos/${OPEN_DAY_PHOTO}/%2e%2e/secret.jpg`,
    `trips/${TRIP}/photos/${OPEN_DAY_PHOTO}/..\\secret.jpg`,
  ];

  for (const r2ObjectKey of unsafe) {
    const { handler, recorded } = harness({
      rows: [row(OPEN_DAY_PHOTO, { r2ObjectKey })],
    });
    const body = await verdicts(await handler(ask(TRIP, [OPEN_DAY_PHOTO])));

    assertEquals(body.urls, {});
    assertEquals(body.refused, [OPEN_DAY_PHOTO]);
    assertEquals(recorded.gateAsked, []);
    assertEquals(recorded.signed, []);
  }
});

Deno.test("a stored key outside the row's own folder is refused before signing", async () => {
  const { handler, recorded } = harness({
    rows: [row(OPEN_DAY_PHOTO, {
      r2ObjectKey: `trips/${TRIP}/pages/secret.jpg`,
    })],
  });
  const body = await verdicts(await handler(ask(TRIP, [OPEN_DAY_PHOTO])));

  assertEquals(body.urls, {});
  assertEquals(body.refused, [OPEN_DAY_PHOTO]);
  assertEquals(recorded.gateAsked, []);
  assertEquals(recorded.signed, []);
});

// ---------------------------------------------------------------------------
// §7.3.5 -- batches, and the bounds on one invocation
// ---------------------------------------------------------------------------

Deno.test("§7.3.5 an oversize batch is refused whole, and refused before any work", async () => {
  const { handler, recorded } = harness();
  const ids = Array.from(
    { length: MAX_BATCH + 1 },
    (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`,
  );
  const response = await handler(ask(TRIP, ids));

  assertEquals(response.status, 400);
  assertStringIncludes(await response.text(), String(MAX_BATCH));
  assertEquals(recorded.lookups, [], "nothing is looked up");
  assertEquals(recorded.signed, []);
});

Deno.test("§7.3.5 the cap counts what was sent, not what survives de-duplication", async () => {
  const { handler } = harness();
  const ids = Array.from({ length: MAX_BATCH + 1 }, () => OPEN_DAY_PHOTO);
  assertEquals((await handler(ask(TRIP, ids))).status, 400);
});

Deno.test("a repeated id is answered once", async () => {
  const { handler, recorded } = harness();
  const body = await verdicts(
    await handler(ask(TRIP, [OPEN_DAY_PHOTO, OPEN_DAY_PHOTO])),
  );

  assertEquals(Object.keys(body.urls), [OPEN_DAY_PHOTO]);
  assertEquals(recorded.signed.length, 1);
});

Deno.test("one day is asked of the gate once, however many photographs it holds", async () => {
  const second = "66666666-6666-4666-8666-666666666666";
  const { handler, recorded } = harness({
    rows: [row(OPEN_DAY_PHOTO), row(second)],
  });
  await handler(ask(TRIP, [OPEN_DAY_PHOTO, second]));

  assertEquals(recorded.gateAsked.length, 1);
  assertEquals(recorded.signed.length, 2);
});

// ---------------------------------------------------------------------------
// The envelope
// ---------------------------------------------------------------------------

Deno.test("only POST, and only with an Authorization header", async () => {
  const { handler } = harness();
  const get = await handler(
    new Request("https://fn.example/r2-download-url", { method: "GET" }),
  );
  assertEquals(get.status, 405);

  const anonymous = await handler(ask(TRIP, [OPEN_DAY_PHOTO], ""));
  assertEquals(anonymous.status, 401);
});

Deno.test("§7.3.9 a token that does not resolve to a user signs nothing", async () => {
  const { handler, recorded } = harness({ callerId: null });
  const response = await handler(ask(TRIP, [OPEN_DAY_PHOTO]));

  assertEquals(response.status, 401);
  assertEquals(recorded.lookups, []);
  assertEquals(recorded.signed, []);
});

Deno.test("a malformed trip id, body or list is refused before any lookup", async () => {
  const { handler, recorded } = harness();

  const badTrip = await handler(ask("nope", [OPEN_DAY_PHOTO]));
  assertEquals(badTrip.status, 400);

  const badBody = await handler(
    new Request("https://fn.example/r2-download-url", {
      method: "POST",
      headers: { Authorization: "Bearer token" },
      body: "{",
    }),
  );
  assertEquals(badBody.status, 400);

  const empty = await handler(ask(TRIP, []));
  assertEquals(empty.status, 400);

  assertEquals(recorded.lookups, []);
  assertEquals(recorded.signed, []);
});

Deno.test("a refusal names no reason anywhere in the response", async () => {
  const { handler } = harness({
    rows: [row(SHUT_DAY_PHOTO, { dayNumber: SHUT_DAY })],
    openDays: [OPEN_DAY],
  });
  const response = await handler(ask(TRIP, [SHUT_DAY_PHOTO]));
  const text = await response.text();

  assertEquals(response.status, 200);
  for (const word of ["gate", "member", "shut", "day", "trip"]) {
    assert(
      !text.toLowerCase().includes(word),
      `the response says "${word}", which tells a guesser why`,
    );
  }
});
