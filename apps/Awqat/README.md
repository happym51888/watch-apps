# Awqat — prayer times, Qibla and tasbih, with nothing to connect to

Watch-only. No iPhone app, no account, no network call, ever.

## Why this app

Two separate signals, and the second one is what shaped the design.

**The incumbent's complication is broken.** From a user who liked it:

> hands down the BEST salah times app for the watch. But recently it has not
> been functioning at all… the widget appears as just a blank square.

**Every prayer app gets the Fajr alarm wrong, and it is a platform problem.**
From a developer describing exactly why:

> every prayer app delivers the pre-dawn (Fajr / suhoor) alarm as a
> notification. iOS caps notification sound at 30 seconds

Thirty seconds of chime does not wake someone who is genuinely asleep. That is
why the complaint about these apps is almost never "the times are wrong" — it is
that people miss Fajr. A notification is a reminder. Waking up needs an alarm.

Research on this category was blunt that prayer-time apps are a crowded field,
and that is true. But "crowded" and "solved" are different words. The two things
above are the reasons to build another one, and they are the two things this app
does differently.

## The three decisions that make it different

**1. Fajr gets a real alarm, not a notification.** watchOS has a purpose-built
mechanism for this: an extended runtime session of type `.alarm`. It is
scheduled in advance, wakes the app at the appointed moment with nothing
running, and buzzes the wrist repeatedly — in Silent Mode, with no sound needed
at all, which on a wrist is *more* reliable than a speaker. Apple's constraints
are strict and `AlarmScheduler` is shaped entirely around them:

- 36 hours ahead, maximum
- one scheduled session at a time
- the app **must** play a haptic when it starts, or the system offers the user a
  way to stop it scheduling sessions at all

So Fajr — the one you might sleep through — takes the single alarm slot and is
re-armed every time the app runs. The other four are ordinary notifications,
which is the right tool for "you are awake, it is time". The settings screen
says all of this out loud, including the 36-hour limit, because an alarm the
user believes is set but is not is worse than no alarm.

**2. The complication cannot go blank.** It never computes a timetable. The app
writes a two-field snapshot to a shared App Group whenever anything changes, and
the widget only reads. If the snapshot is missing it renders "Open Awqat" —
readable text, because a blank square is indistinguishable from a crash. Its
reload policy is `.after(the prayer time)`, so it rolls over on its own at the
one moment it becomes stale, rather than polling.

**3. Nothing needs a network, ever.** Sunrise, sunset, transit and the Asr
shadow angle are computed from Meeus's solar-position algorithms on the device.
Given coordinates the app has a full timetable on a plane, in a basement, or in
a country with no roaming. The last location fix is cached indefinitely, because
a fix from yesterday is worth far more than a spinner — and when it is stale the
screen says so instead of quietly pretending.

## Layout

```
Package.swift                    SwiftPM library, runs anywhere
Sources/AwqatCore/
  Astronomy.swift                Meeus solar position, sunrise/sunset/transit/Asr
  CalculationMethod.swift        11 published conventions, as data
  PrayerTimes.swift              The six times, plus high-latitude fallbacks
  Qibla.swift                    Great-circle bearing to the Kaaba
Tests/AwqatCoreTests/            Including the published-timetable regression
WatchApp/                        SwiftUI, Core Location, alarms
Complication/                    Next-prayer widget
Shared/SharedSnapshot.swift      The only file both targets compile
validation/verify_astronomy.py   Executable proof — see below
project.yml                      XcodeGen spec
```

## Build

```sh
brew install xcodegen
xcodegen generate
open Awqat.xcodeproj
```

Set your Team ID in `project.yml`, or pick a team in Xcode's Signing pane. The
App Group `group.app.awqat` must exist in your developer account and match both
entitlements files and `SharedSnapshot.suiteName`.

Logic tests, no Mac needed:

```sh
swift test
```

## Verification status

**The Swift here has never been compiled** — it was written on Windows, where
the toolchain cannot load its own standard library without the Windows SDK.
Expect to fix compile errors on the first build.

The astronomy, though, is checked against times published by someone else:

```sh
python validation/verify_astronomy.py
```

36 reference points from the AlAdhan API — six locations chosen to break things
rather than to agree: London at midsummer (high latitude), New York in midwinter
under ISNA, Jakarta on the equator with Hanafi Asr, Sydney in the southern
hemisphere, Cairo under the Egyptian method with Hanafi Asr, and Makkah with Umm
al-Qura's fixed-interval Isha.

Thirty of the thirty-six match exactly. The remaining six are all Asr, all
within 60 seconds, and chasing them down was worth the time: back-calculating
the shadow factor each implementation's time actually implies gives **0.98–0.99
for AlAdhan against a declared 1.0**, and **1.0000 exactly** for this engine. The
disagreement is theirs. It is documented rather than "fixed", because matching
it would mean deliberately computing the wrong Asr.

The cause on this side was worth fixing though: the first version computed solar
declination once at noon and reused it for Asr four hours later. Asr's altitude
is itself a function of declination, so the estimate has to be iterated until it
converges. It now is.

What still needs a real watch: whether the `.alarm` session actually fires
reliably after a night on the charger, whether Core Location returns a fix
quickly enough on a cold launch, and whether the compass is usable indoors.

## Shipping a watch-only app

There is no standalone watchOS platform on the App Store, and Xcode's Organizer
will refuse to upload a watch-only build. The documented route is to nest the
watch app inside a stub iOS container:

- container `Info.plist`: `ITSWatchOnlyContainer = true` (this is what removes
  the iPhone-screenshot requirement) and `LSApplicationLaunchProhibited = true`
- watch app `Info.plist`: `WKWatchOnly = true`, no
  `WKCompanionAppBundleIdentifier` — already set here
- upload with `iTMSTransporter`, not the Organizer

One consequence to price in before choosing watch-only: **App Store Analytics
reports nothing for watch-only apps** — no acquisition, retention, or crash data,
only Sales and Trends. You will be shipping without instrumentation.

## Religious correctness, and the limits of it

This app takes positions, and it should be honest about which ones:

- **Angles are data, not opinion.** All eleven methods' published values live in
  one file so that a disagreement with a printed timetable can be traced to a
  single number rather than argued about.
- **Asr school is a user setting, not a method property.** A Hanafi user in
  Britain follows Karachi's angles but their own madhab's Asr, and no published
  method encodes that combination.
- **High-latitude rules are labelled as conventions.** Where the sun never gets
  far enough below the horizon, there is no astronomical answer. The app offers
  the three usual rules and says plainly that none is more correct — follow your
  mosque.
- **Polar days say so.** Where sunrise and sunset genuinely do not occur, the app
  shows an explanation instead of inventing a time.
- **Per-prayer minute adjustments exist** because every real timetable differs
  from pure calculation by a minute or two, and users overwhelmingly want to
  match the board on the wall.

## Deliberately not in v1

- **Hijri date and Ramadan features.** The obvious next addition, and the one
  most likely to be asked for first. Hijri needs a sighting convention, which is
  another "this is a choice, not a calculation" surface.
- **Manual city selection.** Location is automatic only. Someone who wants times
  for where they are travelling tomorrow cannot get them.
- **Adhan audio.** The watch speaker is poor and the haptic alarm is better on a
  wrist, but a lot of people will expect it.
- **Qada tracking and prayer logging.** A different app, really.
- **Nearest-city fallback for polar latitudes.** Currently it explains the
  problem rather than solving it.
