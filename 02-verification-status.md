# Verification status

Recorded 2026-09-03. Read this before trusting any code in `apps/`.

## What the local machine can and cannot do

| Check | Status | Detail |
| --- | --- | --- |
| Swift toolchain present | Yes | Swift 6.3.3, `x86_64-unknown-windows-msvc`, installed via winget |
| Compile Swift | **No** | `swiftc -typecheck` fails with `unable to load standard library for target 'x86_64-unknown-windows-msvc'`. The Windows Swift stdlib resolves through the Windows SDK module maps, so it needs MSVC + the Windows SDK present. |
| Run `swift test` | **No** | SwiftPM refuses first: `toolchain is invalid: could not find CLI tool 'link'`. |
| Install MSVC build tools | **No** | `winget install Microsoft.VisualStudio.2022.BuildTools` exits 1602. The shell is not elevated, and Visual Studio Build Tools requires administrator rights. |
| Compile SwiftUI / WatchKit | **No, and never** | Those frameworks ship only in the Apple SDKs. This is not a Windows configuration problem; it needs macOS + Xcode 27 regardless. |
| Build/run a watchOS app | **No** | Requires Xcode on macOS. |

So: **the Swift sources in `apps/` are unexecuted.** The Swift test suites under
`Tests/` are written and complete but have never been run.

## What was verified, and how

Since the Swift could not be executed, the parts where a mistake would be
expensive were re-implemented as faithful line-for-line ports and executed. This
verifies the **algorithms and constants**, not the Swift syntax or types.

### Prayer-time astronomy — `apps/Awqat/validation/verify_astronomy.py`

Validated against 36 prayer times published by the AlAdhan API, an independent
implementation, fetched 2026-09-03. Six locations chosen to exercise the
branches that actually break: a midsummer high-latitude case where both Fajr and
Isha lose their astronomical solution, a midwinter case, an equatorial case, a
southern-hemisphere case, both Asr schools, and a fixed-interval Isha rule.

```
RESULT: PASS        largest disagreement: 60s
```

30 of 36 times agree exactly. The six that differ are all Asr, and the cause was
run down rather than waved away: taking each published Asr time and backing out
the shadow factor it implies gives 0.98–0.99 for AlAdhan's standard-school times
against a declared 1.0, while this engine solves for 1.0000 exactly.

```
  case                               declared   aladhan    awqat
  London 2026-06-15 MWL standard          1.0    0.9946   1.0000
  New York 2026-01-15 ISNA standard       1.0    0.9803   1.0000
  Jakarta 2026-09-20 MWL Hanafi           2.0    1.9928   2.0000
  Sydney 2026-07-05 MWL standard          1.0    0.9911   1.0000
  Cairo 2026-11-12 Egyptian Hanafi        2.0    2.0136   2.0000
  Makkah 2026-03-10 Umm al-Qura           1.0    0.9846   1.0000
```

Standard-school Asr sits nearer solar noon, where the sun's altitude changes
slowly, so a small angular approximation becomes a visible time difference —
which is exactly why the two Hanafi cases agree and the four standard cases do
not. The engine is the more faithful of the two to the shadow definition. It is
still worth saying plainly in the app that times can differ from a local mosque
by a minute, which is what the per-prayer offsets are for.

One real gap, deliberately left: Umm al-Qura moves Isha to Maghrib + 120 minutes
during Ramadan. The engine has no Hijri calendar and does not do this. The test
`testUmmAlQuraUsesFixedIntervalAfterMaghrib` asserts the plain 90-minute rule so
the gap is recorded rather than hidden.

### Metronome timing and haptic planning — `apps/Tactus/validation/verify_haptic_plan.py`

```
Property 1: haptic rate limit is never violated
  swept 60960 configurations
  tightest gap anywhere: 0.3409s (floor 0.34s)
Property 4: pulse offsets do not drift
  after 8220 pulses (60 min at 137bpm): indexed offset error 0.00e+00s,
  accumulating loop error 2.01e-10s
...
61233 assertions
RESULT: PASS
```

The sweep is the important one. It covers every integer tempo from 20 to 400 bpm
against 8 time signatures, 4 subdivision levels and 5 accent patterns, and
asserts that no configuration anywhere schedules two haptics closer than the
Taptic Engine can render them. That is precisely the failure the shipping watch
metronomes exhibit in their reviews.

## Residual risk

- **Swift compile errors are possible** in all `Sources/` and `Tests/` files, and
  in the not-yet-written SwiftUI layer. First build on a Mac will surface them.
  The logic underneath is verified; the transcription is not.
- **Untestable-here by nature:** actual haptic feel, whether `WKExtendedRuntimeSession`
  survives a real hour on real hardware, complication refresh budget in practice,
  battery drain, and App Review's opinion of the session type a metronome declares.
  These need a physical Apple Watch.

## To close the gap

On a Mac with Xcode 27:

```sh
brew install xcodegen
cd apps/Awqat && xcodegen generate && xcodebuild -scheme AwqatWatch -destination 'generic/platform=watchOS' build
cd ../Tactus && xcodegen generate && xcodebuild -scheme TactusWatch -destination 'generic/platform=watchOS' build
```

And run the Swift test suites, which are the real gate:

```sh
cd apps/Awqat  && swift test
cd ../Tactus   && swift test
```

Both packages are plain SwiftPM libraries with no Apple-framework dependencies,
so `swift test` works on macOS or on any Linux/Windows box that has a complete
Swift toolchain.
