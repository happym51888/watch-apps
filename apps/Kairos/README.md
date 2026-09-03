# Kairos — two-factor codes on your wrist, with the phone switched off

## Why this app

This is the best-evidenced of the three, because the demand is countable rather
than anecdotal. Two long-running feature requests, both still open, both with no
maintainer resolution:

> it would be nice to have an apple watch app for authenticator so people can
> find their auth codes without pulling out their phone

— 78 reactions, open since 2017, zero maintainer replies. A parallel request on
another authenticator carries 33.

And the incumbent's weakness is stated with unusual precision by its own users:
OTP Auth's watch app requires the paired iPhone to be *unlocked*, "which defeats
the purpose of using the watch." If you have to unlock your phone to read a code
off your watch, you have already done the thing the watch was supposed to save
you from.

That is the entire product thesis, and it is a small one on purpose: **enrol
once from the phone, then never need the phone again.** Kairos stores the secret
in the watch's own keychain and computes HMAC locally. The phone can be off,
flat, in a locker, or in another country.

The wider theme showed up independently across nine sources during research —
people wanting to leave the phone behind, in the gym, on a run, at a desk. This
is the version of that theme with the cleanest technical shape: pure local
computation, no backend, no network permission, no background execution, no
sensor access, nothing to subscribe to.

## The security decisions, stated plainly

These are the product, so they are not buried in the code.

**Secrets never leave the watch.** Keychain items are written with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. `WhenUnlocked` makes them
unreadable while the watch is off your wrist and locked. `ThisDeviceOnly`
excludes them from encrypted backups and from iCloud Keychain. A TOTP secret
that syncs is a TOTP secret that can be pulled off a second device, which is
most of the way to not having a second factor at all.

**The complication does not show a code.** It is a launcher. A live code on the
always-on display is legible to anyone who glances at your wrist, and it is in
every photo you appear in. One tap is still faster than a phone.

**No crypto was hand-rolled.** HMAC comes from CryptoKit via `CryptoKitHMAC`. The
core package does not import it directly — it takes an `HMACProviding` — which is
what keeps the rest of the logic testable without a Mac, but the production path
is always Apple's implementation. `Insecure.SHA1` is correct here despite the
name: RFC 6238 §1.2 mandates SHA-1 as the default, and the SHA-1 collision work
does not affect HMAC-SHA1.

**No network entitlement, no analytics, no account.** There is nothing to breach
and nothing to configure.

## Layout

```
Package.swift                 SwiftPM library, so the logic runs anywhere
Sources/KairosCore/
  Base32.swift                RFC 4648 decode, tolerant of human typing
  OTP.swift                   RFC 4226 HOTP + RFC 6238 TOTP
  OTPAuthURI.swift            otpauth:// Key URI parser
  Account.swift               Model + display formatting
  CryptoKitHMAC.swift         Production HMAC, behind `canImport(CryptoKit)`
Tests/KairosCoreTests/        The RFC vectors, as tests
WatchApp/                     SwiftUI, Keychain, WatchConnectivity receive
PhoneApp/                     QR scanning and enrolment only
Complication/                 Launcher widget
validation/verify_totp.py     Executable proof — see below
project.yml                   XcodeGen spec
```

## Build

```sh
brew install xcodegen
xcodegen generate
open Kairos.xcodeproj
```

Set your Team ID in `project.yml`, or pick a team in Xcode's Signing pane. The
keychain access group in `WatchApp/Kairos.entitlements` will pick up your team
prefix automatically.

Logic tests, no Mac needed:

```sh
swift test
```

## Verification status

**The Swift here has never been compiled** — it was written on Windows, where
the toolchain cannot load its own standard library without the Windows SDK.
Expect to fix compile errors on the first build.

The algorithm, though, is checked against the published vectors:

```sh
python validation/verify_totp.py
```

```
Property 2: HOTP matches RFC 4226 Appendix D
  counter 0  ->  755224   (RFC: 755224)
  ...
Property 3: TOTP matches RFC 6238 Appendix B
     unix time        SHA1      SHA256      SHA512
            59    94287082    46119246    90693936
    1111111109    07081804    68084774    25091201
  ...
RESULT: PASS  (47954 assertions)
```

That covers all 10 RFC 4226 HOTP values, all 18 RFC 6238 TOTP values across
three hash algorithms, all 7 RFC 4648 base32 vectors, 18,000 generated codes
checked for digit count and leading zeros, and 16 `otpauth://` shapes including
the ones that fail silently.

Three specifics worth calling out, because each is a bug that ships and then
fails intermittently in a way nobody can reproduce:

- **Leading zeros.** `07081804` is in the RFC table for exactly this reason.
  Format the code as an integer and one login in ten fails.
- **The sign-bit mask.** RFC 4226 §5.3 masks the high bit of the first selected
  byte. Omit it and codes are correct except when that byte is ≥ 0x80.
- **Per-algorithm seed lengths.** RFC 6238's SHA-256 and SHA-512 rows use 32-
  and 64-byte seeds. Using the 20-byte SHA-1 seed for all three is the standard
  way to appear to pass the table while being wrong.

The Python port also found the limit of its own usefulness: Python's integers
are arbitrary-precision, so it happily computed `10**10` where Swift's `UInt32`
would have trapped on any 10-digit account. That one was caught while writing
the Swift test, not by the port, and is now pinned in both.

What still needs a real watch: keychain behaviour across a lock/unlock cycle,
WatchConnectivity delivery when the watch is on a charger, and whether the
crown-scrolled list is comfortable with twenty accounts on a 41mm screen.

## App Review notes

Kairos is a normal iPhone app with a watch app, so none of the watch-only
`ITSWatchOnlyContainer` wrapping that Tactus and Awqat need applies. That is
partly why it was chosen: the phone app is the storefront, which also solves the
discoverability problem that watch-only apps have.

Two things reviewers will look at:

- **Camera permission on a security app.** `NSCameraUsageDescription` says what
  it is for and that nothing is stored. `ScannerView` takes no photo and retains
  no frame; the decoded string goes to the parser and then over
  WatchConnectivity.
- **No background modes are declared at all.** Codes are computed on demand.
  Nothing needs to stay alive.

## Deliberately not in v1

- **Encrypted export / restore.** Right now, losing the watch loses the accounts
  on it, and the phone app holds no copy either. This is the most important gap
  and the first thing to build; it needs a passphrase-wrapped export, which
  needs care rather than speed.
- **Reading codes on the phone.** The phone app enrols and forwards, nothing
  more. Making it a full authenticator doubles the attack surface for a feature
  every user already has elsewhere.
- **Steam's custom alphabet.** Steam guard codes use five characters from a
  non-decimal alphabet. `OTP.truncate` is decimal-only; supporting Steam means a
  separate rendering path.
- **Reordering and folders.** `sortIndex` exists and is honoured; there is no UI
  to change it yet.
- **iCloud sync.** Not an oversight. See the security section.
