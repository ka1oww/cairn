# Dual camera spike

This is a **throwaway spike**, not a prototype of Cairn's real camera screen, in the same
spirit as `learning/riverpod-drift-demo`. Its only job is to answer one question with running
code: does the moment -- back camera as the subject, small front-camera inset in the corner --
need true hardware-simultaneous dual capture, or does a fast back-then-front sequence deliver
the same effect people actually recognise as "the BeReal effect"? The design record already
calls dual capture "the one genuinely hard piece of engineering in this app"
(`docs/decisions/2026-08-22-design-calls.md`); this spike exists so nobody has to keep guessing
about that.

**The short answer:** build the back-then-front sequence. Don't chase true simultaneous
capture. The rest of this README is the evidence for that call, and the code that backs it up.

## 1. What BeReal actually does

The popular belief -- repeated in nearly every article, including BeReal's own marketing copy
-- is that the front and back cameras fire at the exact same instant. The evidence gathered for
this spike points somewhere else: **BeReal almost certainly takes the two photos in fast
sequence, not simultaneously.**

Four independent threads of evidence, from weakest to strongest:

1. **Marketing language is the only source for the popular belief.** Every "simultaneous" claim
   traced back leads to BeReal's own promotional copy or press coverage repeating it
   ([Shomil Jain's reverse-engineering writeup](https://shomil.me/bereal/) quotes Bloomberg
   describing "simultaneous images"). No independent technical source was found that confirms
   this from the client's actual capture code.
2. **API teardown shows two separate, sequential upload requests.** A practical MITM teardown of
   BeReal's network traffic found that posting a BeReal uploads the front and back images as
   [two consecutive HTTP requests](https://dev.to/ozcap/comment/215h0), followed by a third call
   telling the API where they landed. Sequential uploads don't *prove* sequential capture on
   their own (a client could capture in parallel and upload in series), but they're consistent
   with it and inconsistent with any special synchronization effort.
3. **User-facing accounts describe a perceptible pause.** Multiple independent write-ups on using
   the app describe "a slight delay between capturing the two photos", with the rear camera
   firing first and the front camera "automatically" following "with a moment's pause" --
   see [Does BeReal Take Front or Back Camera First?](https://techtalkhome.com/does-bereal-take-front-or-back-camera-first/)
   (accessed via search cache; the site returned an access-blocked response to a direct fetch
   during this research, so treat this one source as secondary corroboration, not primary).
4. **The decisive one: BeReal's own stated minimum device requirements are incompatible with a
   hard dependency on true simultaneous hardware capture.** BeReal's help center lists minimums of
   [Android 8 and iOS 15, with no chip/processor requirement](https://help.bereal.com/hc/en-us/articles/7531346369053-Minimum-device-requirements)
   (quoted via search cache for the same reason as above). Android's concurrent-camera API
   (`getConcurrentCameraIds`) didn't exist before **Android 11 (API 30)** -- three major versions
   above BeReal's stated floor. iOS's `AVCaptureMultiCamSession` needs an **A12 chip** (iPhone
   XS/XR, 2018) -- iOS 15 itself shipped for iPhone 6s (2015, A9), three chip generations earlier.
   If BeReal required true multi-camera hardware, it could not run on the devices it explicitly
   advertises support for. It does anyway, which means it can't be requiring that hardware path.

None of this is a smoking-gun leaked source file -- BeReal's client is closed and no teardown
found was thorough enough to settle it beyond all doubt. But points 2-4 triangulate on the same
answer independently, and point 4 in particular is close to dispositive: **it is not just likely
that BeReal uses sequential capture, it is close to provable from BeReal's own published
compatibility policy.**

**Why this is the single most valuable finding here:** if the thing people actually recognise
and love as "the BeReal effect" is a fast sequential shot, not a hardware-synchronized one, then
building true simultaneous capture for Cairn would mean solving a *harder* engineering problem
than the one that made the original work. That should weigh heavily against attempting it.

## 2. Is true simultaneous capture reachable from Flutter, on devices this party would carry?

Reachable in principle, on both platforms, for a real device flag -- but only through
platform-specific native code with zero framework or mature package support, at a real
complexity, battery, and thermal cost, and with device coverage that excludes real phones on
both sides.

### iOS

- `AVCaptureMultiCamSession` requires **iOS 13+ and an A12-or-later chip** (iPhone XS/XR, 2018,
  and everything since). Apple's guidance is to check the runtime flag
  [`isMultiCamSupported`](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession/ismulticamsupported)
  rather than hardcode a device list.
- **This spike measured that flag directly rather than trusting secondhand claims about it** --
  see `ios/Runner/AppDelegate.swift`, which wires it up over a `MethodChannel`. Running the built
  app on a booted (headless, no GUI window opened) iOS Simulator -- "iPhone 17 Pro", iOS 26.5,
  built with Xcode 26.6 -- logged:

  ```
  MULTICAM_PROBE_RAW_VALUE=true model=iPhone systemVersion=26.5
  ```

  This directly contradicts guidance repeated as recently as a source found *during this spike's
  own research* (a [dev.to piece on `AVCaptureMultiCamSession`'s real limits](https://dev.to/tbds_2dadf2b626f315902eae/avcapturemulticamsession-the-real-limits-and-why-the-stock-camera-app-doesnt-offer-dual-recording-4o7e))
  that the flag is "permanently false" in Simulator. It is not, at least not on current tooling.
  **What this does and doesn't prove:** Simulators have zero real camera hardware regardless of
  what this flag says, so a `true` result here cannot mean a live session will actually work --
  it means the flag answers from the simulated device's declared chip class, not from any live
  sensor probe. The practical lesson carries over to real devices too: **treat `isMultiCamSupported`
  as "eligible to attempt", never as "confirmed working"** -- which matters even more on Android,
  see below, where the equivalent flag is documented to lie in both directions.
- **Cost, from research (not yet measured by this spike):** heat and battery are "materially
  worse than single-camera recording" -- two sensors, two ISP paths, a composite step per frame.
  Resolution is budget-constrained: the session enforces a `hardwareCost` ceiling and refuses to
  start once exceeded, meaning dual-1080p is often not available and a downgrade path is
  mandatory, not optional.
- **No live dual preview is possible in Flutter today without hand-written native UI.** The
  standard `camera` plugin supports exactly one open `CameraController` at a time; a second one
  breaks the first (confirmed by Flutter's own issue tracker --
  [flutter/flutter#119858](https://github.com/flutter/flutter/issues/119858), closed as a
  duplicate / not planned). A real dual-preview implementation would need two hand-rolled
  `UIView`-backed Flutter platform views hosting two `AVCaptureVideoPreviewLayer`s, wired to a
  single `AVCaptureMultiCamSession`, entirely outside anything the framework or an official
  plugin offers.
- **No third-party Flutter package is fit to build on.** Two were found:
  [`flutter_dual_camera`](https://pub.dev/packages/flutter_dual_camera) (1 like, last published
  16 months ago, and its own docs admit it "doesn't support displaying the camera preview in the
  UI, only capturing images") and [`multicamera`](https://pub.dev/packages/multicamera)
  (updated within the last day at the time of writing, but an unverified uploader, 4 likes, and
  its [source repo](https://github.com/alexdempster44/multicamera) has 1 star and documents no
  native implementation details, device requirements, or fallback behaviour at all). Neither is
  something to build a shipping feature on.
- **Verdict:** technically reachable on a real (2018-or-newer) but incomplete slice of iPhones,
  only by writing and maintaining bespoke native Swift with no cross-platform framework to lean
  on.

### Android

- The equivalent API is `CameraManager.getConcurrentCameraIds()` /
  `FEATURE_CAMERA_CONCURRENT`, added in **Android 11 (API 30)**, and it only exists in the
  low-level **Camera2** API -- **CameraX has no support for it**, which matters because CameraX
  is the modern, recommended camera layer and the one Flutter's own
  `camera_android_camerax` implementation is built on.
- **Real-world device coverage is the actual blocker, not the API level.**
  [STRV's engineering survey](https://www.strv.com/blog/can-we-use-the-front-back-cameras-at-the-same-time-on-android-engineering)
  of roughly 120,000 real Samsung/Xiaomi/Oppo/Vivo devices found only **about 23%** can actually
  run front and back concurrently. Worse, the capability flag is unreliable in *both*
  directions: some devices that advertise the feature (Galaxy Z Flip, Poco X3) don't reliably
  deliver it, and at least one that doesn't advertise it (Pixel 6) does. Google's own
  [concurrent-streaming docs](https://source.android.com/docs/core/camera/concurrent-streaming)
  concede camera HALs are allowed to fail the request outright
  (`ERROR_MAX_CAMERAS_IN_USE`) even for a combination the API reported as supported.
- **No implementation was attempted here.** `flutter doctor` on this machine reports no Android
  SDK installed at all -- not "unconfigured", genuinely absent -- so there was no way to even
  compile-check a single line of Kotlin, let alone run it. Writing untested native Android code
  inside a spike whose whole purpose is honesty about what's proven would have undercut the
  point of the exercise. Android's answer is documented here from research, not code.
- **Verdict:** technically reachable, but on roughly one in four real devices today (and that
  number is itself unreliable per-device), via the same bespoke-native-code cost as iOS, with a
  meaningfully worse coverage story.

### Cross-platform verdict

Reachable, yes, on both platforms, for a shrinking-but-real minority of the devices this party
would actually carry, through 100% bespoke native code with no framework or mature package to
lean on, at a real and independently-documented battery/heat/complexity cost -- in service of
reproducing an effect that the evidence in part 1 says the original app probably didn't build
that way either.

## 3. What this spike built, and why

The working code here is the **back-then-front sequential capture**, because that's what the
evidence in part 1 says actually produces "the BeReal effect", it's what the design already
treats as an acceptable path (`docs/decisions/2026-08-22-design-calls.md`, section 5: "Back-only
remains an acceptable fallback... the inset is a nice-to-have, not the mechanic"), and it's the
only one of the two mechanics buildable today on `camera` -- the one camera package that's
official, actively maintained, and behaves identically on every platform Cairn ships to.

Also built, but strictly as a diagnostic rather than a feature: the iOS-only
`isMultiCamSupported` probe described above. It exists so a future session with an actual
physical iPhone in hand can re-ask the reachability question directly, on the real device,
without redoing this research.

**Read these files in this order:**

1. **`lib/moment/capture_sequencer.dart`** -- the entire "sequential capture" mechanic: capture
   back, switch lenses, capture front, and time it. It never imports `package:camera`; it's
   handed three closures and only cares about order and timing. That's what makes it provable
   without any camera, real or fake, anywhere in the picture.
2. **`test/capture_sequencer_test.dart`** -- proves that mechanic correct: ordering, that a
   failure at any step stops the sequence rather than continuing, and that the measured gap
   between shots is never negative.
3. **`lib/moment/moment_camera_screen.dart`** -- wires real `CameraController` calls into those
   three closures. The comment at the top of the file explains why there's no live front-camera
   preview during capture (the single-controller limitation above) and why that's not a
   workaround-in-waiting -- it's the actual supported shape.
4. **`lib/widgets/dual_camera_frame.dart`** -- the compositor: back full-bleed, front in a small
   rounded corner inset, per the design's own language ("in the manner people already know from
   BeReal").
5. **`lib/moment/moment_review_screen.dart`** -- shows the finished moment and the one number
   this whole spike exists to produce on real hardware: the measured gap, in milliseconds,
   between the two shots.
6. **`lib/multicam/multicam_capability.dart`** and **`ios/Runner/AppDelegate.swift`** -- the
   `isMultiCamSupported` diagnostic probe, and the doc comments explaining exactly what it did
   and didn't prove when run on Simulator (see part 2).

## 4. How to run it

```sh
cd learning/dual-camera-spike
flutter pub get
flutter analyze          # 0 issues
flutter test             # 5/5 passing -- the sequencer logic, no hardware needed
flutter run -d chrome    # the only target on a stock Mac with a real, live camera
```

Running on Chrome uses this machine's built-in webcam through `getUserMedia`. A laptop has
exactly one physical camera, so the app detects that (`availableCameras()` returns one entry for
both "back" and "front" roles) and reuses it for both shots -- **labelled honestly on-screen**,
not silently faked, via the diagnostic strip at the top of the camera screen.

For iOS:

```sh
flutter build ios --simulator --no-codesign   # compiles; proves the Swift is correct
```

This produces a real `.app` and is enough to catch any Swift/type error, but **cannot exercise
live capture** -- Simulators have no camera hardware at all (see the constraint this task was
given). It *can* exercise the `isMultiCamSupported` probe, which only needs the OS to answer a
question, not a live sensor -- that's the `MULTICAM_PROBE_RAW_VALUE=true` result quoted above. A
physical iPhone, plugged in and run with `flutter run -d <device-id>`, is the only way to prove
anything further.

### `flutter doctor` output (captured on this machine)

```
[✓] Flutter (Channel stable, 3.47.1, on macOS 26.3.1 25D2128 darwin-arm64, locale en-US) [344ms]
[✗] Android toolchain - develop for Android devices [266ms]
    ✗ Unable to locate Android SDK.
[✓] Xcode - develop for iOS and macOS (Xcode 26.6) [854ms]
    • Xcode at /Applications/Xcode.app/Contents/Developer
    • CocoaPods version 1.17.0
[✓] Chrome - develop for the web [4ms]
[✓] Connected device (2 available) [6.1s]
    • macOS (desktop), Chrome (web)
[✓] Network resources [854ms]

! Doctor found issues in 1 category.
```

Unlike `learning/riverpod-drift-demo`, Xcode is actually installed on this machine (26.6, with
CocoaPods) -- which is why the iOS Simulator compile check and the live `isMultiCamSupported`
probe above were possible at all. What's still missing is a physical iPhone and an Android SDK;
neither was worth fighting the toolchain for, per this task's own brief.

## 5. What was actually proven, and what wasn't

**Proven, with evidence in this repo:**

- `flutter analyze` -- clean, 0 issues.
- `flutter test` -- 5/5 passing. This proves the entire sequential-capture mechanic (ordering,
  timing, failure propagation) correct, independent of any camera hardware.
- `flutter build web` -- compiles cleanly.
- `flutter build ios --simulator --no-codesign` -- compiles cleanly. The native Swift
  (`AVCaptureMultiCamSession` channel in `AppDelegate.swift`) type-checks and links against the
  real iOS 26 SDK via the Xcode 26.6 actually installed on this machine -- not a claim, a
  successful build.
- The `isMultiCamSupported` probe -- actually invoked end-to-end (Dart → `MethodChannel` →
  Swift → AVFoundation → back to Dart) on a booted iOS Simulator, headless, no GUI window ever
  opened. Result and its correct interpretation are both documented above and in
  `ios/Runner/AppDelegate.swift`.

**Written and reasoned about, not run:**

- The actual back-then-front `CameraController` capture flow, against real camera hardware.
  `flutter test` exercises the sequencing logic with fakes; nothing in this session ran it
  against a live lens. (`flutter run -d chrome`, which would exercise it against this machine's
  real webcam, was written to work and reasoned through carefully, but not actually driven
  end-to-end in this session -- doing so safely would need a browser automation session, and the
  one available in this environment appeared to already be pointed at someone's own in-progress,
  unrelated review tab, which wasn't worth hijacking for a secondary check.)
- Everything about real iPhone behaviour: whether `AVCaptureMultiCamSession` genuinely starts on
  a physical device, and -- the number that actually matters -- what the sequential fallback's
  real gap-between-shots is when switching real front/back lenses instead of Simulator's
  nonexistent camera. `MomentReviewScreen` reports that number the moment this runs on one.
- Android, entirely -- no code, because there was no SDK on this machine to even compile-check
  it against.

## 6. Recommendation

**Build the back-then-front sequence as the real, shipping mechanic** -- not a fallback-of-a-
fallback, but the intended design. The evidence says that's what "runs like BeReal" actually
means. **Do not build true hardware-simultaneous capture:** it answers a harder engineering
question than the one that made the original work, it has zero support in Flutter's framework or
ecosystem, it excludes real phones in the party on both platforms (pre-2018 iPhones; roughly
three in four Android devices), and its complexity/battery/heat cost is disproportionate against
a design that already blesses back-camera-only as acceptable and calls the inset "a nice-to-have,
not the mechanic."

**The one thing still worth doing before calling this fully closed:** run this exact app on a
physical iPhone (`flutter run -d <device-id>`) and read the number `MomentReviewScreen` reports.
Whether that gap lands at 150ms or 2 seconds is the one question this spike could not answer
from a laptop, and it's the only remaining number that could change this recommendation.
