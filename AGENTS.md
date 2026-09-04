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
- Schema is at v11. A test that stands up an *old* schema by winding
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
  (the repository says why). Two more residents are the tap-to-Maps
  rules. `maps_handoff.dart` is the whole display-and-URL rule, written
  once: the query (`searchText, area`, or bare `searchText` when there is no
  area), the three keyless app URLs (Google/Apple/Waze), the meal-label
  split, the placeholder test, the places on a line and the badge threshold.
  A second copy of any of them is the thing to refuse in review — the
  screens compose nothing. `parsed_areas.dart` is the only mapping from the
  parser's seven provenances to the domain's three
  (`travellerOwn` > `human` > `parser`, which is also the priority order),
  and both `paste_flow.dart` and `repaste_merge.dart` go through it.
  `calendar_days.dart` is the one spelling of "n days later" over a
  date-only value (`calendarPlusDays`, `DateTime` component arithmetic —
  never `add(Duration(days: n))`, which lands a day early across a DST
  fall-back); every app-side date-chip and date-fill arithmetic goes
  through it. `area_edit.dart` is main's phase-1 scaffolding and is still called from
  nowhere: the frontend resolves a running area onto every stop's own
  `area` instead of re-deriving it from headings, and correcting a run
  rewrites each stop in it, so nothing needs the re-derivation. Delete it or
  wire it, but do not grow a third rule beside it.
- **A stop's area is a fact about the stop, and the person outranks the
  parser.** Schema v9 stores `kind` / `area_text` / `area_source` on
  `itinerary_stops`; `cairn_model`'s `Stop` carries them; the priority is the
  traveller's own words in the plan (`travellerOwn`) over a correction made
  on the phone (`human`) over anything the parser inferred (`parser`), and
  nothing above `parsed_areas.dart` re-decides it. Four things worth knowing.
  A correction **rides the sync cargo** like any other edit — it writes
  through `TripRepository.setStopAreas`, which stamps the day's
  `revisedAtUtcIso` and nothing else, because the day is the merge atom and
  the plan's *shape* did not change. It **outlives a re-paste**:
  `mergeRepaste` carries human areas plan-wide by the stop's own text, and
  will not overwrite an area the new text itself declares. A pull from a
  server that has not had migrations `0012`/`0013` applied must **not** null the
  local areas — `RemoteStop.carriesAreas` is false when the row has no
  `area_text` key at all, which means "does not know", never "says none";
  deleting that distinction silently erases every correction on the phone.
  And the handoff is **always a text search** — a query, never a stored pin,
  never a coordinate, and never an API key: every URL is a keyless https
  universal link composed by `maps_handoff.dart` and opened through
  `LinkOpenerEdge`, which is what lets every widget test assert the URL
  without a browser.
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
  it, `PasteFlow.accept` forgets it, a fresh import replaces it — though
  over a box already holding different text the paste screen asks one
  question first, and declining keeps the text and writes no draft
  (`test/import_replace_ask_test.dart`). The restore
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
  them shared.** `lib/repositories/itinerary_sync.dart` and its deliberate
  sibling `photo_sync.dart` (the outbox bullet, below) are the only two files
  holding both backends at once. The itinerary half pushes this phone's plan, applies what the merge
  hands back, and replaces the roster wholesale (RLS means the server only
  answers a member, so the roster it returns necessarily contains the caller;
  a merge that kept a local row would resurrect somebody who left and deal
  them a ping). It reports a *standing*, never an error — dormant, no trip,
  awaiting the trip row, offline, refused, archived, synced — and offline
  means the local copy is untouched and authoritative. The apply is itself a
  merge: `AppDatabase.applyRemoteItinerary` (its doc comment is the
  authority) re-reads the plan inside its own transaction so an edit made
  during the round trip wins by its own clock, and a day deleted mid-flight
  is defended by a durable tombstone (`itinerary_day_tombstones`, schema v11)
  instead of being resurrected by the answer's older snapshot. Two rules to keep: applying a merge must
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
  late is stored for the next one, with one narrow exception and one repair,
  both `bootstrap.dart`'s (its docs are the authority): accepting a plan may
  adopt a late-landing account, bounded, only while no trip exists yet
  (`lateAccountResolverProvider`), and a roster a previous launch left under
  the stand-in is healed to the account on the next launch
  (`MembershipStore.adoptAccountIdentity`,
  `test/stand_in_identity_test.dart`). `flutter test` never reaches out: every widget test binds
  `NoSession`, and the live check is
  `flutter test test/hosted_smoke_test.dart --dart-define=CAIRN_HOSTED_SMOKE=true`.
  **A green suite is still no evidence the hosted project behaves** — that is
  what that one test is for, and `supabase/README.md` is the authority on the
  defines, on why `CAIRN_TRIP_TIMEZONE` is an override rather than a gate, and
  on what the hosted project has and has not actually done.
