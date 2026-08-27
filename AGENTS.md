# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Layout

- `learning/` — throwaway demos built to make a technical decision, not the app.
  - `learning/dual-camera-spike/` decided the moment's dual capture: build back-then-front
    sequential capture, not true hardware-simultaneous dual camera, because the evidence says
    that's what BeReal itself actually does and true simultaneity has no Flutter framework
    support on either platform. See its `README.md` for the full evidence trail. One sharp edge
    worth knowing generally: `AVCaptureMultiCamSession.isMultiCamSupported` is a device-class
    flag, not a live-hardware probe -- it read `true` on the iOS Simulator during that spike's
    testing, which has no camera at all. Never treat that flag alone as proof a capture session
    will actually work, on Simulator or a real device.
- `supabase/` — the backend (see below).
- `packages/` — standalone Dart packages (own `pubspec.yaml`, tested with `dart test`) that back the Flutter app but must stay Flutter-free. Keep new packages under this pattern rather than pulling their logic into the Flutter app directly.
- `ops/` — small operational Cloudflare Workers that support the backend but aren't part of the app or the Supabase schema. `ops/keepalive-worker/` pings the hosted Supabase project three times a week (Mon/Wed/Fri) so the free tier never auto-pauses from inactivity; it is cron-only and deliberately has no `fetch` handler, so verify it through `wrangler dev --test-scheduled` or the dashboard's Trigger button rather than a URL; see its `README.md` and `supabase/README.md`'s Free-tier limits section for why it's a Worker and not a GitHub Actions cron or `pg_cron` job. Deploy with `wrangler deploy` from inside the worker's directory.

## The app (root `pubspec.yaml`, `lib/`, `ios/`)

The Flutter application (Riverpod for app state, Drift for the local
database). `lib/README.md` is the authority on the layout: each directory
under `lib/` is one band of `docs/architecture.md`, and which band may
import what is written there, not here.

- Drift's generated code (`lib/**/*.g.dart`) is not checked in (root
  `.gitignore`): run `dart run build_runner build` after checkout, before
  analyzing or testing the app.
