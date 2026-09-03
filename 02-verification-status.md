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

## Compile verification (closed)

This section used to say Swift compile errors were possible and unverified. They
were, and the gap is now closed on GitHub Actions `macos-15` with Xcode 16.4.

Final state, [run 33774061649](https://github.com/happym51888/watch-apps/actions/runs/33774061649):

| xcodebuild | | swift test | |
|---|---|---|---|
| KairosWatch | BUILD SUCCEEDED | Kairos | 9 tests, 0 failures |
| Kairos (iOS) | BUILD SUCCEEDED | Tactus | 31 tests, 0 failures |
| TactusWatch | BUILD SUCCEEDED | Awqat | 36 tests, 0 failures |
| AwqatWatch | BUILD SUCCEEDED | Verba | 19 tests, 0 failures |
| VerbaWatch | BUILD SUCCEEDED | | |
| Verba (iOS) | BUILD SUCCEEDED | **total** | **95 tests, 0 failures** |

Eight runs to get there. What the compiler caught that the Python validators
could not, by category:

| Category | Count | Examples |
|---|---|---|
| Module structure | 19 files | `import <App>Core` when XcodeGen compiles sources into the target, so no such module exists |
| Swift 6 data races | 8 | WatchConnectivity `[String: Any]` payloads, `CLHeading`, `CLLocationManager`, `AVCaptureSession`, `ClickPlayer` crossing isolation |
| Actor isolation vs. protocols | 4 | `WKExtendedRuntimeSessionDelegate` is nonisolated, so `@MainActor` members cannot satisfy it |
| API that does not exist | 3 | `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory` — written from documentation, absent from the SDK |
| Type-checker limits | 1 | `SettingsView.body`, five picker sections in one `List` literal |
| Missing conformance | 1 | `TimeSignature` needs `Hashable` for `Picker`; structs get no automatic synthesis |
| Language rules | 3 | `switch` expression as a call argument, `%` on `Double`, bare `catch` shadowing a `@State` property |
| Project config | 2 | Verba declaring the repo root as a SwiftPM package; `group:` keys doubling Tactus source paths |

Four findings are worth keeping in mind beyond this project.

**The CI was reporting success while builds failed.** `continue-on-error: true`
was set on the build and test steps during bring-up, deliberately, so a single
run would return every app's errors instead of stopping at the first. Run 5 then
reported 11/11 jobs green while two builds were in fact failing. A gate that
cannot fail is not a gate; both flags are removed. The per-app matrix already
gives the "see all errors at once" benefit without lying about the result.

**Two test failures were the test's fault, not the code's.** Awqat's Julian Day
assertions failed at 2436115.5 vs. an expected 2436116.5. Meeus example 7.a is
stated for 1957 October 4**.81** → JD 2436116.31, so midnight is 2436115.5; the
expectation had conflated the worked example's fractional day with 0h. The
second expectation, 2461469.5, is 2027-03-05, not the 2026-02-28 it claimed.
Both were checked against Python's proleptic Gregorian ordinal anchored on the
Unix epoch before touching anything — the implementation was right, and
`verify_astronomy.py` reproducing 36 published prayer times could not have
survived a one-day error in the date conversion.

**A build broke on a comment.** Renaming Tactus's bundle identifier with
PowerShell's `Set-Content` rewrote `project.yml` in the machine's ANSI code
page, truncating three em-dashes from `e2 80 94` to `e2 80`. Every local signal
said the change was fine — the file read correctly in an editor, `git add` took
it, the diff was two plausible lines — and XcodeGen on the runner then refused
to open the file at all. The functional content was never wrong. This is the
same shape as everything else on this list: no error where the mistake happened,
an error a long way away. `tools/check_encoding.py` now asserts every tracked
text file is UTF-8 without a BOM, and `tools/test_check_encoding.py` reproduces
both failures and asserts the checker reports them. That self-test paid for
itself on its first run by catching a bug in the checker: printing a decode
error crashed with `UnicodeEncodeError` on a GBK console, so the check exited
non-zero and explained nothing.

**Three of the four apps could not be installed, and six green builds said
otherwise.** Adding a job that installs each watch app on a simulator and
photographs it found that Kairos, Awqat and Verba produced bundles with no
`CFBundleIdentifier`. Those three point at a hand-written `INFOPLIST_FILE`;
Tactus uses XcodeGen's `info:` block. XcodeGen synthesises the identity keys
into a plist it generates and leaves a hand-written one exactly as written, and
Xcode does not add them either. Tactus passed only because it was written
differently, which is the sole reason the difference was visible.

This is the most expensive kind of defect in the set: `xcodebuild` reported
success, `swift test` reported success, and the artefact was unusable. Nothing
short of installing it would have said so. All seven hand-written plists — the
two iPhone apps and three complications had the same hole — now declare the
identity keys, and `tools/check_infoplists.py` asserts it statically, because
the simulator job only ever installs the four watch apps.

The diagnosis cost more than the fix. `simulator_smoke.sh` read the identifier
with `BUNDLE_ID="$(plutil -extract ...)"`; plutil wrote its complaint to
stdout, command substitution captured it into the variable, and `set -e` ended
the run. The log showed the app path, then nothing, then a non-zero exit. The
script now captures and prints that message, validates the identifier's shape
rather than merely its emptiness, and carries an `ERR` trap that names the
failing line and command.

## Residual risk
- **Untestable-here by nature:** actual haptic feel, whether `WKExtendedRuntimeSession`
  survives a real hour on real hardware, complication refresh budget in practice,
  battery drain, and App Review's opinion of the session type a metronome declares.
  These need a physical Apple Watch.

## Reproducing the build

CI does this on every push (see `.github/workflows/build.yml`). On a Mac:

```sh
brew install xcodegen
cd apps/Kairos && xcodegen generate && xcodebuild -scheme KairosWatch -destination 'generic/platform=watchOS' build
cd ../Tactus   && xcodegen generate && xcodebuild -scheme TactusWatch -destination 'generic/platform=watchOS' build
cd ../Awqat    && xcodegen generate && xcodebuild -scheme AwqatWatch  -destination 'generic/platform=watchOS' build
cd ../Verba    && xcodegen generate && xcodebuild -scheme VerbaWatch  -destination 'generic/platform=watchOS' build
```

And the Swift test suites:

```sh
for app in Kairos Tactus Awqat Verba; do (cd "apps/$app" && swift test); done
```

Both packages are plain SwiftPM libraries with no Apple-framework dependencies,
so `swift test` works on macOS or on any Linux/Windows box that has a complete
Swift toolchain.