- **The plan really leaves the phone on an ordinary build, and the app says
  when it has not.** Both halves are
  `docs/decisions/2026-08-27-the-trip-clock-is-the-phones.md`, and both were
  one defect: `CAIRN_TRIP_TIMEZONE` used to be a gate with no default, so no
  ordinary build could ever create the shared `trips` row — silently, forever.
  The clock is now the phone's own IANA name
  (`lib/app_state/device_time_zone.dart` over the hand-written
  `cairn/time_zone` channel, `ios/Runner/DeviceTimeZone.swift`), assembled in
  `bootstrap.dart`'s `tripRowFor`; the define survives only to pin a
  destination's zone. A *name*, never the device's UTC offset — `Etc/GMT±N`
  has no daylight saving and cannot spell a half-hour zone, and
  `trips.timezone` is checked against `pg_timezone_names` at write time.
  Reintroducing an offset-derived zone is the thing to refuse in review.
  Three rules hold this together. **An unnamed trip still publishes**, as
  `unnamedTripPlaceholder`; a clearing rename uses the same non-null wire word
  and maps it back to null locally. Names now carry their own
  `name_revised_at` clock through `sync_trip_name`, and any current member may
  rename while the starter-only protection over every other trip-row column
  stays intact (`0014_member_trip_rename.sql`) — bounded on both sides:
  `guard_member_trip_rename` is an *allowlist* over `to_jsonb(new)`, so a
  column a later migration adds to `trips` is refused rather than silently
  handed to every member, and a closed trip refuses a rename from anybody,
  starter included, which is the read-only record rule written twice like
  every other write path. That second refusal is keyed on the *rename* and
  sits above the trigger's starter early-return, so it holds on a bare
  `PATCH` round `sync_trip_name` and still takes nothing else off
  `trips_update_starter`. **One gate remains and only one**:
  a plan with no resolved first or last date, because those columns are
  `not null` and inventing a date is the guess the paste flow exists to
  refuse. And **`TripSync.standings` is the only thing above the seam that
  knows the sync exists** — a read-only stream, bound by `bootstrapApp`
  (`sharing:` in tests), turned into words *once* by `planSharingFor` in
  `trip_settings.dart` and drawn twice: a short mark on the Trail, the full
  sentence in the trip sheet. `SyncOutcome.detail` is for a log and is never
  rendered; a second derivation of those words, or a technical string reaching
  a person, is the thing to refuse in review.
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
- **The house skin's tokens are written once, in
  `lib/screens/house_style.dart`** — a transcription of
  `docs/design/README.md`'s House system block; a second spelling of any
  house colour is the thing to refuse in review. The container's tab bar is
  skinned to frame 5b (the drawn "tab bar of record" in
  `docs/design/2026-08-22-handoff.zip`), minus the Book tab and camera
  shutter it drew: the captain kept the built three-tab Today-Trail-Pool
  shape (2026-08-28), and a Book tab waits for a built Book — absent, not
  disabled, per the container's own comment. The bar's icons are 2px
  round-capped stroke paths on a 24 grid drawn in `trip_shell.dart` (Trail
  and Pool trace 5b's SVGs; Today's flag is the same vocabulary), not
  Material glyphs. Atkinson Hyperlegible (OFL) is bundled in
  `assets/fonts/`; Young Serif is not yet — nothing built sets display
  type. `test/tab_bar_style_test.dart` pins the tokens and states.
