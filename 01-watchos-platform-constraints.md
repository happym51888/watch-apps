# watchOS platform constraints that decide what is buildable

Researched 2026-09-03. Target: watchOS 27 / Xcode 27.

These constraints matter more than the idea list. Most "obvious" Apple Watch app ideas
are dead on arrival because of one of the limits below, so every candidate idea was
checked against this list before being ranked.

## 1. Haptics

`WKInterfaceDevice.current().play(_:)`:

- **No effect when the app is `background` or `inactive`.** The only documented exception
  is an app with an active `HKWorkoutSession`.
  Source: <https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:)>
- **Minimum 100 ms between haptics.** If the engine is already engaged, the system stops
  the current feedback and imposes a 100 ms floor before the next one. Practical ceiling
  is therefore ~2.5 distinct taps/second before taps start getting swallowed.
- **Only the 9 stock `WKHapticType` values.** No custom haptic waveform authoring on
  watchOS (Core Haptics `CHHapticEngine` pattern authoring is an iOS thing).
- **Haptics stall HealthKit heart-rate collection.** Apple explicitly says not to call
  `play(_:)` while gathering heart rate. Any app that mixes live HR with frequent haptics
  has to accept gaps.
- Haptics are silently a no-op if the user turned off haptics system-wide, so never make
  a haptic the only channel for critical state.

Consequence: a haptic metronome is feasible but **hard-capped around 150 BPM** for
one-tap-per-beat. Above that you must thin out the pattern (accent-only, or tap every
other beat). Any app promising "a tap every second, forever, in your pocket" is lying.

## 2. Background runtime

There is no general background timer on watchOS. The app is suspended when the wrist
drops. Four documented escapes, via `WKExtendedRuntimeSession`:

| Session type | Runtime | Schedulable | Time limit |
| --- | --- | --- | --- |
| Self care | Frontmost | No | 10 min |
| Mindfulness | Frontmost | No | 1 hour |
| Physical therapy | **Background** | No | 1 hour |
| Smart alarm | **Background** | Yes (`start(at:)`, up to ~36 h ahead) | 30 min |

Source: <https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions>

Notes that bite:

- "Frontmost" sessions survive the screen turning off, but die the moment the user
  presses the Digital Crown or switches apps.
- Only **physical therapy** and **smart alarm** genuinely run in the background.
- `notifyUser(hapticType:repeatHandler:)` is only for schedulable (smart alarm) sessions,
  repeat interval must be `0 < t <= 60` seconds. If the app is not active, the system
  shows its own alarm alert with Stop/Open.
- If you start a smart alarm session and never play a haptic, the system shows a warning
  and offers to disable future sessions for your app.
- Sustained high CPU during a session gets it killed with
  `WKExtendedRuntimeSessionErrorCode.exceededResourceLimits`.
- Sessions can be shortened at the system's discretion under thermal/battery pressure.
- **Silent-audio keep-alive does not work.** Background audio mode extends runtime only
  while real audio is actually playing.
- Each app may declare **only one** extended runtime session type.

`HKWorkoutSession` is the other path: it grants real background execution *and* is the
documented exception that lets haptics fire in the background. For anything that must
tap the wrist reliably over a long period, a workout session is the honest architecture —
but it is only legitimate if the activity really is a workout, otherwise review risk.

## 3. Things that are simply not available

- **No custom watch faces.** Third parties cannot ship a watch face; only complications
  via WidgetKit. Also, you cannot hide the system status-bar clock — attempting it is a
  documented rejection reason.
  Source: <https://stackoverflow.com/questions/38067952/how-to-hide-or-remove-the-time-from-the-apple-watch-status-bar>
- **No blood pressure sensor**, no raw PPG waveform, no continuous background
  accelerometer stream while suspended.
- **No third-party access to Apple's sleep staging** beyond what HealthKit exposes.
- **CGM / glucose** requires the sensor vendor's own API and partnership; a solo dev
  cannot ship "glucose on my wrist" for Dexcom/Libre users.
- Anything phrased as diagnosis or treatment invites medical-device regulation. Keep
  copy descriptive ("you logged X"), never diagnostic.

## 4. Complications

- WidgetKit only, families `accessoryCircular`, `accessoryCorner`, `accessoryRectangular`,
  `accessoryInline`.
- Timeline-based. You get a limited refresh budget per day; you cannot push a live-updating
  complication at arbitrary frequency. Design for "correct when glanced at", and prefer
  values that can be computed forward in time locally (e.g. next prayer time, next
  scheduled event) so one timeline entry set covers many hours without a refresh.

## 5. Shipping a watch-only app (the part nobody documents)

The App Store has no standalone watchOS platform. A watch-only app must be nested inside
a stub iOS container:

- Container `Info.plist`: `ITSWatchOnlyContainer = true` (this is what removes the
  iPhone-screenshot requirement and makes the store classify the product as watch-only)
  and `LSApplicationLaunchProhibited = true` (stub is never launched).
- Watch app `Info.plist`: `WKWatchOnly = true`, and **no** `WKCompanionAppBundleIdentifier`.
- Xcode's Organizer upload paths refuse this; upload with `iTMSTransporter`.

Source: <https://perryts.com/pt/blog/shipping-a-watch-only-app-to-the-app-store/>

Also relevant: in Xcode, "Deployment Settings → allow running without iOS Application"
is what makes a companion watch app independent.
Source: <https://developer.apple.com/forums/thread/749746>

## 6. What is new in watchOS 27 that opens doors

- **Foundation Models framework reaches watchOS** for the first time, including
  `PrivateCloudComputeLanguageModel` (32K context, no API keys, no account setup).
  On-device + Private Cloud Compute.
- **Vision framework on watchOS**: on-device image understanding, saliency-based cropping,
  barcode reading.
- **HealthKit workout zones**: heart-rate and cycling-power zone APIs.
- **Perimenopause / menopause state APIs.**

Sources: <https://developer.apple.com/wwdc26/guides/watchos/>,
<https://developer.apple.com/documentation/watchos-release-notes/watchos-27-release-notes>

The workout-zones API is the interesting one for this project: it lands exactly on the
loudest unmet fitness complaint (no real-time zone coaching) and it pairs with the
one legitimate way to play background haptics (a workout session).
