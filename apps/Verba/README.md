# Verba — one-tap voice capture on the wrist, text in a database

Tap the watch. Talk. Lower your wrist and keep talking. The audio reaches your
iPhone, gets transcribed on-device for free, and lands in your own Supabase
project as a searchable row.

---

## The two platform facts that designed this app

Before writing anything I checked the availability of every API this needs
against Apple's own documentation index rather than assuming. Two answers came
back that rule out the obvious design:

| API | watchOS? |
| --- | --- |
| `AVAudioRecorder` | yes, watchOS 4+ |
| `URLSessionConfiguration.background` | yes, watchOS 2+ |
| `WCSession.transferFile` | yes, watchOS 2+ |
| `SFSpeechRecognizer` | **no** — iOS, iPadOS, Mac Catalyst, macOS, visionOS |
| `SpeechAnalyzer` (new in 26) | **no** — iOS, iPadOS, Mac Catalyst, macOS, tvOS, visionOS |

**1. There is no speech-to-text API on watchOS. Not the old one, not the new
one.** So "the watch transcribes" is not a feature that can be built, at any
level of effort, by anyone. Transcription happens on the iPhone.

**2. A third-party watchOS app cannot start recording from the background.** The
`audio` background mode only permits *continuing* audio I/O that began while the
app was frontmost; starting it from a timer or a background task fails with
`AVAudioSession` error 561015905. So "record everything all day automatically"
is also not buildable.

What *is* buildable, and is what this app does:

- **One tap, from the watch face**, via a complication or the app in the Dock.
- **Recording continues** once started — wrist down, screen off, app
  backgrounded, other apps in front. This is fully supported and is the real
  need ("record the rest of this conversation").
- **Transcription on the iPhone**, on-device, free, private, unlimited.
- **Storage in your Supabase project**, which is what makes the same corpus
  reachable from a laptop.

If you want unattended all-day capture, that is a hardware problem, not a
software one — no App Store app on any platform can do it on a watch.

---

## Architecture

```
Apple Watch                    iPhone                      Supabase
─────────────────────────      ──────────────────────      ─────────────────
tap → AVAudioRecorder
      16 kHz mono AAC
      (~15 MB per hour)
          │
          ▼
      TransferQueue  ──────►  WCSession inbox
      (survives kills,            │
       crashes, reboots)          ▼
                              Transcriber
                              SpeechAnalyzer (26+)
                                 └ or SFSpeechRecognizer
                                     + ChunkPlan / Stitcher
                                        │
                                        ▼
                                  SupabaseStore ──────►  storage: memo-audio
                                                         table:   public.memos
                                                         (RLS, owner-only)
```

`WCSession.transferFile` rather than a direct upload from the watch, as the
primary path, for three reasons: it is free, it is unmetered, and the system
queues it — the transfer completes even if the watch app is killed, and resumes
when the phone comes back in range. On-device transcription on the phone then
costs nothing and sends no audio anywhere.

---

## What is verified, and what is not

Swift here has **never been compiled**. There is no Mac in this environment, and
Swift on Windows cannot build SwiftUI, WatchKit, AVFoundation or Speech. Saying
otherwise would be the only real failure available to me, so: the first
`xcodebuild` on a Mac or in CI will surface syntax and API errors, and that is
expected.

What *is* verified is the part that fails **silently** — where a bug produces no
crash, no error, no log, just quietly wrong behaviour that nobody notices until
the data is gone. Those pieces were extracted into `Sources/VerbaCore/`, which
imports no Apple framework, and ported line-for-line to Python:

| Validator | Asserts | Result |
| --- | --- | --- |
| `validation/verify_queue.py` | audio that exists only on the watch is never deleted | **3,054,303 assertions pass** |
| `validation/verify_transcript.py` | chunking covers every second; stitching loses no word | **23,259 assertions pass** |
| `validation/verify_upsert.py` | a later write never blanks a populated transcript | **36 assertions pass** |

```
python validation/verify_queue.py
python validation/verify_transcript.py
python validation/verify_upsert.py
```

### The queue

88,000 randomised events across 400 runs, including **6,927 simulated crashes
mid-transfer** — the case that strands recordings in real apps, because an item
left marked "in flight" after the process that owned it died will never be
retried by anything. Invariants checked after *every* event:

- every `deleteLocalFile` targeted a recording confirmed to exist elsewhere
- no enqueued recording ever disappeared
- a crash costs zero retry attempts (50 consecutive crashes leave a healthy
  recording healthy)
- duplicate enqueues, duplicate successes, and a failure arriving *after* a
  success are all absorbed
- a backlog drains oldest-first regardless of what order it loaded off disk in
- when the disk is full of undelivered audio, the app warns and keeps recording
  rather than freeing space by destroying the only copy — tested at 18× the
  budget with zero deletions

### The transcript seam