- **Capture is a route, not a tab.** The only way in is the day page's one
  call to action, and only an open or a late window offers it. The camera is
  behind `CameraSource` (`lib/app_state/camera_source.dart`): a real camera on
  a device, a *generated* PNG anywhere without one — which is what
  makes the flow walkable on the Simulator, and also means a green simulator
  run is no evidence the camera path works. Judge that on a device only.
  `NSCameraUsageDescription` is in `ios/Runner/Info.plist`; audio is off, so
  no microphone string is needed. The ping's schedule is real
  (`trip_moments`) but dealt for a stub party of one, and `NotificationEdge`
  is not implemented against iOS -- nothing actually buzzes yet.
- **One `takeOne()` is one capture *event*: the back frame, then the front
  one.** Sequential and never simultaneous — the spike settled that
  (`learning/dual-camera-spike/`), and `BackCameraSource` opens and disposes
  one controller per lens through `CameraCaptureEdge`, so two lenses are
  never live at once. `CapturedFrame.path` still *is* `backPath`, deliberately,
  so the single-frame callers above the seam keep working; **the source
  composes nothing** — it delivers two files, `TheBreath.frontFramePath`
  carries the front one up, and the capture review's inset
  (`capture_screen.dart`, keys `capture-back-frame` / `capture-front-frame`)
  is the composition's one home. A discarded attempt discards *both* frames
  (`onceMore`, `abandon`); the kept photograph is still the back frame alone —
  storing the front one is a later slice. Three refusals are load-bearing and
  all three are `CameraRefused`: no
  back camera, no *front* camera, and a failure of the second shot — and the
  last one **discards the back file it already copied**, because a half-taken
  event must leave no orphan on disk. `CameraCaptureEdge` and the injectable
  directory exist for exactly that: `test/camera_source_test.dart` proves the
  ordering, the frame identity and the cleanup against a fake, which is
  evidence about the sequencing rules and still none at all about a real
  camera.
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
  **The phone mints the photo's id, and it must be spelled the way `photos.id`
  reads back** -- one lower-case hyphenated v4 uuid, drawn by `mintPhotoId`
  and formatted by `PhotoId.mint`, the same split `mintTripId` / `TripId.mint`
  uses (one formatter, `_uuidFrom`, serves both). It used to emit thirty-two
  undashed hex characters, which no `uuid` column accepts and which
  `r2-upload-url` refuses outright -- a seam whose two halves had simply never
  been run against each other. `test/photo_id_format_test.dart` reads the
  function's own `UUID_RE` out of its source and compares, rather than keeping
  a third copy.
- **A kept photograph durably leaves the phone: bytes first, row second,
  never the reverse.** `lib/repositories/photo_sync.dart` (whose header holds
  the full rationale) drives the `photo_outbox` table (schema v8) that
  `PhotoStore.keep` fills in the same transaction as the photo row; the
  durable states — `queued`, `uploaded`, `caption`, `refused` — are exactly
  the places a kill can leave you, and `test/photo_outbox_test.dart` replays
  each. Four rules to keep. The driver watches `photo_outbox` and **never
  `photos`**, so the pull (unbuilt) can apply rows without re-triggering the
  push. An upload ticket is minted per attempt, never persisted, and **never
  re-minted once a PUT has returned 200** — past that line the `photos` row
  may land any moment and a row's existence is what makes `r2-upload-url`
  refuse the id. `SharedFactsUnavailable` stops the whole pass with no
  per-item penalty, `UploadTicketRejected` retries with backoff — an
  `uploaded` or `caption` row keeps its state through `delayOutboxRetry`, so
  a retryable failure after the PUT never re-mints a ticket over durable
  bytes (attempts never terminate; the server's close-plus-grace is the real
  deadline, relayed as `refused`), and `SharedFactsRefused` is terminal but
  minted only on the upload function's own verdicts (403, 409, a validation
  400) — any other 4xx retries, and the v11 migration re-queues rows an
  older client's broader classification left `refused`. And uploading
  never requires a dated day — the photo's home is its day *number*, so no
  form ever stands in front of the camera; a plan nobody dated still
  publishes, `trip_day` simply null. The caption is a single-owner field
  (latest write by the contributor wins, no conflict machinery): it rides
  the record when still pending, else `PhotoStore.writeWord` queues one
  `caption` push, and `settleOutboxPushed` converts rather than deletes when
  the word moved mid-flight. Today is
  `DayPage(date:)` handed today's date; the Trail opens the same widget for
  every node, through `DayPage.planDay(n)`. Two ways in, one screen: the
  number is the only way to reach a day whose date is still open, since
  nothing here guesses a date. A second day surface is the thing to refuse in
  review. `todayProvider` derives today from the *device* date because no
  trip clock is stored yet — it is the one place that changes when one is,
  and `bootstrapApp(today:)` pins it in tests.
