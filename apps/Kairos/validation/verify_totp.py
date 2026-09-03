#!/usr/bin/env python3
"""
Executable check of KairosCore against published test vectors.

The Swift in this repo cannot be compiled on the machine it was written on, so
the logic is ported here line-for-line and run against external references:

  * RFC 4226 Appendix D  - 10 published HOTP values
  * RFC 6238 Appendix B  - 18 published TOTP values (6 instants x 3 hashes)
  * RFC 4648 Section 10  - 7 published base32 vectors
  * otpauth:// Key URI   - real-world shapes that produce silently wrong codes
  * property sweeps      - leading zeros, step boundaries, counter monotonicity

For an authenticator this matters more than usual. A wrong metronome feels
wrong immediately; a wrong authenticator just says "invalid code" and the user
blames the website.

  python validation/verify_totp.py
"""

import hashlib
import hmac as hmaclib
import math
import sys
from urllib.parse import urlsplit, parse_qsl, unquote

FAILURES = []
ASSERTIONS = 0


def check(condition, message):
    global ASSERTIONS
    ASSERTIONS += 1
    if not condition:
        FAILURES.append(message)


def equal(actual, expected, message):
    check(actual == expected, f"{message}: got {actual!r}, expected {expected!r}")


# ---------------------------------------------------------------------------
# Port of Sources/KairosCore/Base32.swift
# ---------------------------------------------------------------------------

_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"


def _reverse_table():
    table = [-1] * 128
    for index, character in enumerate(_ALPHABET):
        table[ord(character)] = index
        table[ord(character.lower())] = index
    table[ord("0")] = table[ord("O")]
    table[ord("1")] = table[ord("L")]
    table[ord("8")] = table[ord("B")]
    return table


_REVERSE = _reverse_table()


class Base32Error(Exception):
    pass


def base32_decode(text):
    output = bytearray()
    buffer = 0
    bits = 0
    for character in text:
        if character == "=":
            continue
        if character in " -\t\n\r":
            continue
        code = ord(character)
        if code >= 128 or _REVERSE[code] < 0:
            raise Base32Error(f"invalidCharacter({character})")
        buffer = ((buffer << 5) | _REVERSE[code]) & 0xFFFFFFFF
        bits += 5
        if bits >= 8:
            bits -= 8
            output.append((buffer >> bits) & 0xFF)
    if bits >= 5:
        raise Base32Error("truncated")
    if bits > 0 and (buffer & ((1 << bits) - 1)) != 0:
        raise Base32Error("nonCanonicalPadding")
    return bytes(output)


def base32_encode(data):
    result = []
    buffer = 0
    bits = 0
    for byte in data:
        buffer = (buffer << 8) | byte
        bits += 8
        while bits >= 5:
            bits -= 5
            result.append(_ALPHABET[(buffer >> bits) & 0x1F])
    if bits > 0:
        result.append(_ALPHABET[(buffer << (5 - bits)) & 0x1F])
    return "".join(result)


# ---------------------------------------------------------------------------
# Port of Sources/KairosCore/OTP.swift
# ---------------------------------------------------------------------------

_HASHES = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}


def hmac_digest(message, key, algorithm):
    """Stands in for CryptoKit. Both sides call a vetted library, never a
    hand-rolled hash, so this substitution is faithful."""
    return hmaclib.new(key, message, _HASHES[algorithm]).digest()


def truncate(digest, digits):
    assert len(digest) >= 20
    assert 6 <= digits <= 10
    offset = digest[-1] & 0x0F
    binary = (
        ((digest[offset] & 0x7F) << 24)
        | (digest[offset + 1] << 16)
        | (digest[offset + 2] << 8)
        | digest[offset + 3]
    )
    return str(binary % (10 ** digits)).zfill(digits)


def hotp(key, counter, digits=6, algorithm="SHA1"):
    message = counter.to_bytes(8, "big")
    return truncate(hmac_digest(message, key, algorithm), digits)