- Schema is at v7. A test that stands up an *old* schema by winding
  `user_version` back must also drop everything later versions added
  (`test/trip_id_test.dart`'s `windBackToV4` is the pattern) -- an upgrade that
  finds its own column already there fails outright, and the failure reads like
  a bug in the migration rather than in the fixture.
- Analyze with `flutter analyze lib test tool` from the root. A bare
  `flutter analyze` also walks `learning/` and `packages/` -- separate
  projects with their own dependency contexts -- and reports their
  unfetched dependencies as errors. `tool/` is named because the analyzer
  reports on the files it is *given*, not on everything they import: a test
  importing a script does not get that script analyzed.
- iOS only, deliberately: no `android/` exists and the dev machine has no
  Android SDK. The build gate is
  `flutter build ios --simulator --no-codesign`. The signing configuration is
  committed on purpose — `ios/Runner.xcodeproj/project.pbxproj` carries the
  bundle id `com.ka1o.cairn` (`.RunnerTests` for the test target) and a
  `DEVELOPMENT_TEAM`, because it used to live only as an uncommitted local edit
  and a clean checkout could not build to a device. Nothing else in the repo
  hardcodes the bundle id, and there are no entitlements, profiles or
  `CODE_SIGN_STYLE` overrides to keep in step.
- The launch surface: `RootScreen` opens on the paste box until an itinerary
  is accepted into Drift, then on the trip — `TripShell`, whose tabs open on
  **Today**. Each flow's whole brain is one file in `lib/app_state/`
  (`paste_flow.dart`, `import_flow.dart`, `day_view.dart`, `trail_view.dart`,
  `pool_view.dart`, `capture_flow.dart`, `ping_schedule.dart`); screens render
  their view models and never import the parser or `cairn_model`.
- **`lib/logic/` holds pure decision cores the app-state band calls** — no
  Flutter, no Riverpod, no IO. It holds the plan said back as pasteable text
  (`plan_text.dart`) and, its first resident, the re-paste merge
  (`repaste_merge.dart`, tested in `test/repaste_merge_test.dart`), whose
  rules are settled: match repasted days to saved days by date first (a
  full-year title candidate counts for matching but is never bound, and one
  the parser flagged `ambiguousNumericOrder` counts for nothing — it matches
  as undated and rides on the result for the date sheet to ask about), then
  undated days by position; a matched day takes the repasted place and stops
  wholesale, and survival is plan-wide — a stop whose text still appears
  anywhere in the revised plan was moved, not displaced, and only text the
  re-paste no longer says at all (case/whitespace-insensitive) goes to the
  set-aside; unclaimed
  current days come back as the very same `ConfirmedDay` instance, unclaimed
  repasted days append numbered past the current maximum. A day's identity is
  its number — photos key on it — so the merge never renumbers and never
  re-dates an existing day. It speaks `ConfirmedDay`, not
  `cairn_model.TripDay`: saved plans carry open dates and have no clock yet
  (the repository says why).
- **The paste box survives the process, but only for an import.**
  `lib/app_state/plan_draft.dart` holds the whole rule and
  `plan_drafts` (one row, id 1, schema v7) holds the text. An import that
  lands starts the draft, and only an import or the person's own editing may
  write to it — not the example, not a plan typed from scratch, and a
  programmatic fill that isn't an import leaves a standing draft alone rather
  than overwrite it — because what it defends is an expensive read (a
  three-page scan through recognition), not typing. While it stands it
  *tracks the box*, which is what makes "never resurrect over something the
  person has since typed by hand" true by construction instead of by a
  timestamp; there is deliberately **no expiry**. Emptying the box discards
  it, `PasteFlow.accept` forgets it, a fresh import replaces it. The restore
  rule is the paste screen's, because only it knows what is in the box: a
  draft is put back **only into a box that would otherwise open empty**, so
  it never lands over a re-paste's pre-filled live plan, and the read
  re-checks the box before writing into it. It is local and must stay local
  — pre-accept text has no trip, no clock and nothing eight phones could
  agree on, so it is not in `itinerary_sync.dart`'s cargo and never becomes
  a shared fact. `test/plan_draft_test.dart` relaunches the app over the
  same database to prove all of it.
- **The read-back is an editor, and it never demolishes.** The confirm screen
  edits a *draft* inside `paste_flow.dart`, and `accept()` builds the
  `ConfirmedItinerary` from that draft rather than from the parse. Every stop
  carries a stable id so a chip survives being reworded, timed, reordered,
  moved to another day or removed. **Removing a stop files it in the set-aside
  with a reason; nothing the person pasted is ever deleted** — that is why the
  tile's title flips from "couldn't place" to "set aside" once a removal of
  the person's own is in it, and why a set-aside line drags back into a day.
  The gestures are split deliberately: a *tap* on a chip opens its menu, a
  *long press* drags it (`LongPressDraggable` + `DragTarget`, built-in
  Flutter, no package), and the whole chip is the handle, not an icon. A day's
  emptiness is live state, not a parse verdict — drag the last stop off a day
  and it asks what a day that arrived empty asks, which also collapses the
  clean days to slim rows. A whole-paste re-read (`readMonthFirst`, `useYear`)
  reparses and so discards the draft; its card says so. **That card teaches
  with the plan's own date, never an invented one** — the parser hands back
  the first date that reads both ways round
  (`ParseResult.firstAmbiguousNumericDate`, recorded at the match rather than
  re-derived from the dialect the parse ran in), the app band spells it both
  ways (`MonthFirstExample`), and the screen only arranges the two readings.
  Whether the flip is offered at all *is* that example's presence
  (`offerMonthFirstFix` is a getter over it), so a card teaching a date the
  plan does not contain, or offered where no date would move, is a state that
  cannot be built.
- **A date inside a day's own title is a candidate, never a binding.**
  `Day 1 - Tokyo, 14 June` used to lose the date entirely; the parser now
  surfaces it as `ParsedDay.dateCandidate` (`src/date_header.dart`'s
  `findDateFragment`, which also hands back the title with the fragment lifted
  out) and *still does not set the date*. The phone asks, through the confirm
  screen's date sheet, and `leaveDateOpen` is an answer it remembers rather
  than a dismissal. A parser that binds a year is the thing to refuse in
  review: `_resolveCandidate` rolls a year-less candidate off the first date
  already bound in the draft — `todayProvider` when there is none — and the
  sheet shows the weekday it worked out, so a wrong year is visible before it
  binds and not after. **Dating the *first* day dates the whole plan**, though:
  `setDayDate` runs `_fillDatesFromFirstDay` down the draft (day two the day
  after, and so on) whenever the day it just dated is the first one. Later days
  stay individually adjustable, and dating one of those fills nothing; the
  trade-off, deliberate and written on `setDayDate`, is that re-dating day one
  re-runs the fill over a later day someone adjusted by hand. Day one is the
  anchor, and moving the anchor moves the plan.
- **The container is `lib/screens/trip_shell.dart`**: a tab per destination,
  each owning its own `Navigator` so a day page opened from the Trail
  survives a switch to Today and back. It holds all three of the design's
  destinations (Today, Trail, Pool) and no fourth: trip-level actions hang
  off the Trail's title, where the chevron opens `TripSheet` — the roster,
  the trip's live code, rename, new words, the gated delete, and the two
  entries that change a running trip's plan without destroying it. Anything
  drawn but not built stays **absent, not disabled** — that is how the Pool
  waited, how leaving and removing wait now, and how the next one should.
- **Editing never requires deleting the trip, and there is no destructive
  re-paste.** The old "Paste a different plan" hatch is gone; re-introducing
  one is the thing to refuse in review. The sheet's *Edit the whole plan*
  opens the same read-back editor over the live plan (`PasteFlow.editLivePlan`;
  `planEditorProvider` is what `RootScreen` watches to draw it) and **nothing
  is written until Save** — `cancelPlanEdit` leaves the trip untouched. The
  sheet's *Re-paste the plan text* hands the paste box the plan said back as
  text (`lib/logic/plan_text.dart`) and reading it **merges** into the plan
  (`lib/logic/repaste_merge.dart`) instead of replacing it: what the new text
  no longer carries is displaced into the set-aside, never deleted. Two traps.
  The merge is `lib/logic/`'s shared module and `mergeRepaste` is called from
  exactly one place (`PasteFlow._mergeReparse`), so the whole rule stays
  swappable in one edit; keep it that way. And **every route from the
  editor back to the paste box must stay in merge mode**, and so must
  every *re*-read once inside it: `startOver` redirects to
  `repasteCurrentPlan`, and `_mergesInsteadOfReplacing` (the frozen baseline,
  not "is the paste box open") is what routes the month-first flip and the
  year answer, whose second read would otherwise fall through to a plain parse
  and overwrite the trip with whatever text was in the box. That is the hatch
  this removed. A day the merge leaves in place keeps its **number**,
  and that alone is what keeps its photographs: `photos.dayNumber` is the only
  link, and nothing re-files photos when a plan is saved. The merge never
  renumbers, so a day's photographs never move — but *keeping* them is not the
  same as keeping them with the right day. The position pass can pair a
  repasted day with a **different** current day: drop the first of three
  undated days from the re-paste text and `repasted[0]` pairs with
  `current[0]`, so day 1 keeps its number and so its photographs while its
  content becomes what was day 2's. **A day the re-paste *adds* keeps the
  parser's doubt, and a day the plan already held keeps none** — `MergedDay`
  carries `confidence`, `uncertainty` and `headerWeekday` off the parse for
  `MergedDayOrigin.appendedNew` alone, so `Sat - Nara` is asked about exactly
  as it would be on a first paste instead of rendering clean and saving with
  its date silently open, while a day the person already answered for is not
  nagged again. That asymmetry is the rule, not an oversight; making it
  uniform in either direction is the thing to refuse in review. It is keyed on
  origin, though, and not on whether the content is new, so the position-pairing
  gap just named is also the path where genuinely new content still arrives
  without doubt: insert an undated `Sat - Nara` block above an existing undated
  day and it pairs by position, rides in clean, and saves with its date open
  unasked. Two known
  gaps remain, both deferred. A displaced line's time — `itinerary_set_asides` has no time column, so a
  set-aside stop's star survives only until Save, and dragging it back after a
  reopen restores it unstarred; closing that needs a schema change. And a
  second sits in `lib/logic/plan_text.dart`: a stop's time is written back
  into the rendered line when the words contradict it, but a time the person
  *cleared* cannot be — `10:00 Coffee` with its time taken off still says
  10:00, so the re-read stars it again. Closing that needs the renderer to
  reword what the person wrote, which it deliberately never does.
- **The phone mints the trip's id, and the server keeps it**
  (`docs/decisions/2026-08-25-the-trip-mints-its-own-id.md`). A trip must be
  startable in flight mode, and the ping schedule seeds itself from the id, so
  an id issued at first sync would silently re-deal every remaining day. The
  mint is split like the invite draw — `TripId.mint(bytes)` in `cairn_model`
  is the shape, `mintTripId()` in `app_database.dart` is the randomness — and
  it is called *inside* the transaction that decides there is no trip yet, so
  nothing above the store may hand in an id of its own. **There is no fallback
  id anywhere**: the `localTripId = 'local-trip'` constant is gone and
  `pingsForPlan` requires a real `TripId`. Schema v5 heals a trip written
  before the mint; that is the only time an id changes, and after it an id is
  the trip's for good.
- **The trip is a stored fact, and the permission model is not the app's.**
  Accepting a plan starts it (`MembershipStore.startTrip`, idempotent) and
  mints its id and its first three-word code. Who may do what is
  `cairn_model`'s `trip_powers.dart` and nothing above it re-decides it;
  there is no role
  column in `trip_members` and there must never be one. A code carries no
  expiry of its own either: it dies when the trip closes, so
  `trip_invite_codes` has no expiry column and `TripInvite.standingAt` is
  *told* the close. Everything about joining is local — nothing carries a
  membership to another phone, and the join door says so rather than
  spinning.
- **The itinerary and the roster are shared facts, and the seam is what makes
  them shared.** `lib/repositories/itinerary_sync.dart` is the one file holding
  both backends at once: it pushes this phone's plan, applies what the merge
  hands back, and replaces the roster wholesale (RLS means the server only
  answers a member, so the roster it returns necessarily contains the caller;
  a merge that kept a local row would resurrect somebody who left and deal
  them a ping). It reports a *standing*, never an error — dormant, no trip,
  awaiting the trip row, offline, refused, archived, synced — and offline
  means the local copy is untouched and authoritative. Two rules to keep: applying a merge must
  never re-stamp a day's clock (that is what makes two phones push at each
  other forever), **an archived trip is not reconciled at all** (it returns
  `SyncStanding.archived` before the first round trip, so a pull cannot apply
  somebody's plan over a closed record — and the server refuses the same call
  for the same reason, `sync_trip_itinerary` raising on `trip_closes_at`,
  because one of eight phones has a wrong clock), and **a reconcile that changed nothing
  must write nothing**,
  because the plan's own Drift stream is what asks for the next sync. Nothing
  above the seam knows any of this exists, deliberately.