- **The app's clock is a function to ask, and the app root is the only thing
  that makes anybody ask again.** `nowProvider`
  (`lib/app_state/ping_schedule.dart`) is a `Provider<Clock>`, so every
  consumer calls it — `ref.watch(nowProvider)()` — and gets the wall clock as
  it is at the asking. It was a `Provider<DateTime>` until 2026-09-03, and
  that cached a single reading for the life of the launch: every window,
  every trip ending and every invite standing was decided against a clock
  that had stopped when the app started. The type change is the easy half.
  **The trap is that the clock is live and the verdicts drawn from it are
  not** — a provider that asked once keeps that answer until something
  invalidates it, and watching the clock invalidates nothing, because the
  closure's identity never changes. So `CairnApp` (`lib/app.dart`) is the one
  place invalidation happens: `ref.invalidate(nowProvider)` on
  `AppLifecycleState.resumed`, and again every `clockRefresh` while the app
  is in front, because no lifecycle event fires for a minute that arrives
  while you are already looking at the trip. A surface that grows a refresh
  of its own is the thing to refuse in review, and the capture screen's
  second hand is the one deliberate exception — it is there for the *grain*,
  a two-minute window counted down to the second, not for the freshness.
  Tests pin the clock with `bootstrapApp(now:)`, composed through
  `pinnedClock(from:, moving:)`: `now:` alone is a clock that has stopped,
  which is what almost every test wants, and a test that walks a window down
  hands in `elapsed:` as well — a `StartElapsed` it drives off the faked
  clock, refused without `now:` because an interval added to a base that
  already moves would count twice.
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
- **Editing a migration the hosted project has already recorded changes
  nothing on the hosted project, and nothing says so.** `db push` skips a
  version already in `supabase_migrations.schema_migrations`, and that row
  keeps the statements as they were when it ran — hosted's `0014` row still
  holds the first version's eleven, none mentioning `trip_closes_at`. So an
  amendment is either the next numbered file (the direction `0011` took
  rather than patching `0007`) or a deliberate explicit patch over an
  `--db-url`, written down in `supabase/README.md`'s Verification section.
  `0014` is the one time this repo has taken the second road; a green
  `db push` is not evidence the hosted bodies match the files.
- **A hosted project exists and migrations `0001`-`0010`, `0012` and `0014`
  are applied to it** (`0012`, the tap-to-Maps area columns, on 2026-08-31;
  `0014`, the flat member rename, on 2026-09-01, re-applied the same day —
  function, trigger and policy half only — once review added its closed-trip
  refusal and allowlist guard, so the hosted bodies match the repo — patched
  in place rather than re-pushed, per the bullet above;
  `0011`, the photo transport delta, `0013`, which teaches
  `sync_trip_itinerary` those columns, and `0015`, the day-gate and tenancy
  hardening, are written and locally probed but
  applied nowhere else — until `0013` runs, an area correction is stripped on
  push and absent on pull, so it never leaves the phone that made it), and an
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
- **Both edge functions are split so that they can be tested without being
  deployed, and nothing here has ever been deployed.** In each of
  `supabase/functions/r2-upload-url/` and `r2-download-url/`, `handler.ts`
  holds every decision behind injected dependencies and **imports nothing
  remote**; `index.ts` builds the real ones from `supabase-js`, `aws4fetch` and
  `Deno.env`. That is the only reason their refusals can be exercised at all —
  `deno test handler_test.ts`, no network, no secrets — and
  `deno check --no-remote handler.ts` in CI (a matrix leg per function) is what
  keeps the split honest. Teaching a handler to import a client directly is the
  thing to refuse in review. What no test here can reach: whether the PostgREST
  queries in either `index.ts` really answer the questions the handler asks,
  and whether R2 honours a signed `content-length` or an `X-Amz-Expires`. All
  of that needs the deployment nobody has made.