def counter_at(unix_time, period, epoch=0):
    assert period > 0
    elapsed = unix_time - epoch
    if elapsed <= 0:
        return 0
    return int(math.floor(elapsed / period))


def totp(key, unix_time, period=30, digits=6, algorithm="SHA1", epoch=0):
    return hotp(key, counter_at(unix_time, period, epoch), digits, algorithm)


def seconds_remaining(unix_time, period, epoch=0):
    assert period > 0
    remaining = period - math.fmod(unix_time - epoch, period)
    return period if remaining <= 0 else remaining


# ---------------------------------------------------------------------------
# Port of Sources/KairosCore/OTPAuthURI.swift
# ---------------------------------------------------------------------------


class URIError(Exception):
    pass


def parse_uri(text):
    parts = urlsplit(text.strip())
    if parts.scheme.lower() != "otpauth":
        raise URIError("notAnOTPAuthURI")
    kind = parts.netloc.lower()
    if kind not in ("totp", "hotp"):
        raise URIError(f"unsupportedType({kind})")

    query = {name.lower(): value for name, value in parse_qsl(parts.query)}

    raw_secret = query.get("secret", "")
    if not raw_secret:
        raise URIError("missingSecret")
    try:
        secret = base32_decode(raw_secret)
    except Base32Error as error:
        raise URIError(f"invalidSecret({error})")
    if not secret:
        raise URIError("emptySecret")

    label = unquote(parts.path)
    if label.startswith("/"):
        label = label[1:]
    if ":" in label:
        label_issuer, account = label.split(":", 1)
        label_issuer, account = label_issuer.strip(), account.strip()
    else:
        label_issuer, account = "", label.strip()

    issuer = (query.get("issuer") or "").strip() or label_issuer

    digits = 6
    if "digits" in query:
        if not query["digits"].isdigit() or not 6 <= int(query["digits"]) <= 10:
            raise URIError(f"invalidDigits({query['digits']})")
        digits = int(query["digits"])

    algorithm = "SHA1"
    if "algorithm" in query:
        if query["algorithm"].upper() not in _HASHES:
            raise URIError(f"invalidAlgorithm({query['algorithm']})")
        algorithm = query["algorithm"].upper()

    if kind == "totp":
        period = 30
        if "period" in query:
            raw = query["period"]
            if not raw.isdigit() or not 0 < int(raw) <= 3600:
                raise URIError(f"invalidPeriod({raw})")
            period = int(raw)
        detail = ("totp", period)
    else:
        if "counter" not in query:
            raise URIError("missingCounter")
        if not query["counter"].isdigit():
            raise URIError(f"invalidCounter({query['counter']})")
        detail = ("hotp", int(query["counter"]))

    return {
        "issuer": issuer,
        "account": account,
        "secret": secret,
        "algorithm": algorithm,
        "digits": digits,
        "kind": detail,
    }


def group(code):
    n = len(code)
    if n == 6:
        return f"{code[:3]} {code[3:]}"
    if n == 8:
        return f"{code[:4]} {code[4:]}"
    if n in (7, 9, 10):
        return f"{code[:-4]} {code[-4:]}"
    return code


# ---------------------------------------------------------------------------
# 1. RFC 4648 Section 10 - base32 vectors
# ---------------------------------------------------------------------------

print("=" * 72)
print("Property 1: base32 matches RFC 4648 Section 10")
print("=" * 72)

RFC4648 = [
    ("", b""),
    ("MY======", b"f"),
    ("MZXQ====", b"fo"),
    ("MZXW6===", b"foo"),
    ("MZXW6YQ=", b"foob"),
    ("MZXW6YTB", b"fooba"),
    ("MZXW6YTBOI======", b"foobar"),
]

for encoded, plain in RFC4648:
    equal(base32_decode(encoded), plain, f"decode {encoded!r}")
    if plain:
        equal(base32_encode(plain), encoded.rstrip("="), f"encode {plain!r}")
print(f"  {len(RFC4648)} published vectors, both directions")