- **The path is live, and only one test proves it.** An ordinary build points
  at the hosted project (`SharedFactsConfig.fromEnvironment` defaults; the anon
  key is publishable and belongs in the repo, the service-role key and the DB
  password never do), signs in as a GoTrue *anonymous* account
  (`lib/storage/remote/gotrue_sessions.dart`, the stand-in until Apple lands),
  and the signed-in id becomes `localMemberIdProvider` — one change and not
  two, because the roster is replaced wholesale with the server's and a phone
  still calling itself `me` would ask the gate and the ping schedule about a
  stranger. That id is resolved on the boot path but **not over the network**:
  the vault keeps the account's id beside its refresh token, so `main()` reads
  it off a local file and only a first-ever launch waits (three seconds, then
  the stand-in). The identity is fixed for the launch — a session that lands
  late is stored for the next one, never adopted mid-session. `flutter test` never reaches out: every widget test binds
  `NoSession`, and the live check is
  `flutter test test/hosted_smoke_test.dart --dart-define=CAIRN_HOSTED_SMOKE=true`.
  **A green suite is still no evidence the hosted project behaves** — that is
  what that one test is for, and `supabase/README.md` is the authority on the
  defines, on why `CAIRN_TRIP_TIMEZONE` has no default, and on what the hosted
  project has and has not actually done.
- **The trip's three Drift tables do not re-emit for free.** `trip_facts`,
  `trip_members` and `trip_invite_codes` are read through one stream, and it
  is a `customSelect` over all three with `readsFrom` — minting a code
  changes no fact about the trip, so a stream watching `trip_facts` alone
  leaves a rotated code on screen. Writing a no-op empty companion to force
  an emit does not work; this was the bug.