- **A `photos` row is what claims an original, and a claimed original is
  nobody's to overwrite.** The function refuses to sign a photo id a row
  already holds — flatly, its own contributor included, because an original is
  immutable and that immutability is what lets a phone cache bytes forever.
  Without it any member could sign a PUT over any other member's photograph and
  leave the row untouched, which is invisible to every RLS policy (RLS protects
  the row; nothing in Postgres protects the object). The refusal costs the
  retry path nothing **only because the ordering is bytes-first-row-second** —
  an outbox that inserted the row first would refuse its own retry. The two
  probe checks under *"a co-member can read what an upload URL is minted from"*
  pin the premise that a photo id is not a secret.
- **A row may only point at its own object.** `photos_object_key_own_prefix_check` /
  `photos_thumbnail_key_own_prefix_check` (`0011`, tightened by `0015`) bound
  the *first* claim to
  `lower(key) like 'trips/' || trip_id || '/photos/' || id || '/%'`, and the
  `photos_lock_object_keys` trigger (`0011`) stops either key changing afterwards.
  Neither is sufficient alone — a trigger has no old row on INSERT, and a
  locked key that was free to be anything is a permanent theft rather than a
  revocable one. This is what `r2-download-url`'s promise rests on: it signs
  the row's own stored key, so what may be *stored* is the whole invariant, and
  before the check a member could claim somebody else's `day_pages` key (a
  different table, a different unique index) and have it signed faithfully.
  Three things not to undo. The comparison is **case-insensitive on purpose**:
  both functions' `UUID_RE` carries the `i` flag, so a strict check would take
  the PUT and then refuse the row, stranding an object behind a retry that
  re-mints the same rejected key forever. Past the prefix, `0015` refuses
  traversal and empty segments, backslashes, percent escapes and URL
  delimiters — a `.../<id>/../` key passed the prefix check and was normalised
  outside the photo's folder before signing (`supabase/README.md` owns the
  detail); the rest of the naming is still `objectKeyFor`'s business.
  And the client must **mint the photo id itself** — a key containing the row's
  own id cannot be written by a client waiting on `gen_random_uuid()`.
  `day_pages.r2_object_key` is still unconstrained deliberately: nothing signs
  a day-page key yet (its `trip_id` is locked by `0015`'s
  `day_pages_lock_trip_id` trigger, though).
- **The download function signs the row's key and nothing else, and its five
  properties are load-bearing in order.** `r2-download-url` takes a trip and up
  to 64 photo ids and answers a verdict per id. (1) **The row decides**: every
  id is looked up server-side and only that row's own stored `r2_object_key` is
  signed — a trip, a day, a key or a uid in the body is not read at all, and R2
  keys are derivable from ids the sync already hands out, so a function that
  signed a key it was handed would leak every trip. (2) **The stored key is
  validated again before signing** (`isSafePhotoObjectKey`): it must name the
  row's own folder in literal, non-empty, non-traversing segments, so a
  malformed legacy row is refused before the gate is asked — the last wall in
  front of the signer, deliberately repeating `0015`'s constraint. (3)
  **Authorisation is
  inherited, not re-decided**: the row is read *as the caller* through RLS, so
  `may_read_trip_photos` answers and no second copy of the rule exists in
  TypeScript. (4) **The gate is asked before anything is signed**, per id,
  inside the loop. (5) **A refusal carries no reason** — unreadable,
  nonexistent, malformed and gated are one answer, because a reason is an
  oracle for walking the corpus. A failed read and an unanswerable gate both
  refuse rather than sign. The shape is settled (2026-08-28): a time-limited
  signed link, **15 minutes**, no Worker proxy and no R2 binding ever. The
  signing is deliberately asymmetric with the PUT — no `allHeaders: true`,
  because a GET declares nothing to bind.