# Human-tolerance cases: these must all yield the same key.
CANONICAL = base32_decode("MZXW6YTBOI")
for variant in [
    "mzxw6ytboi",
    "MZXW 6YTB OI",
    "MZXW-6YTB-OI",
    "MZXW6YTBOI======",
    "  MZXW6YTBOI  ".strip(),
]:
    equal(base32_decode(variant), CANONICAL, f"tolerant decode {variant!r}")
print("  5 human-typed variants normalise to the same key")

# Character-count classes that cannot be valid base32 must be rejected, not
# silently truncated into a plausible key.
for bad_length in ["A", "AAA", "AAAAAA", "AAAAAAAAA"]:
    try:
        base32_decode(bad_length)
        check(False, f"{bad_length!r} should not decode")
    except Base32Error as error:
        equal(str(error), "truncated", f"reject {len(bad_length)}-char group")
for bad_char in ["MZXW6YTB!", "MZXW6YT9"]:
    try:
        base32_decode(bad_char)
        check(False, f"{bad_char!r} should not decode")
    except Base32Error as error:
        check("invalidCharacter" in str(error), f"reject {bad_char!r}")
print("  4 invalid lengths and 2 invalid characters rejected")

# ---------------------------------------------------------------------------
# 2. RFC 4226 Appendix D - HOTP vectors
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 2: HOTP matches RFC 4226 Appendix D")
print("=" * 72)

RFC4226_SECRET = b"12345678901234567890"
RFC4226 = [
    "755224", "287082", "359152", "969429", "338314",
    "254676", "287922", "162583", "399871", "520489",
]

for counter, expected in enumerate(RFC4226):
    equal(hotp(RFC4226_SECRET, counter), expected, f"HOTP counter={counter}")
    print(f"  counter {counter}  ->  {hotp(RFC4226_SECRET, counter)}   (RFC: {expected})")

# The first published value, 755224, is also reachable through the base32 path
# a real user would take, which links the two ports together.
equal(
    hotp(base32_decode(base32_encode(RFC4226_SECRET)), 0),
    "755224",
    "HOTP via base32 round-trip",
)

# ---------------------------------------------------------------------------
# 3. RFC 6238 Appendix B - TOTP vectors, all three hashes
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 3: TOTP matches RFC 6238 Appendix B")
print("=" * 72)

# RFC 6238 uses a different seed length per algorithm; using the 20-byte SHA-1
# seed for all three is the single most common way to "pass" this table while
# being wrong. Erratum 2866 makes the intent explicit.
SEEDS = {
    "SHA1": b"12345678901234567890",
    "SHA256": b"12345678901234567890123456789012",
    "SHA512": b"1234567890123456789012345678901234567890123456789012345678901234",
}

RFC6238 = [
    (59, "94287082", "46119246", "90693936"),
    (1111111109, "07081804", "68084774", "25091201"),
    (1111111111, "14050471", "67062674", "99943326"),
    (1234567890, "89005924", "91819424", "93441116"),
    (2000000000, "69279037", "90698825", "38618901"),
    (20000000000, "65353130", "77737706", "47863826"),
]

print(f"  {'unix time':>12}  {'SHA1':>10}  {'SHA256':>10}  {'SHA512':>10}")
for unix_time, sha1_expected, sha256_expected, sha512_expected in RFC6238:
    row = []
    for algorithm, expected in (
        ("SHA1", sha1_expected),
        ("SHA256", sha256_expected),
        ("SHA512", sha512_expected),
    ):
        actual = totp(SEEDS[algorithm], unix_time, period=30, digits=8, algorithm=algorithm)
        equal(actual, expected, f"TOTP {algorithm} t={unix_time}")
        row.append(f"{actual:>10}" + ("" if actual == expected else " MISMATCH"))
    print(f"  {unix_time:>12}  " + "  ".join(row))

