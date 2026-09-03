# App Store submission

What is ready, what still needs a Mac, and the exact text to paste into App
Store Connect.

## Ready

| | Kairos | Tactus | Awqat | Verba |
|---|---|---|---|---|
| Compiles (CI, real `xcodebuild`) | yes | yes | yes | yes |
| Logic tests pass | 9 | 31 | 36 | 19 |
| 1024×1024 icon | yes | yes | yes | yes |
| `PrivacyInfo.xcprivacy` | yes | yes | yes | yes |
| Purpose strings in `Info.plist` | camera | — | location | mic, speech |
| Launches on simulator | CI job | CI job | CI job | CI job |
| Bundle id | `app.kairos` | `app.tactus.watchkitapp` | `app.awqat.watchkitapp` | `app.verba` |

## Still needs a Mac (or a paid account)

1. **Signing.** `DEVELOPMENT_TEAM` is empty in all four `project.yml` files.
   Set it, or pick a team in Xcode's Signing pane. CI builds unsigned.
2. **Archive and upload.** `xcodebuild archive` then Xcode Organizer or
   `xcrun altool` / `iTMSTransporter`. Cannot be done from Windows.
3. **Screenshots you would actually publish.** CI produces real screenshots of
   each app launching (artifact `screenshot-*`), which proves the app renders
   and is enough to submit. They show first-launch state — an empty vault, a
   stopped metronome — because nothing seeds demo data. Presentable
   screenshots need either a seeded demo mode or a wrist.
4. **The watch-only container** for Tactus and Awqat, below.

## Watch-only apps need an iOS container

Tactus and Awqat have no iPhone app and no reason to have one. Xcode Organizer
will still refuse to upload a standalone watchOS app: the store's unit of
distribution is an iOS app that happens to contain a watch app.

The stub container is an iOS target that ships no code and cannot be launched:

```
ITSWatchOnlyContainer          = true    # tells the store this is watch-only
LSApplicationLaunchProhibited  = true    # the iPhone app is not launchable
WKWatchOnly                    = true    # (in the watch app) runs with no phone
```

and **no** `WKCompanionAppBundleIdentifier` in the watch app's `Info.plist` —
that key is what makes a watch app a companion, and a companion app will not
run on a watch paired through Family Setup.

Kairos and Verba do not need this. Both have real iPhone apps: Kairos scans
enrolment QR codes, Verba does the transcription (watchOS has no speech API at
all).

Awqat's watch `Info.plist` currently carries
`UIRequiredDeviceCapabilities: [watch-companion]` alongside `WKWatchOnly`.
Those two contradict each other — `watch-companion` is an iOS-side capability
meaning "requires a paired watch". Worth removing when you set up the
container; it was not changed here because it cannot be verified from Windows
and the build does not complain.

## Listings

Field limits: name 30, subtitle 30, keywords 100 (comma-separated, no spaces),
promotional text 170.

### Kairos

- **Name:** `Kairos — Codes on Your Wrist`  *(30)*
- **Subtitle:** `2FA codes without your phone`
- **Keywords:** `2fa,totp,otp,authenticator,two-factor,security,code,login,verification,offline`
- **Promotional text:** Your two-factor codes on your wrist. No phone, no
  network, no account.

> **Description**
>
> Kairos shows your two-factor authentication codes on your Apple Watch.
>
> Raise your wrist, read the code, type it. That is the whole app. You do not
> take out your phone, unlock it, find the authenticator app, and scroll.
>
> **It works with what you already use.** Scan the same QR code you would scan
> with any other authenticator. Kairos implements the standards those codes are
> defined by — RFC 6238 for time-based codes and RFC 4226 for counter-based
> ones — so anything that issues a normal `otpauth://` code works.
>
> **Nothing leaves your watch.** There is no account to create, no sync, no
> server, and no networking code in the app at all. Secrets are stored in the
> Keychain, marked as this-device-only, so they are not in your iCloud backup
> and do not follow you to a new device. That is a deliberate trade: it means
> you keep your own backup of the original QR codes.
>
> **The countdown is honest.** The ring shows how long the current code has
> left, and the code changes exactly when the window does, not a second early
> or late.
>
> Supports 6 to 10 digit codes, SHA-1, SHA-256 and SHA-512, and custom periods.

> **Review notes**
>
> No account needed. To test: add an account by scanning any TOTP QR code, or
> use the standard RFC 6238 test vector — secret `GEZDGNBVGY3TQOJQ` (base32 for
> "12345678901234567890"), which produces `287082` at Unix time 59.
>
> The app has no network entitlement and makes no network requests. The camera
> is used only on iPhone to decode an enrolment QR code; the image is never
> stored or transmitted.