- **The gate keys on a day *number*, and an undated day is open.** `0011`
  re-keyed `photos`, `day_unlocks` and `day_page_is_open` off
  `(trip_id, day_number)`, resolving the calendar through
  `trip_itinerary_days`; `photos.trip_day` and `day_unlocks.day_date` are
  retained as never-read provenance. A day the itinerary cannot date reads as
  **walked, and so open**, which is `lib/app_state/day_gate.dart`'s rule said
  in SQL — the rule still exists exactly twice. The consequence is real and
  stated rather than buried: a trip whose itinerary has not reached the server
  has no shut days at all. Failing shut instead would shut a live trip against
  the people who took the photographs. Uploading never requires a day to have a
  date, and contributing to an undated day opens it (`record_day_unlock` has no
  `trip_day is not null` guard any more — that guard was the hole). Since
  `0015` the permissive default cannot be forged: an unlock follows a moved
  photograph (deleting one still never re-locks its day), and re-dating or
  un-dating a still current or future day holds the gate shut until the old
  date passes (`day_gate_date_guards`) — `supabase/README.md`'s gate section
  owns the detail.
- **Every photograph read goes through one seat.** `may_read_trip_photos`
  (`0011`) today answers exactly `is_trip_member`, and both the `photos` SELECT
  policy and `r2-download-url` go through it. It exists so that when leaving
  and being removed land, changing what a leaver may still see is a change to
  one function body. Adding a second path to a photograph is the thing to
  refuse in review.
- **A tombstone is a candidate, not an instruction.** Deleting a `photos` row
  writes its R2 keys to `photo_tombstones` (`0011`), which has RLS on and **no
  policies at all** and deliberately **no foreign key on `trip_id`** — a
  cascading FK would delete the very tombstones the cascade just wrote. A
  sweeper must re-check that no `photos` row claims a key before deleting the
  object; nothing sweeps yet.
- **`tool/photo_pipe_probe.dart` is the third evidence layer, and it has never
  been run.** Three real accounts — contributor, co-member, stranger — against
  a *scratch* project and bucket, which is the only place an RLS refusal is
  observable over the real stack (the local probe has no GoTrue or PostgREST;
  the hosted smoke has one account). It is committed, not throwaway, and grows
  a section per slice. It refuses to start against `SharedFactsConfig`'s hosted
  URL or key — a guard in code, not in prose. Never CI: it needs a network, a
  project and secrets. Run it by hand and paste its transcript into the PR.
- **A `language sql` function body is validated when the function is created;
  a `plpgsql` one is not.** This is what makes a later migration unable to drop
  a column an earlier `create or replace function` reads: the repo's probe
  applies every migration **twice**, and the second pass re-runs `0007`'s
  `day_page_is_open` against a schema `0011` has already changed. That is why
  `0011` retains `day_unlocks.day_date` as a nullable never-read column rather
  than patching `0007` — piling `if exists` guards onto an already-applied
  migration is the wrong direction, and the retention is symmetric with keeping
  `photos.trip_day`.
- **A presigned PUT bounds nothing unless the headers are signed.** aws4fetch
  leaves `content-type` and `content-length` out of the signature by default
  (its `UNSIGNABLE_HEADERS`), so the content-type allowlist was advisory and
  the object size unbounded. `allHeaders: true` in `index.ts` is what puts both
  in `X-Amz-SignedHeaders` and gives the 64 MiB ceiling teeth; deleting it
  looks harmless and silently removes both bounds.

## Packages