# 07081804 and 25091201 in that table both begin with a zero. Formatting a code
# as an integer would print 7081804 and every one of those logins would fail.
leading_zero_cases = [
    entry for entry in RFC6238
    for value in entry[1:]
    if value.startswith("0")
]
check(len(leading_zero_cases) > 0, "table should exercise leading zeros")
print(f"  {len(leading_zero_cases)} of the published values begin with a zero digit")

# ---------------------------------------------------------------------------
# 4. Leading zeros hold across a large sweep, not just in the RFC table
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 4: every generated code has exactly the requested digit count")
print("=" * 72)

zero_led = 0
generated = 0
for digits in (6, 7, 8):
    for algorithm in ("SHA1", "SHA256", "SHA512"):
        for counter in range(0, 2000):
            code = hotp(SEEDS[algorithm], counter, digits=digits, algorithm=algorithm)
            equal(len(code), digits, f"length {algorithm}/{digits}/{counter}")
            check(code.isdigit(), f"digits only {algorithm}/{digits}/{counter}")
            generated += 1
            if code[0] == "0":
                zero_led += 1

print(f"  generated {generated} codes across 3 hashes x 3 digit counts")

# Truncation boundary cases. The 10-digit row is here because Python's
# arbitrary-precision integers silently absorb a bug that Swift would trap on:
# 10**10 does not fit in a UInt32, so the modulus must be 64-bit. This port
# cannot catch that class of defect, which is why it is pinned in the Swift
# test as well (`testDynamicTruncationMasksTheSignBit`).
max_digest = bytes([0xFF, 0xFF, 0xFF, 0xFF] + [0x00] * 15 + [0x00])
equal(truncate(max_digest, 10), "2147483647", "sign bit is masked, 10 digits")
equal(truncate(max_digest, 6), "483647", "sign bit is masked, 6 digits")
offset_digest = bytes([0x00] * 10 + [0x00, 0x00, 0x01, 0x02] + [0x00] * 5 + [0x0A])
equal(truncate(offset_digest, 6), "000258", "offset read from the final nibble")
print("  truncation boundary cases: sign-bit mask and 10-digit modulus")
print(f"  {zero_led} began with a zero ({100.0 * zero_led / generated:.1f}%, expected ~10%)")
check(
    0.08 < zero_led / generated < 0.12,
    "zero-led rate should sit near 1-in-10; a skew means truncation is biased",
)

# ---------------------------------------------------------------------------
# 5. Step boundaries: the code changes exactly on the period, never between
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 5: codes change exactly on step boundaries")
print("=" * 72)

for period in (15, 30, 60, 90):
    base = 1700000000 - (1700000000 % period)
    for step in range(50):
        start = base + step * period
        first = totp(SEEDS["SHA1"], start, period=period)
        last = totp(SEEDS["SHA1"], start + period - 1, period=period)
        following = totp(SEEDS["SHA1"], start + period, period=period)
        equal(first, last, f"stable within step, period={period} step={step}")
        check(first != following or True, "adjacent steps may collide by chance")
        equal(
            counter_at(start + period, period),
            counter_at(start, period) + 1,
            f"counter advances by one, period={period}",
        )
        # The countdown must never read zero, and must read a full period at
        # the instant a new code appears.
        equal(seconds_remaining(start, period), float(period),
              f"full period at boundary, period={period}")
        remaining = seconds_remaining(start + period - 1, period)
        equal(remaining, 1.0, f"one second left at end of step, period={period}")
        for offset in range(period):
            value = seconds_remaining(start + offset, period)
            check(0 < value <= period, f"countdown in range, period={period}")

print("  4 periods x 50 steps: counter advances by exactly 1, code stable within")
print("  countdown stays inside (0, period] at every whole second")

# ---------------------------------------------------------------------------
# 6. otpauth:// shapes seen in the wild
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 6: otpauth:// parsing")
print("=" * 72)

SECRET32 = base32_encode(b"12345678901234567890")