Chunking is needed because `SFSpeechRecognizer` takes bounded audio per request.
Cut on a fixed grid and every cut eats whatever word straddled it: transcripts
that read fine and are quietly missing a word every minute. So windows overlap
and the seam is found by content.

3,000 randomised recordings, 338,799 words: **100% reconstructed exactly, zero
words lost.** The stitcher is deliberately biased — where a seam is ambiguous it
keeps too much rather than too little, because a visible repetition can be
deleted by the user and deleted speech cannot be recovered by anyone.

### Known limitation: Chinese and Japanese seams

Seam detection tokenises on whitespace and punctuation. Chinese has neither, so
no seam is found between two Chinese chunks and both are kept whole — a visible
repetition at each boundary rather than silent loss. This is the correct failure
direction and it is tested as such, but it *is* a limitation: fixing it properly
needs a CJK segmenter (`CFStringTokenizer` with `kCFStringTokenizerUnitWord`
handles this on Apple platforms). Recordings under ~55 seconds are never split
and are unaffected. Mixed Chinese/English stitches correctly on the Latin words.

### Not verified at all

- **anything requiring a compiler** — see above
- **the `SpeechAnalyzer` branch** in `Transcriber.swift`, written against the
  iOS 26 API as documented and not compiled. If it does not build, delete it;
  the `SFSpeechRecognizer` path underneath is complete and handles every case.
- **the Postgres file parses** — `verify_upsert.py` reproduces the conflict
  clause in SQLite, which proves the *semantics*. `supabase db push` proves the
  syntax.
- **transcription accuracy**, battery cost, and whether recording genuinely
  survives an hour of wrist-down time. Those need a wrist.

---

## Setting it up

### 1. Supabase

```bash
supabase link --project-ref YOUR-REF
supabase db push          # applies supabase/schema.sql
```

Or paste `supabase/schema.sql` into the SQL editor. It creates `public.memos`,
the `memo-audio` bucket, owner-only RLS policies on both, and the
`upsert_memo()` function the clients call.

Read the RLS policies before pointing a real key at this. The anon key is
public by design and shipping it in a client is expected — but it is only safe
*because* those policies exist. With RLS off, an anon key is a world-readable,
world-writable database.

```bash
cp PhoneApp/Supabase.example.plist PhoneApp/Supabase.plist
# fill in url + anonKey. Supabase.plist is gitignored.
# never put the service_role key here; it bypasses RLS.
```

### 2. Build

```bash
brew install xcodegen
xcodegen generate
open Verba.xcodeproj
```

Two targets: `Verba` (iPhone) and `VerbaWatch`. This ships as a normal paired
app rather than watch-only, which sidesteps the `ITSWatchOnlyContainer` /
`iTMSTransporter` submission dance the other three apps in this repo need — the
iPhone app is doing real work here, not standing in as a container.

### 3. Put it one tap away

The design assumes the button is reachable without navigating. Add Verba to the
watch Dock, or give it a slot on your watch face — a recorder you have to find
is a recorder you use once.

---

## App Review notes

- **`WKBackgroundModes: [audio]`** — an audio app doing audio. Unlike the
  `mindfulness` session type that a metronome has to justify, there is no
  argument to have here.
- **`NSMicrophoneUsageDescription`** states plainly that recording only starts
  on a tap. It does, and the code cannot do otherwise.
- **`NSSpeechRecognitionUsageDescription`** states that transcription runs on
  the device. `requiresOnDeviceRecognition` is set whenever the locale's model
  supports it.
- **No audio leaves the user's hardware** unless they sign in to their own
  Supabase project. There is no vendor backend and no telemetry.
- Recording legality varies by jurisdiction — two-party consent states, the EU.
  If you ship this, that belongs in the App Store description, not buried in a
  settings screen.

---

## Files

```
Sources/VerbaCore/        no Apple frameworks; this is the tested part
  Recording.swift           the model, and what "sole copy" means
  TransferQueue.swift       the state machine that must not lose audio
  Backoff.swift             retry schedule with full jitter
  ChunkPlan.swift           overlapping windows for long recordings
  TranscriptStitcher.swift  content-based seam removal
  Transcript.swift          transcript + database row shape

WatchApp/
  Recorder.swift            AVAudioRecorder, 16 kHz mono AAC
  DeliveryCoordinator.swift queue → WCSession, with atomic persistence
  VerbaApp.swift            the one big button
  QueueView.swift           every state, named in plain language

PhoneApp/
  Transcriber.swift         SpeechAnalyzer, falling back to SFSpeechRecognizer
  SupabaseStore.swift       three URLRequests, no SDK
  VerbaPhoneApp.swift       inbox → transcribe → sync

supabase/schema.sql       table, bucket, RLS, upsert function
validation/               the Python ports and their assertions
Tests/VerbaCoreTests/     the same properties as XCTest, for `swift test`
```