- `packages/itinerary_parser/` — pure-Dart package (no Flutter dependency) that parses pasted free-text trip plans into structured days/stops. Test with `dart test` from inside that directory; see its `README.md` for the public API, confidence semantics, and documented parsing limitations.
  - **The area gazetteer is a validator, and `null` is a supported mode
    forever.** `parseItinerary(gazetteer:)` is phase 2 of tap-to-Maps: given
    one, an area drawn from a *vocabulary run* must also be a real place name
    before it may be attached, which is what kills the menu words a run alone
    admits ('UNAGI', 'UDON'); the traveller's own in-tail wording is trusted
    unvalidated, because it is a statement rather than an inference. A
    gazetteer is also positive evidence in exactly two narrow rules — unique
    stop-line self-evidence beats the running heading, and a gazetteer-known
    destination on a wrapped train-route continuation may set it — stated in
    the package README's gazetteer section and pinned by
    `test/area_rule_test.dart`; a third rule needs the same measurement bar.
    Given none, the extractor is phase-1 exactly — the C7t floors in
    `test/area_ground_truth_test.dart` are pinned **without** a gazetteer and
    must stay that way, and the C10 floors beside them are the same corpus
    scored **with** the committed assets. Four things worth knowing before
    touching it. The package **never reads a file or an asset** —
    `SortedListAreaGazetteer.fromAssetTexts` takes text somebody else
    inflated, which is what keeps it dependency-free. The assets are built by
    `tool/build_area_gazetteer.dart` from GeoNames dumps (~80 MB per country,
    downloaded by hand, never committed; only the ~0.4 MB of built asset is),
    and **every rule in that builder is a measured one** — the feature-code
    set, the name-columns-only choice (alternate names measurably inject
    junk), and the hamlet filter (drop plain-settlement P rows under 500
    population; keep PPLX, PPLA*, PPLC and all class A regardless), so
    changing any of them is a re-measurement, not a tidy-up. Both sides
    normalise through this package's own `areaTokens`, and the asset was
    frozen against Python's NFD in the measurement lab, so
    `area_words.dart`'s decomposition map must spell the same macrons,
    breves and carons the dumps carry — a mismatch there builds a name one
    way, looks it up another, and silently never matches. And **when it
    loads is the decision**: `lib/app_state/area_gazetteer_loader.dart`
    reads it on import only, off the UI thread through
    `gazetteerRunnerProvider` (the `extractionRunnerProvider` pattern —
    `Isolate.run` in the app, an injected direct call in tests, because a
    real isolate under the fake clock hangs silently), once per launch,
    never at launch and never on the day/trail path. Every failure there is
    swallowed on purpose: a missing or corrupt asset leaves the gazetteer
    null, which is a plan read the phase-1 way, never a failed import.
    `test/area_gazetteer_test.dart` pins all of that, because every wrong
    answer to "when" is silent.
  - **The bare place-name day header is script-agnostic, and its narrowness is
    bought twice.** `looksLikeProperNounHeader` (`src/line_classifier.dart`)
    tested `^[A-Z][A-Za-z'.]*$` until 2026-08-30, so `München`, `Αθήνα`,
    `Москва` and `京都` were not headers at all: `ParsedDay.place` came back
    null for every day of the trip and nothing reported it. The rule now is a
    word is either **cased** (opens `\p{Lu}`/`\p{Lt}`, tail any letter, mark,
    `'` or `.` — so `KYOTO` and a decomposed `Zürich` are one word each) or
    **caseless** (all `\p{Lo}`, the letters that have no capital to demand:
    CJK, kana, hangul, Thai, Arabic, Hebrew, Indic). All the regexes carry
    `unicode: true`, which is what makes the property escapes work and makes
    the length bounds count code points rather than UTF-16 units. Two bounds
    replace the capital the caseless branch cannot show, and both are
    load-bearing: a caseless *word* is capped at 16 code points, because a
    Japanese sentence is one "word" and word count stops bounding a line
    written without spaces; and a line with **no capital anywhere** is capped
    at 3 words rather than 5, because brevity is then the only evidence left.
    A lowercase Cyrillic or Greek line is still prose — those scripts are
    `\p{Ll}`, never `\p{Lo}`, so the caseless branch cannot leak into them.
    The old `_allCapsWord` was strictly subsumed by the proper-noun shape and
    is gone. Widening the alphabet further, or widening the punctuation a word
    may carry, is the thing to refuse in review; `test/place_header_script_test.dart`
    is half acceptance and half refusal for exactly that reason. The
    `[A-Za-z]` groups still in `src/date_header.dart` are deliberate — they
    capture candidate month and weekday words that are immediately looked up
    in English-only tables, so widening them would change nothing.
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