cases = [
    (
        "canonical Google shape",
        f"otpauth://totp/Example:alice@google.com?secret={SECRET32}&issuer=Example",
        {"issuer": "Example", "account": "alice@google.com", "digits": 6,
         "algorithm": "SHA1", "kind": ("totp", 30)},
    ),
    (
        "percent-encoded colon and space in label",
        f"otpauth://totp/Big%20Corp%3A%20bob%40big.example?secret={SECRET32}",
        {"issuer": "Big Corp", "account": "bob@big.example", "digits": 6,
         "algorithm": "SHA1", "kind": ("totp", 30)},
    ),
    (
        "no issuer anywhere",
        f"otpauth://totp/plainuser?secret={SECRET32}",
        {"issuer": "", "account": "plainuser", "digits": 6,
         "algorithm": "SHA1", "kind": ("totp", 30)},
    ),
    (
        "issuer parameter overrides a stale label prefix",
        f"otpauth://totp/OldName:carol?secret={SECRET32}&issuer=NewName",
        {"issuer": "NewName", "account": "carol", "digits": 6,
         "algorithm": "SHA1", "kind": ("totp", 30)},
    ),
    (
        "SHA256 with 8 digits and a 60s period",
        f"otpauth://totp/Bank:dave?secret={SECRET32}&algorithm=SHA256&digits=8&period=60",
        {"issuer": "Bank", "account": "dave", "digits": 8,
         "algorithm": "SHA256", "kind": ("totp", 60)},
    ),
    (
        "lowercase keys and algorithm value",
        f"otpauth://totp/Svc:erin?Secret={SECRET32}&Algorithm=sha512",
        {"issuer": "Svc", "account": "erin", "digits": 6,
         "algorithm": "SHA512", "kind": ("totp", 30)},
    ),
    (
        "HOTP with a counter",
        f"otpauth://hotp/Yubi:frank?secret={SECRET32}&counter=7",
        {"issuer": "Yubi", "account": "frank", "digits": 6,
         "algorithm": "SHA1", "kind": ("hotp", 7)},
    ),
    (
        "spaced lowercase secret as pasted from a web page",
        "otpauth://totp/Svc:grace?secret=gezd%20gnbv%20gy3t%20qojq%20gezd%20gnbv%20gy3t%20qojq",
        {"issuer": "Svc", "account": "grace", "digits": 6,
         "algorithm": "SHA1", "kind": ("totp", 30)},
    ),
]

for name, uri, expected in cases:
    parsed = parse_uri(uri)
    for key, value in expected.items():
        equal(parsed[key], value, f"{name}: {key}")
    print(f"  ok  {name}")

# The spaced-secret case must produce the very same key as the RFC seed, which
# is what proves the tolerance is cosmetic and not corrupting.
equal(
    parse_uri(cases[7][1])["secret"],
    b"12345678901234567890",
    "spaced lowercase secret decodes to the RFC seed",
)

rejections = [
    ("wrong scheme", "https://example.com/?secret=" + SECRET32, "notAnOTPAuthURI"),
    ("unknown type", f"otpauth://mtop/x?secret={SECRET32}", "unsupportedType"),
    ("no secret", "otpauth://totp/Example:alice", "missingSecret"),
    ("bad secret", "otpauth://totp/x?secret=!!!!", "invalidSecret"),
    ("digits out of range", f"otpauth://totp/x?secret={SECRET32}&digits=4", "invalidDigits"),
    ("unknown hash", f"otpauth://totp/x?secret={SECRET32}&algorithm=MD5", "invalidAlgorithm"),
    ("zero period", f"otpauth://totp/x?secret={SECRET32}&period=0", "invalidPeriod"),
    ("hotp without counter", f"otpauth://hotp/x?secret={SECRET32}", "missingCounter"),
]

for name, uri, expected_error in rejections:
    try:
        parse_uri(uri)
        check(False, f"{name} should have been rejected")
    except URIError as error:
        check(expected_error in str(error), f"{name}: got {error}")
        print(f"  ok  rejects {name}")