### Tactus

- **Name:** `Tactus — Haptic Metronome`
- **Subtitle:** `Feel the beat, don't hear it`
- **Keywords:** `metronome,haptic,tempo,bpm,practice,drums,music,rhythm,tap,beat,silent,timing`
- **Promotional text:** A metronome you feel through your wrist. Keeps running
  when the screen goes dark.

> **Description**
>
> Tactus taps the beat on your wrist instead of clicking in your ear.
>
> Useful when a click track is in the way: playing with other people, practising
> a wind instrument, on stage, in a quiet room, or with headphones already
> carrying something else.
>
> **It keeps going when the screen goes off.** Most watch metronomes stop the
> moment your wrist drops, because a suspended app cannot produce haptics.
> Tactus holds an extended runtime session so the beat continues.
>
> **It tells you the truth about fast tempos.** The Taptic Engine cannot tap
> faster than about ten times a second, and taps need more spacing than that to
> feel like separate beats rather than a buzz. Past roughly 176 bpm something
> has to give. Instead of smearing, Tactus thins deliberately — subdivisions
> first, then unaccented beats, then everything but the downbeat — and the
> settings screen tells you exactly what it is doing at your current tempo.
>
> **No drift.** Beats are scheduled against absolute deadlines rather than by
> adding up intervals, so an hour of practice ends on the beat it should.
>
> Tap tempo, 2/4 through 12/8, subdivisions to sixteenths, editable accents, and
> an optional audible click for the beats the wrist is too slow to carry.

> **Review notes**
>
> **On the extended runtime session:** Tactus declares `mindfulness`. A
> metronome is not a mindfulness app, and the session type is used here for the
> reason the category exists — a frontmost session that survives the screen
> switching off. It is the only session type that allows this app to work as
> described; without it the beat stops when the wrist drops, which is the single
> most common complaint about existing watch metronomes.
>
> If this is not acceptable, the app still functions with the audible click
> (`audio` background mode) and we will remove the `mindfulness` declaration on
> request. Flagging it up front rather than hoping it passes.
>
> No account, no network, no data collection.

### Awqat

- **Name:** `Awqat — Prayer Times & Qibla`
- **Subtitle:** `Prayer times, computed on-watch`
- **Keywords:** `prayer,salah,namaz,qibla,adhan,islam,muslim,fajr,ramadan,times,compass,athan`
- **Promotional text:** Prayer times and qibla on your wrist. Computed on the
  watch, works with no signal.

> **Description**
>
> Prayer times and the direction of the qibla, on your wrist.
>
> **The complication works.** It shows the next prayer and how long until it, on
> the watch face, and it updates. This is the reason the app exists.
>
> **Times are computed, not downloaded.** The solar position calculations run on
> the watch, so the app works on a plane, in a basement, abroad, with no signal
> and no phone. Nothing is fetched and nothing is sent.
>
> **Your calculation method, not ours.** Muslim World League, Egyptian General
> Authority, University of Islamic Sciences Karachi, Umm al-Qura, Dubai, ISNA,
> Kuwait, Qatar, Singapore, Diyanet and Tehran, with Hanafi or standard Asr, and
> high-latitude rules for places where the sun does not set.
>
> **Fajr can wake you.** Fajr uses the watch's alarm session; the other prayers
> use notifications.
>
> Qibla is a great-circle bearing to the Kaaba, and the app tells you when it is
> using magnetic rather than true north instead of quietly pointing you a few
> degrees off.

> **Review notes**
>
> No account, no network. Location is used only to compute prayer times and the
> qibla bearing on the device, and is when-in-use rather than always.
>
> Times may differ by up to about a minute from some published timetables for
> Asr. This is deliberate and documented: Awqat computes the moment a shadow
> reaches the defined multiple of an object's height, recomputing the sun's
> declination at the estimated Asr time rather than reusing the value from solar
> noon. Some published tables appear to use a slightly different shadow factor.
> Details in `apps/Awqat/validation/verify_astronomy.py`.

### Verba

- **Name:** `Verba — Voice Notes to Text`
- **Subtitle:** `Record on your wrist, read anywhere`
- **Keywords:** `voice,memo,recorder,transcribe,dictation,notes,speech,text,audio,transcript,search`
- **Promotional text:** One tap to record on your wrist. Transcribed on your
  phone, searchable from your laptop.