- **Recognition is an edge, and it is judged on a device only.**
  `lib/app_state/text_recognition_edge.dart` is Apple Vision behind a seam on
  the `camera_source.dart` pattern — bytes in, lines in reading order out —
  with `ios/Runner/TextRecognition.swift` (a `VNRecognizeTextRequest` over the
  hand-written `cairn/text_recognition` channel, `.accurate`, language
  correction on) as the one real implementation and `FakeTextRecognition` as
  the only one any automated test ever exercises. **A green suite and a green
  simulator run are no evidence OCR works**, exactly as for the camera; real
  recognition quality is judged on a device against a manual corpus — with one
  exception, below, which is arithmetic rather than judgement. **A
  refusal has two flavours and they must not share a sentence**:
  `RecognitionRefused.kind` is `unavailable` (no channel host, a device Vision
  cannot query languages for) or `noTextFound`, and only the first blames the
  device — the second lands on `noReadableTextInPictureSentence`, the same
  words an empty answer gets, written once. Native raises the split as the
  `no_text` error code, and it does so on *both* halves of a Vision refusal
  (an error handed to the completion, and a throw out of `perform` — a
  one-pixel image fails through the second). Blaming the phone for an ordinary
  textless picture is the thing to refuse in review. Four
  things worth knowing. Pictures never enter `planExtractors` — `claimsImage`
  in `import_flow.dart` claims them by extension first and magic bytes second,
  so a renamed screenshot still finds the route — and it runs *before*
  `routeToExtractor`, so an extension-based image claim pre-empts an
  extractor's magic-byte match (a text file named `.png` goes to OCR).
  **Both doors accept pictures**: the file door's picker filter is
  `documentImportExtensions` (derived from the registry, as before) *plus*
  `imageImportExtensions`, because a screenshot saved into Files is the same
  screenshot as one in the photo library and the person does not know which
  door they are standing at (captain's decision, 2026-08-27). One route, not
  two — the picked image falls through `_read`'s `claimsImage` to the very
  same recognition call the photo door makes — so a second image path is the
  thing to refuse in review; the pill's sub-line spells the documents out and
  says `pictures` for the rest rather than naming ten image extensions. The **scanned-PDF door** is
  the one-tap offer off a `noTextLayer` refusal, and it must read with
  recognition *unconditionally* (`_runRead(viaOcrRoute: true)` bypasses the
  registry): routing it back through `_read` sends the bytes to the very
  extractor that already said the pages were pictures. And the photo-library
  door needs `NSPhotoLibraryUsageDescription` in `Info.plist` because
  `file_picker`'s image mode builds `PHPickerConfiguration(photoLibrary:)`,
  the authorization-requiring form. And **a scanned page is never drawn larger
  than the pixels it actually has**: `TextRecognition.renderScale` treats the
  2400 long-edge target as a ceiling and clamps it to the page's own image
  resolution (`nativePixelLongEdge`, which counts an image only when it is
  shaped like its page *and* carries at least one pixel per point of the
  page's long edge, so neither a logo beside vector text nor a low-resolution
  full-bleed watermark behind it can drag a page down below the target).
  Upscaling *loses* text rather than gaining it — a 700x900px screenshot
  wrapped into a PDF read back 5 of its 17 lines at 4x and all 17 at 1x, with
  the same picture through the photo door reading perfectly either way — which
  is the counter-intuitive part and the thing to refuse in review if someone
  raises the target again. A 300dpi scan is untouched; the target still bounds
  it.
- **Reading order is measured off the text, never off the page.**
  `ios/Runner/TextLineOrder.swift` is the whole rule: Vision reports one
  observation per visual line, in no order, and names each quadrilateral's
  corners in the *text's* own frame, so `topRight - topLeft` points along the
  reading direction whichever way up the picture is. Sorting on
  `boundingBox.midY` instead — which the edge did until 2026-08-27 — is
  reading order only while the page happens to be upright: a plan photographed
  sideways with no EXIF orientation tag recognises every line and returns them
  fully shuffled, days interleaved, and a careless person accepts a scrambled
  trip. Reintroducing an assumed axis is the thing to refuse in review. The
  file is deliberately pure geometry — no Vision, no Flutter — and is compiled
  into **both** the Runner and RunnerTests targets, which is what lets
  `ios/RunnerTests/TextLineOrderTests.swift` cover the rotated case at all:
  it is one of the two automated tests of anything in `ios/Runner/` (the
  other is `RunnerTests.swift`, over the render-scale arithmetic), and it runs
  under `xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner
  -only-testing:RunnerTests` (a simulator destination; `flutter test` never
  reaches it).
- **The Swift side has tests, and `flutter test` does not run them.**
  `ios/RunnerTests/` is an XCTest bundle already wired into the `Runner`
  scheme; run it with
  `xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner
  -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>'
  -only-testing:RunnerTests CODE_SIGNING_ALLOWED=NO` after a
  `flutter build ios --simulator --debug --no-codesign` (Debug, because the
  tests need `ENABLE_TESTABILITY`). Only the platform code that is *decidable*
  belongs there — the OCR render-scale arithmetic and the reading-order
  geometry above are the whole of it today, and recognition quality still is
  not testable anywhere.
- **Capture is a route, not a tab.** The only way in is the day page's one
  call to action, and only an open or a late window offers it. The camera is
  behind `CameraSource` (`lib/app_state/camera_source.dart`): a real back
  camera on a device, a *generated* PNG anywhere without one — which is what
  makes the flow walkable on the Simulator, and also means a green simulator
  run is no evidence the camera path works. Judge that on a device only.
  `NSCameraUsageDescription` is in `ios/Runner/Info.plist`; audio is off, so
  no microphone string is needed. The ping's schedule is real
  (`trip_moments`) but dealt for a stub party of one, and `NotificationEdge`
  is not implemented against iOS -- nothing actually buzzes yet.
- **The stored frame is the original, and every displayed size is derived.**
  Settled 2026-08-22 (`docs/decisions/2026-08-22-grill-round-one.md` §3);
  the trip's full-size handover promise rests on it. Two halves, and both
  are load-bearing: `BackCameraSource` asks for `ResolutionPreset.max`
  (`high` is 720p on iOS -- a downsize no later layer could undo) and files
  the plugin's file with a byte-for-byte copy; and **every photo surface
  draws through `lib/screens/photo_frame.dart`**, which decodes the original
  down to the box it lands in and never writes. A bare `Image.file` on a
  stored photo is the thing to refuse in review -- it looks right and costs
  ~48 MB of image cache per 12-megapixel tile. The decode size is
  fit-aware, because reading the wrong edge is silent both ways. What the
  rule costs is measured, not estimated: `docs/storage-and-cost.md`, from
  `tool/measure_photo_corpus.dart`. Re-run the tool rather than adding a
  second estimate beside the first -- two disagreeing estimates is the state
  that file was written to end, and the trap it fell into first is that most
  files in a photo library are not photographs a camera took.
- **A photo row is an index, not the photograph**: Drift's `photos` table
  holds the row, the frame is a file in the app's documents directory, and
  that mirrors Postgres-plus-R2 on the server on purpose. The seam over it has
  two halves on purpose -- `PhotoRepository` is the read interface the Pool was
  built against, `PhotoStore` is the Drift implementation that also owns the
  write path, and `bootstrap.dart` binds both providers to the one instance.
  Bind them to two and every test still passes while the Pool goes blank.
- **There is one day screen and no separate day detail.** Today is
  `DayPage(date:)` handed today's date; the Trail opens the same widget for
  every node, through `DayPage.planDay(n)`. Two ways in, one screen: the
  number is the only way to reach a day whose date is still open, since
  nothing here guesses a date. A second day surface is the thing to refuse in
  review. `todayProvider` derives today from the *device* date because no
  trip clock is stored yet — it is the one place that changes when one is,
  and `bootstrapApp(today:)` pins it in tests.
- The Trail draws **one node per day of the plan and no others**: a date the
  plan skips gets a `GapDay` page but never a node, because every drawing
  numbers the path over the plan's own days ("Day 4 of 8"). The winding
  geometry is the screen's identity, not decoration.
- **The Pool reads; capture writes; they meet at one store.**
  `PhotoRepository` (`lib/repositories/photo_repository.dart`) is the trip's
  photo *read* seam, and `PhotoStore` is the Drift implementation that answers
  it and owns the write path. `bootstrap.dart` binds `photoRepositoryProvider`
  and `photoStoreProvider` to the same instance — that, and nothing else, is
  what makes a captured photo appear in the Pool. Tests build a pool of a
  known shape through `bootstrapApp(photos:)`, which overrides the read side
  alone. Two rules the screen depends on: a photo's day is
  the `dayNumber` already on its `PhotoRef` — never re-derived from
  `photo_day_assignment` on read, since a person may have overridden it — and
  a day's photos are ordered by `cairn_model.DayPool`, not by the screen. A
  tile whose bytes are not on this phone is a permanent state of a pool eight
  people share, not a loading spinner.
- **A trip ends, and where it stands is one rule written once.**
  `cairn_model`'s `tripStandingAt` turns `(now, endsAt)` into underway / grace
  / archived, and every surface and write path asks it through
  `tripStandingProvider` (`lib/app_state/trip_lifecycle.dart`, which reads the
  saved plan of bare calendar dates and hands its days to the domain's
  `tripEndsAtFrom` — the arithmetic is shared with `TripSync._endsAt`, so an
  ending cannot be one thing on screen and another on the wire). A second
  comparison of dates above that provider is the thing
  to refuse in review. The shape is
  `docs/decisions/2026-08-26-the-ending.md`: seventy-two hours of grace taking
  nothing but late photographs, then the record is fixed. Three things worth
  knowing before touching it. **The read-only half is a permission**, in
  `trip_powers.dart`, so a new caller inherits it — with `canDeleteTrip` the
  one deliberate exception (discarding a record is not editing it). **A trip ends at the end of its *last*
  day**, so a plan whose last day carries no date has not ended and is
  `underway` rather than closed or unknown — ending on the last *dated* day
  would archive a half-dated plan mid-trip. And **the grace's real intake is not built**: capture only writes to
  today, so the window's door is the import sweep, and until that exists the
  rule sits at the write path (`CaptureFlow.turnTheDayOver`) rather than on a
  button. The plan is refused the same way: the paste box stays reachable on
  an archived trip, through the trip sheet's re-paste entry — it is also the
  only door to joining another one — and
  only `PasteFlow.accept` refuses, with the confirm screen showing the read in
  full and a sentence where the accept button was. The number itself is
  written twice and never three times — here and
  as `trip_grace_after_end()` in SQL, compared by `supabase/tests/rls_probe.py`.
- **The gate is one rule, written once.** `cairn_model`'s `GateState.decide`
  is it: the gate applies to the day being lived, and every day that has sealed
  is open to everyone on the trip whether they answered it or not
  (`docs/decisions/2026-08-22-grill-round-one.md` §1). `Trip.gateFor` answers
  with it for a real trip; `lib/app_state/day_gate.dart` answers with it for
  this one-phone slice, which has no roster to build a `Trip` from and so gates
  on `localMemberId` and on the photos still in the pool -- both are seams
  Phase 2 closes, and the second one has a trap the server already avoids with
  `day_unlocks` (deleting your photo must never re-shut a day you opened). The
  only other copy of the rule is `day_page_is_open` in SQL, and that one is
  deliberate (`docs/architecture.md`, invariant 2). A copy per surface is the
  thing to refuse in review. The Pool is its one live consumer today, because
  the gate withholds photographs and no other built surface draws one.
- Widget tests over the stack must open Drift with
  `closeStreamsSynchronously: true` or teardown hangs silently at 0% CPU —
  the header comment in `test/paste_confirm_flow_test.dart` explains the
  mechanism. Read it before writing any test that pumps the app. Since the
  container landed, every tab stays in the tree but the unselected ones are
  *offstage*: finders skip those by default, so a plain `find.byKey` sees
  only the tab you are standing on, and a tap only reaches it. A test that
  pumps `bootstrapApp` and then its own `ProviderScope` must key that scope
  (`UniqueKey`): Riverpod refuses to update a scope whose override count
  changed, and every new binding in `bootstrap.dart` changes it. Two more
  silent hangs, both at 0% CPU with no error: awaiting a drift *stream*
  (`watch().first`) inside `testWidgets` never completes under the faked
  clock -- read once instead (`AppDatabase.readPhotos`) -- and so does real
  file I/O, so a fake camera must write its frame synchronously. The same
  zone is why the import flow's extraction runner is injectable
  (`extractionRunnerProvider`): production wraps the pure extractor call in
  `Isolate.run`, and a real isolate inside `testWidgets` hangs silently, so
  every test overrides it with the direct call (`bootstrapApp(extraction:)`).
  A test that drives providers through a bare `ProviderContainer` instead has
  the opposite trap: **every provider is auto-dispose under Riverpod 3**, so an
  unlistened `StreamProvider` is disposed the moment `read` returns and its
  future never completes (a silent 30-second timeout), and an unlistened
  notifier forgets its state between two awaits. `container.listen(p, (_, _)
  {})` is what a widget does for free — `test/trip_ending_test.dart` shows the
  shape.
- Fixture-writing trap: a `Day 1 - Tokyo, 14 June 2027` header does *not*
  give the day a date (the whole tail becomes the place); only a date-shaped
  header (`Mon 14 June 2027 - Tokyo`, `3/11/2027 - Tokyo`) resolves
  `ParsedDay.date`.

## Backend (`supabase/`)

The backend is Supabase (Postgres: accounts, trip membership, photo index)
+ Cloudflare R2 (photo bytes). See `supabase/README.md` for the full model,
RLS rationale, free-tier limits, and setup steps -- it is the source of
truth, not this file.

Sharp edges worth knowing before touching this directory again:

- The backend is intentionally minimal: it holds the shared photo pool, trip
  membership, the shared trip clock, and the itinerary. The trail/stars/ping
  schedule are computed on the phone and must never move server-side without a
  deliberate decision to change that; storing a shared fact is not computing on
  the server (`docs/decisions/2026-08-22-grill-round-one.md` §2), which is what
  makes the itinerary's four tables in `0010_trip_itinerary.sql` legitimate and
  a server-side trail not.
- **The itinerary merge rule is written twice and never three times.** Last
  write wins, *per day*; the day is the atom, so a stop carries no clock of its
  own. Server half: `sync_trip_itinerary` in `0010_trip_itinerary.sql`, one
  call that is both push and pull because PostgREST has no client transaction.
  Phone half: `lib/repositories/itinerary_sync.dart`. Two things that look like
  details and are not -- `trip_itineraries.plan_revised_at` is a *shape*
  revision separate from any day's, because a deleted day leaves no row to
  carry an instant and "I dropped day 4" must be distinguishable from "I have
  never heard of day 4"; and the set-aside pocket has its own clock so that
  *emptying* it still carries a revision. `trip_roster` hands over `joined_at`
  and never a day number: turning an instant into a trip day needs the
  itinerary and the clock, and that arithmetic is the phone's.
- **Never inline a membership subquery in an RLS policy.** Every
  membership/ownership check goes through the `SECURITY DEFINER` helpers
  `is_trip_member` / `is_trip_starter` in `0004_trip_members.sql`, because a
  policy on `trip_members` that reads `trip_members` recurses infinitely and
  takes every membership-gated read in the schema down with it. For the same
  reason, never add `force row level security` to any table here -- it
  re-enables the recursion. Both directions are demonstrated by
  `supabase/tests/recursion_mechanism.py`.
- **The invite grammar exists twice, and the probe is what keeps the two
  copies honest.** A code is three spoken words, forgiving of order and of one
  letter per word, and it dies at the trip's close -- end date plus the grace,
  in the trip's own clock, never a stored `expires_at`. The phone's half
  is `cairn_model`'s `invite_code.dart` / `trip_close.dart`; the server's is
  `0005_trip_invites.sql`, and a code minted on one side is typed into the
  other, so they have to agree letter for letter. `tests/rls_probe.py` reads
  the Dart word list and the grace out of those files and compares them rather
  than trusting the copies to stay in step -- extend that check, never a third
  copy. Two traps in the SQL half: the edit distance is written out rather than
  taken from `fuzzystrmatch`, whose `levenshtein()` prices a swapped pair of
  letters at two and would refuse near-spellings the phone accepts; and
  uniqueness and lookup are both over `invite_code_key(code)`, the canonical
  spelling, never over the text as written.
- Migrations in `supabase/migrations/` are numbered and dependency-ordered.
  Only one forward reference remains, and it is irreducible: `0003_trips.sql`
  defers its own RLS policies to `0004_trip_members.sql`, because `trips` must
  exist before `trip_members` can reference it but the policies are written in
  terms of membership. Read that comment before reordering anything.
- **A hosted project exists and all ten migrations are applied to it**, and an
  ordinary build points at it (`supabase/README.md` is the authority on the
  defines and on what the hosted project has and has not actually done). The
  adversarial checks still run somewhere else and must: `supabase/tests/`
  applies the schema to a throwaway Postgres 17 and drives it as PostgREST
  does, because only one account has ever touched the hosted project, so no RLS
  *refusal* has ever been observed there -- only the permitted paths. Run
  `python3 supabase/tests/rls_probe.py` (see that directory's README) after any
  change to a policy -- RLS refuses by filtering to zero rows rather than
  raising, so a change that silently opens or closes access looks identical to
  one that works until something actually queries it.

## Packages

- `packages/itinerary_parser/` — pure-Dart package (no Flutter dependency) that parses pasted free-text trip plans into structured days/stops. Test with `dart test` from inside that directory; see its `README.md` for the public API, confidence semantics, and documented parsing limitations.
- `packages/trip_moments/` — pure-Dart, offline notification-timing library: it deals each person on a trip exactly one ping a day, as a collision-free permutation of slots over the party, reshuffled daily. See its `README.md` for the derivation and why it needs no server. Test with `dart test` from inside that directory.
  - **The party is an input, not an afterthought.** Each device derives the whole day's assignment for everyone, which is what makes the schedule collision-free offline. A derivation that hashed only the local member id (as an earlier version did) permits two people to land on the same minute and permits the party to cluster.
  - It derives its instants with multiplication and addition, not bitwise shifts, deliberately: Dart's `int` bitwise operators are 32-bit when compiled to JavaScript, so the shift form silently diverges on web while the arithmetic form is exact on every backend. `test/golden_values_test.dart` pins this -- do not "simplify" the arithmetic back to shifts. `tool/print_goldens.dart` documents the four-command VM-vs-dart2js diff that verifies it.
- `packages/cairn_model/` — pure-Dart domain model: the one vocabulary (trip, trip clock, day, stop, member, photo reference, gate) the database layer, the app's state layer and the interface are all written against. Test with `dart test` from inside that directory; its `README.md` names the decision file behind each non-obvious choice.
  - The trip's whole permission model is `src/trip_powers.dart`, as pure
    functions over `(member, startedBy, members)`. `Trip` delegates to it, and
    so does the app: the rules live in one place because two copies drift.
    Also here: `InviteCode` (two words and a number, forgiving of order and of
    one edit, over a vocabulary whose words are pairwise three edits apart) and
    `tripClosesAt` (trip end + `graceAfterATrip`; the book's rule is not this
    one and never expires) and `tripStandingAt`, the one place a trip's ending
    is decided. `TripId.mint` is the package's one exception
    to "it invents nothing": it *formats* sixteen bytes a caller drew, the same
    division `InviteCode.draw` makes, so the package still has no randomness.
  - A day's clock is fixed where the day *starts* and never moves, so a photo taken after an afternoon border crossing still reads at the hour that day was on. `TripDay.sequence`'s per-day clock overrides mirror `photo_day_assignment`'s `timeZoneOverridesByDay` deliberately -- change one and the other has to follow.
- `packages/photo_day_assignment/` — pure-Dart package that decides which day of a trip a photo belongs to, using GPS-derived timezone over EXIF timestamps where possible (see its `README.md` for the full degradation ladder). Test with `dart test` from inside that directory.
  - It calls `timezone_finder`'s `findLocation(longitude, latitude)` -- longitude first, the opposite of the usual lat/lng convention and a standing trap when wiring up callers.
- `packages/plan_extraction/` — pure-Dart contract for the file-import feature: **bytes in, honest lines of plan text out**. `PickedBytes` / sealed `ExtractionResult` / `PlanTextExtractor` are the one shape every import slice codes against; the registry is a `const` list in `lib/app_state/import_flow.dart` and a new format is one extractor plus one line there (the picker filter and the pill's format list derive from it, so nothing else edits). Import **fills the paste box and never auto-parses** — `PasteFlow.parse()` needs zero new state for any format, which is what keeps this feature out of the merge guard's blast radius; over a running trip an imported file composes with re-paste merge semantics for free. Routing probes magic bytes first (`matches`) and uses the extension only as tiebreak — and `matches` runs on the UI thread, before the isolate hop, so it must sniff a bounded prefix and never repeat `extract`'s work over a whole file. OCR is deliberately not an extractor: recognition is a platform call, and it lives behind `TextRecognitionEdge` (see the app bullet on it). Test with `dart test`; fixtures under `test/fixtures/` are generated by `tool/make_fixtures.dart` and `tool/make_pdf_fixtures.dart` (the PDF ones need Chrome, Ghostscript and the network, and are not byte-deterministic — read the extractor's output diff, not the bytes). Docx tables are read **one line per table row**, cells joined in column order (a row down to one filled cell keeps its paragraphs apart, because a single-column table is layout): `[08:30 | Fushimi Inari]` is one stop to a reader and must be one stop in the box. That is the row model's rule reached the other way round — a Word table carries no cell typing, so `plan_rows.dart` could never pair its cells, and teaching it a time grammar over *text* cells would change what xlsx and csv already do. Xlsx/csv (slice C) share one row model, `plan_rows.dart`: structured cells lift into `PlanRow`s (heuristic v1 — a date-typed column drives the dialect, `Mon 14 June 2027 - Tokyo` / `- HH:MM stop`; no date column falls back to faithful row-major lines, never worse than pasting the same table as text) and one renderer says them back as plan text. **A sheet's own furniture is not plan**: a first row that names the date column (`Date`/`Day`/`When`) in short digit-free text, directly above a row that really carries a date there, is read as column labels and dropped rather than surfaced as lines nobody could place, and a column those labels call a place folds into the day header (`Sat 14 September 2027 - Zermatt`) instead of standing as a bare place-name stop under every day. Nothing wider is read out of a label — widening this into schema inference is the thing to refuse in review — and a sheet whose first row is real data fails the very first test (its date cell is typed, not text), so a real row is never eaten. The renderer cannot import `lib/logic/plan_text.dart` (an app file), so it carries its own tiny copy — **`plan_rows_round_trip_test.dart` is what keeps the two honest**, feeding every shape the renderer emits back through the real `parseItinerary` (a dev-only path dependency on `itinerary_parser`, never a runtime one). Three library-version traps worth knowing before touching this package again: `archive` 3.6.1's `Archive` class *is* `Iterable<ArchiveFile>` (no `.entries` getter, and `ArchiveFile(name, size, content)` is the constructor, not a `.bytes()` factory); `csv` 8.0.0 dropped `CsvToListConverter` for `Csv`/`CsvDecoder` (`const CsvDecoder().convert(text)`, fields come back as strings unless `dynamicTyping: true`); and `excel` 4.0.6's `CellValue` switch must handle `DateTimeCellValue` alongside `DateCellValue` or the switch isn't exhaustive.
  - **PDF is the one extractor that is not synchronous, and the contract says
    why.** `extract` returns `FutureOr<ExtractionResult>`: PDFium is not
    re-entrant, so `pdfrx_engine` serializes every call through a background
    worker isolate and offers no synchronous entry point. Two traps sit behind
    that. `return await`, never a bare `return future;` inside the
    `try`/`finally` — the `finally` runs at the `return`, disposing the
    document while the pages are still loading, and the read comes back with
    page one and every other page empty (silently). And **the worker outlives
    the call unless it is stopped**, which strands an isolate per import under
    production's `Isolate.run`; `PdfExtractor` stops it in the `finally`, and
    a test asserts two reads in one process both work. And **the read is
    bounded** (`pdfEngineTimeout`): a PDFium that cannot be loaded throws
    *inside* the worker isolate, so the awaited future never resolves at all
    — the import pill would sit on "Reading …" forever. Past the bound the
    read returns a typed refusal that names the engine. Its cleanup is
    unawaited and only issued when a document was opened, because
    `stopBackgroundWorker` is itself a round trip through the engine that
    just failed to answer (it spawns a fresh worker and destroys the
    library), so awaiting it re-hangs the caller and issuing it blindly can
    crash a later read.
  - **`archive` is pinned to ^3 by an override, and both pubspecs carry it.**
    `pdfrx_engine` asks for `archive` ^4 (through `image`) while `excel` --
    the only maintained xlsx reader -- is pinned to ^3 and does not compile
    against ^4, so one app cannot read both a spreadsheet and a PDF without
    holding `archive` at ^3. Nothing on the PDF path touches the archive API,
    which is why it compiles. The override lives in *both*
    `packages/plan_extraction/pubspec.yaml` (for `dart test`) and the root
    `pubspec.yaml` (for the app), because an override inside a path
    dependency is ignored.
  - **PDFium reaches the phone by a different road than it reaches
    `dart test`.** `pdfium_dart`'s build hook returns without emitting
    anything when the target is iOS, so the app depends on `pdfium_flutter`
    purely to link the XCFramework — nothing in `lib/` imports it, no test
    fails without it, and what fails without it is reading a PDF on a device.
    Check `Runner.app/Frameworks/PDFium.framework` after a build. On a dev
    machine the same hook downloads a host PDFium once, so a fresh checkout's
    first `dart test` needs the network (the package README has both).
  - **The page cleanup strips only provably repeated furniture**
    (`lib/src/text_cleanup.dart`): a phrase at a page edge on ≥3 pages and on
    ≥half of them, bare numbers no larger than the page count, and the
    Wanderlog print shapes the plan names. It **preserves line order and never
    joins lines** — a wrongly joined line corrupts a stop silently, an
    unjoined one is two stops the person can fix in the box. Two guards are
    load-bearing and both were bugs first: the furniture key is blind to
    digits, so a line must read as a *phrase* before it can be furniture or a
    plan printed one day per page loses every `Day N` header; and a bare
    number is only a page number if a page could carry it, or the garbled
    fixture's standalone `1900` reads as folio 1900. **The one exception to
    provable repetition is the one page on which repetition cannot be proved**:
    a single-page export — the commonest print there is — carries the browser's
    header and footer exactly once, so on a lone page an edge line that is
    *nothing but* a web address (folio or not) is furniture on its own. A lone
    edge line that is *nothing but* a numeric date-and-clock stamp is furniture
    only when that same page also carries the web-address line — a bare
    date-and-time can be a real check-in or departure stub, and the browser's
    own footer is the corroborating evidence that it is a printed header
    instead, so the stamp is never stripped by its shape alone. Both shapes are
    anchored end to end deliberately, because a line that merely mentions an
    address is somebody's stop, a lone date is the header the parser most
    needs, and a dashed ISO `2027-06-14 09:00` is a plan's own line far more
    often than a browser's. The exception reaches a one-page document only;
    multi-page prints are still judged by repetition alone.

## Design and decisions

See `docs/decisions/` for the authoritative record of why the app is shaped the way it is, and `docs/design/` for the interface and design system. The central decision is recorded in `docs/decisions/2026-08-22-the-moment.md`: the daily ping is scattered per person rather than simultaneous, because a simultaneous buzz adds no value when everyone is co-located and instead prompts people to photograph themselves rather than each other.

`docs/architecture.md` is the dependency map: every node of the app (built or not), what each knows about, and what breaks if it changes -- read it before moving a responsibility between layers. `docs/architecture.html` is the same map as a single self-contained page for visual reading.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