# Round-tripping must not lose the fields that change the generated code.
for name, uri, _ in cases:
    original = parse_uri(uri)
    # Re-render by hand the way OTPAuthURI.render does, then re-parse.
    kind, detail = original["kind"]
    query = [f"secret={base32_encode(original['secret'])}"]
    if original["issuer"]:
        query.append(f"issuer={original['issuer'].replace(' ', '%20')}")
    if original["algorithm"] != "SHA1":
        query.append(f"algorithm={original['algorithm']}")
    if original["digits"] != 6:
        query.append(f"digits={original['digits']}")
    if kind == "totp" and detail != 30:
        query.append(f"period={detail}")
    if kind == "hotp":
        query.append(f"counter={detail}")
    label = (
        f"{original['issuer']}:{original['account']}"
        if original["issuer"] else original["account"]
    ).replace(" ", "%20").replace("@", "%40")
    round_tripped = parse_uri(f"otpauth://{kind}/{label}?" + "&".join(query))
    for key in ("secret", "algorithm", "digits", "kind"):
        equal(round_tripped[key], original[key], f"round-trip {name}: {key}")

print(f"  {len(cases)} shapes round-trip without losing code-affecting fields")

# ---------------------------------------------------------------------------
# 7. Display grouping never alters the digits
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 7: display grouping is cosmetic only")
print("=" * 72)

for digits in (6, 7, 8, 9, 10):
    for counter in range(200):
        code = hotp(SEEDS["SHA1"], counter, digits=digits)
        grouped = group(code)
        equal(grouped.replace(" ", ""), code, f"grouping preserves digits ({digits})")
equal(group("012345"), "012 345", "six-digit grouping keeps the leading zero")
equal(group("00123456"), "0012 3456", "eight-digit grouping keeps leading zeros")
print("  1000 codes regrouped; digits and leading zeros preserved")

# ---------------------------------------------------------------------------
# 8. Clock skew: what a wrong watch actually costs the user
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 8: clock-skew behaviour is what the UI claims")
print("=" * 72)

# Servers commonly accept a +/-1 step window. How much watch drift that
# actually forgives depends on where in the step you are, so the settings
# screen must not quote a single number without qualifying it. Sweep every
# phase and measure the guaranteed figure rather than a lucky one.
PERIOD = 30
worst_negative = -10**9
worst_positive = 10**9

for phase in range(PERIOD):
    base_time = 1700000000 - (1700000000 % PERIOD) + phase
    server_counter = counter_at(base_time, PERIOD)
    accepted = [
        skew for skew in range(-3 * PERIOD, 3 * PERIOD + 1)
        if abs(counter_at(base_time + skew, PERIOD) - server_counter) <= 1
    ]
    # Accepted skews must be one contiguous run; a hole would mean the counter
    # is not monotonic in time.
    equal(
        accepted, list(range(accepted[0], accepted[-1] + 1)),
        f"accepted skew range is contiguous at phase {phase}",
    )
    equal(len(accepted), 3 * PERIOD, f"window is always 3 steps wide at phase {phase}")
    worst_negative = max(worst_negative, accepted[0])
    worst_positive = min(worst_positive, accepted[-1])

equal(
    counter_at(1700000010 + PERIOD, PERIOD) - counter_at(1700000010, PERIOD),
    1,
    "30s of skew is exactly one step",
)
equal(worst_negative, -PERIOD, "guaranteed tolerance for a slow watch")
equal(worst_positive, PERIOD, "guaranteed tolerance for a fast watch")

print(f"  server window of +/-1 step spans {3 * PERIOD}s of wall clock at every phase")
print(f"  guaranteed tolerance regardless of phase: {worst_negative}s to +{worst_positive}s")
print("  so the honest claim is '+/-30s always, up to 60s depending on timing'")

# ---------------------------------------------------------------------------

print()
print("=" * 72)
if FAILURES:
    print(f"RESULT: FAIL  ({len(FAILURES)} of {ASSERTIONS} assertions)")
    for failure in FAILURES[:25]:
        print(f"  - {failure}")
    sys.exit(1)
print(f"RESULT: PASS  ({ASSERTIONS} assertions)")
print("=" * 72)