> **Description**
>
> Verba records on your wrist and gives you back searchable text.
>
> One tap on the watch starts recording. The recording moves to your iPhone,
> which transcribes it, and both the audio and the text land in a database you
> can search, play and edit from any browser.
>
> **Transcription happens on your devices.** Your iPhone does the speech
> recognition, on-device where your language supports it. There is no
> transcription service in the middle.
>
> **It does not lose recordings.** The queue that moves audio off the watch is
> built so that a recording which exists only on the watch is never deleted —
> not when storage runs low, not when a transfer fails, not when the app is
> killed mid-transfer. That property is tested against hundreds of thousands of
> randomised event sequences including thousands of simulated crashes.
>
> **Long recordings stay whole.** Speech recognition works in windows, and a
> naive split eats the word that straddles the boundary — the text reads fine
> and is quietly missing a word a minute. Verba transcribes overlapping windows
> and stitches them by matching content.
>
> **Search works in your language.** Including Chinese and Japanese, where the
> usual full-text search silently returns nothing.

> **Review notes**
>
> **Verba needs a database, and you have to supply one.** It stores recordings
> in a Supabase project that the operator owns; there is no shared backend and
> no account service. For review, credentials for a test project are in the
> App Review Information field.
>
> Recording starts in the foreground only. The `audio` background mode is
> declared to let a recording that the user started continue while the app is
> backgrounded — third-party watch apps cannot start recording from the
> background and Verba does not attempt to.
>
> Microphone and speech recognition are both used for the app's stated purpose
> and are both explained in their purpose strings.

## Privacy questionnaire

App Store Connect asks separately from the manifest. Answers:

| | Kairos | Tactus | Awqat | Verba |
|---|---|---|---|---|
| Data collected | none | none | none | audio, user content, email |
| Data linked to user | — | — | — | all three |
| Used for tracking | no | no | no | no |
| Third-party analytics | none | none | none | none |
| Location | not used | not used | **used, not collected** | not used |

Awqat is the one that needs care: it *uses* location and does not *collect* it.
Answer yes to the location question, then "not collected". The privacy
manifest's `NSPrivacyCollectedDataTypes` stays empty because nothing is
transmitted — there is no networking code in the app.

Verba's three types are all "App Functionality", all linked (they are stored
under the user's id), none used for tracking.

## Screenshots

watchOS wants screenshots at the sizes of the current watch families. CI
captures one per app from the simulator on every push — download the
`screenshot-*` artifacts from the Actions run.

To make them presentable rather than merely truthful, seed demo state. The
cheapest route is a launch argument checked in the app entry point:

```swift
if ProcessInfo.processInfo.arguments.contains("-demo") { /* seed */ }
```

then pass it in `tools/simulator_smoke.sh` at the `simctl launch` call. Not
implemented — it means shipping demo-data code in the binary, which is worth
deciding on deliberately.

## Pre-flight checklist

Run before every upload:

```sh
python tools/check_privacy_manifests.py   # manifests match the code
python tools/check_workflow.py            # CI can still fail
```

Then, on a Mac:

- [ ] `DEVELOPMENT_TEAM` set in the app's `project.yml`
- [ ] `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` bumped
- [ ] Bundle ids registered in the developer portal (all use `app.<name>`; the
      `com.example.tactus` placeholder is gone)
- [ ] Watch-only container added for Tactus and Awqat
- [ ] `UIRequiredDeviceCapabilities: watch-companion` removed from Awqat's
      watch `Info.plist`
- [ ] Verba: a real Supabase project exists and
      `supabase/test/smoke_test.py` passes against it
- [ ] Verba: test credentials in App Review Information
- [ ] Tactus: the `mindfulness` session note copied into App Review
      Information
- [ ] Archive validates in Organizer

## Honest risk list

| Risk | App | Notes |
|---|---|---|
| `mindfulness` session for a metronome | Tactus | The one real rejection risk. Disclosed in review notes with a fallback. |
| Requires the user to run a database | Verba | Unusual for a consumer app; may draw questions about the business model or a "requires additional purchase" flag. |
| Asr differs ~1 min from some timetables | Awqat | Deliberate and documented; a reviewer is unlikely to check, a user might. |
| No backup or export of secrets | Kairos | By design (this-device-only Keychain), but users will ask. |
| Nothing is verified on real hardware | all | Haptic strength, extended-runtime reliability, battery cost, Core Location cold-start. CI cannot answer any of these. |
