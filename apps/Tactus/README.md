# Tactus — a metronome you can actually feel

Watch-only. No iPhone app, no account, no network, no subscription.

## Why this app

Soundbrenner sells a $70–130 wearable whose entire pitch is that your smartwatch
cannot do this job. Their own FAQ, answering "Why can't I just use my other
wearable, e.g. Fitbit or Apple Watch, instead of Pulse?":

> Pulse uses a 7G ERM haptic motor powered by a special haptic driver. This
> creates vibrations unlike those found in other wearables. More distinct,
> precise, and 700% more powerful than most devices.

— <https://www.soundbrenner.com/products/pulse-vibrating-metronome>

They are half right. The hardware really is weaker. But the other half of the
problem is software, and it is fixable. From a musicians' forum discussing
metronome apps on Apple Watch:

> it can't buzz very strongly, and it limits the app life-cycle so it's at best
> tricky to keep a metronome watch running long enough for a song and at worst
> impossible.

— <https://forum.ukuleleunderground.com/threads/soundbrenner-core-musicians-smart-watch.143795/>

And the incumbent app's reviews are a list of the same two failures over and over:

> No Haptics on apple watch — Can't get haptic feedback working on apple watch.
>
> Looks good but not good with watch — … And the haptic is too faint.
>
> WatchOS app NOT WORKING!!! … When I open it on my watch, a set of rotating dots
> appears and then it duplicates
>
> Doesn't work on Apple Watch … It either crashes upon opening, or is stuck on an
> endless loop of loading.

— <https://appsupports.co/1097323003/pulse-metronome-tap-tempo/negative-reviews>

So the gap is not "nobody thought of a watch metronome". The gap is that the
existing ones are too faint, stop when you lower your wrist, and in several cases
do not load at all. Three things follow, and they are the whole design:

1. **Use the loud haptics.** `.notification` and `.start`, not `.click`. There is
   no intensity API on watchOS, so strength *is* the choice of pattern.
2. **Keep running with the screen off**, via an extended runtime session.
3. **Never let the pattern smear.** Apple documents a 100 ms floor between
   haptics, and the engine cancels whatever is mid-pulse when a new call arrives.
   Past roughly 176 bpm a tap-per-beat cannot be delivered cleanly. Tactus thins
   the pattern deliberately — subdivisions first, then unaccented beats — and says
   on screen what it dropped, instead of firing calls that get swallowed.

## Layout

```
Package.swift                  SwiftPM library, so the logic is testable anywhere
Sources/TactusCore/            Pure logic. No WatchKit, no SwiftUI, no AVFoundation.
  PulseGrid.swift              Drift-free beat timeline
  HapticPlan.swift             The rate-limit planner
  TapTempo.swift               Median-based tap tempo
  HapticProfile.swift          Strength profiles (shared with the complication)
Tests/TactusCoreTests/         Full suite for the above
WatchApp/                      SwiftUI + WatchKit + AVFoundation
Complication/                  WidgetKit complication
validation/                    Executable check of the logic — see below
project.yml                    XcodeGen spec
```

The split is the point: everything that can be got wrong silently lives in
`Sources/TactusCore` and is covered by tests, and everything in `WatchApp` is
plumbing that fails loudly.

## Build

```sh
brew install xcodegen
xcodegen generate
open Tactus.xcodeproj
```

Set `DEVELOPMENT_TEAM` in `project.yml`, or just pick your team in Xcode under
Signing & Capabilities. Then run on a real Apple Watch — the simulator does not
have a Taptic Engine, so it cannot tell you the one thing this app lives or dies
on.

Run the logic tests, which need no Mac and no Xcode:

```sh
swift test
```

## Verification status

**The Swift in this project has never been compiled.** It was written on Windows,
where the Swift toolchain cannot load its own standard library without the Windows
SDK, and SwiftUI/WatchKit cannot be compiled at all outside the Apple SDKs. Expect
to fix compile errors on the first build.

What *has* been verified is the logic, by porting it and running it:

```sh
python validation/verify_haptic_plan.py
```

```
Property 1: haptic rate limit is never violated
  swept 60960 configurations
  tightest gap anywhere: 0.3409s (floor 0.34s)
Property 4: pulse offsets do not drift
  after 8220 pulses (60 min at 137bpm): indexed offset error 0.00e+00s
...
61233 assertions
RESULT: PASS
```

The sweep covers every integer tempo from 20 to 400 bpm against 8 time
signatures, 4 subdivision levels and 5 accent patterns, and asserts that no
configuration anywhere schedules two taps closer than the engine can render.

Things no amount of off-device testing can tell you, and which need a real watch:

- whether "Firm" is actually strong enough through a guitar strap
- whether a `mindfulness` session really survives an hour of practice
- battery cost of an hour of `.notification` haptics
- whether the audible click's jitter is acceptable to a drummer

## App Review risk — read before submitting

Tactus declares `mindfulness` in `WKBackgroundModes`. That is the longest
frontmost extended-runtime session available (one hour, screen may switch off),
and it is what keeps the beat going when you lower your wrist.

Apple's guidance is explicit that the session type should be chosen for the app's
*purpose*, not for the runtime it grants:

> Select a session type based on the app's intended use — not based on the
> features that the session provides.

— <https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions>

A metronome is not mindfulness. This is a real, honest risk of rejection, and you
should decide about it deliberately rather than discover it at review:

- **Option A (shipped default).** Keep `mindfulness` and describe the app as a
  practice-session tool in the review notes. Many practice and timer apps do this.
  It may be accepted; it may not.
- **Option B (no risk).** Drop `mindfulness`, keep only `audio`, and make the
  audible click mandatory whenever the metronome is running — routing it to
  AirPods at low volume if the player wants "silent" practice. Background audio is
  unambiguously sanctioned and has no time limit while audio plays. The cost is
  that a truly silent, headphone-free session then stops when the wrist drops.
- **Option C.** Ship Option B, and add Option A later once there is a user base
  worth arguing for.

`ClickPlayer` is already written, so switching to Option B is a plist change plus
forcing `audioClickEnabled` on.

## Shipping a watch-only app

The App Store has no standalone watchOS platform, and Xcode's Organizer will
refuse to upload a watch-only build. The documented workaround is to nest the
watch app inside a stub iOS container:

- container `Info.plist`: `ITSWatchOnlyContainer = true` (this is what removes the
  iPhone-screenshot requirement and makes the store treat the product as
  watch-only) and `LSApplicationLaunchProhibited = true`
- watch app `Info.plist`: `WKWatchOnly = true`, and **no**
  `WKCompanionAppBundleIdentifier` — already set in `project.yml`
- upload with `iTMSTransporter`, not the Organizer

Source: <https://perryts.com/pt/blog/shipping-a-watch-only-app-to-the-app-store/>

Try the plain Xcode upload first; if it refuses, this is the route.

## Deliberately not in v1

- **Sample-accurate audio.** The click is scheduled per pulse, so it carries the
  same millisecond jitter as the haptic. Fine for practice, wrong for tracking to
  a click. Pre-scheduling onto `AVAudioTime` is the fix.
- **Ableton Link.** The thing that would make this competitive with Soundbrenner
  for stage use. Needs the Link SDK and a real network stack on the watch.
- **Setlist sync from a phone.** Presets are named on the watch by design, but a
  companion app is the obvious follow-up for anyone with a 30-song set.
- **Polyrhythms and tempo ramps.** `PulseGrid` is a single grid; polyrhythm means
  two, and at that point the rate limiter has to arbitrate between them.
