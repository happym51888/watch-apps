import Foundation

/// The hash a given account's codes are built on. Effectively everyone uses
/// SHA-1 — RFC 6238 §1.2 keeps it because HOTP mandated it, and it is safe here
/// since HMAC-SHA1 is not broken by the SHA-1 collision work — but Steam,
/// several banks and some enterprise SSO issue SHA-256 or SHA-512 secrets, and
/// an authenticator that silently assumes SHA-1 will produce six wrong digits
/// with no explanation.
public enum OTPAlgorithm: String, Sendable, CaseIterable, Codable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    /// Output size of the underlying hash, in bytes. Needed because dynamic
    /// truncation indexes off the *last* byte of the digest.
    public var digestByteCount: Int {
        switch self {
        case .sha1: 20
        case .sha256: 32
        case .sha512: 64
        }
    }
}

/// HMAC is the one primitive this package will not implement itself. On Apple
/// platforms it is supplied by CryptoKit (see `CryptoKitHMAC` in the app
/// target); tests inject a reference implementation. Keeping it behind a
/// protocol is what lets the rest of the OTP chain be tested with no framework
/// dependency at all.
public protocol HMACProviding: Sendable {
    func authenticationCode(
        for message: [UInt8],
        key: [UInt8],
        algorithm: OTPAlgorithm
    ) -> [UInt8]
}

/// RFC 4226 HOTP and RFC 6238 TOTP.
///
/// Both RFCs publish test vectors, and `validation/verify_totp.py` checks this
/// exact chain against all of them. That matters more than usual here: a
/// metronome that is subtly wrong feels wrong, but an authenticator that is
/// subtly wrong just says "invalid code" and the user blames the website.
public enum OTP {

    /// RFC 4226 §5.3. Truncate a digest down to `digits` decimal digits.
    ///
    /// The "dynamic" part is that the offset is read from the low nibble of the
    /// final byte, so which four bytes get used varies per counter value.
    public static func truncate(digest: [UInt8], digits: Int) -> String {
        precondition(digest.count >= 20, "digest too short for dynamic truncation")
        precondition((6...10).contains(digits), "OTP digit counts outside 6...10 are not defined")

        let offset = Int(digest[digest.count - 1] & 0x0F)

        // Mask the high bit so the result is a positive 31-bit integer
        // regardless of the platform's signed-int behaviour. RFC 4226 is
        // explicit about this and it is the single most commonly botched line
        // in a hand-rolled HOTP.
        let binary =
            (UInt32(digest[offset] & 0x7F) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])

        // 10^10 exceeds UInt32.max, so the modulus and the remainder are both
        // 64-bit even though `binary` is only 31 bits wide.
        let code = UInt64(binary) % pow10(digits)

        // Leading zeros are significant: 000123 is a valid six-digit code, and
        // trimming it is a classic bug that makes roughly 1-in-10 codes fail.
        // Padding by hand rather than with `String(format:)` avoids the
        // width/type mismatch between `%u` and a 64-bit value.
        let rendered = String(code)
        return rendered.count >= digits
            ? rendered
            : String(repeating: "0", count: digits - rendered.count) + rendered
    }

    /// RFC 4226 HOTP: a code for an explicit counter value.
    public static func hotp(
        key: [UInt8],
        counter: UInt64,
        digits: Int = 6,
        algorithm: OTPAlgorithm = .sha1,
        hmac: some HMACProviding
    ) -> String {
        // Counter is always 8 bytes, big-endian, regardless of algorithm.
        var message = [UInt8](repeating: 0, count: 8)
        var value = counter
        for index in stride(from: 7, through: 0, by: -1) {
            message[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        let digest = hmac.authenticationCode(for: message, key: key, algorithm: algorithm)
        return truncate(digest: digest, digits: digits)
    }

    /// The counter a TOTP code is derived from at a given instant.
    ///
    /// `floor((unixTime - epoch) / period)`. Split out from `totp` because the
    /// UI needs it too: the countdown ring is driven by where we are inside the
    /// current step, and the "next code" preview needs `counter + 1`.
    public static func counter(
        at date: Date,
        period: Int,
        epoch: TimeInterval = 0
    ) -> UInt64 {
        precondition(period > 0, "period must be positive")
        let elapsed = date.timeIntervalSince1970 - epoch
        // Times before the epoch are not meaningful for TOTP; clamp rather
        // than trap, because a user with a badly wrong clock should see wrong
        // codes, not a crash.
        guard elapsed > 0 else { return 0 }
        return UInt64(floor(elapsed / Double(period)))
    }

    /// RFC 6238 TOTP: a code for a point in time.
    public static func totp(
        key: [UInt8],
        date: Date,
        period: Int = 30,
        digits: Int = 6,
        algorithm: OTPAlgorithm = .sha1,
        epoch: TimeInterval = 0,
        hmac: some HMACProviding
    ) -> String {
        hotp(
            key: key,
            counter: counter(at: date, period: period, epoch: epoch),
            digits: digits,
            algorithm: algorithm,
            hmac: hmac
        )
    }

    /// Seconds until the current code expires, in `(0, period]`.
    ///
    /// Never returns 0: at the exact instant of a step boundary the *new* code
    /// has a full period ahead of it. Returning 0 would make the UI flash an
    /// empty ring for one frame.
    public static func secondsRemaining(
        at date: Date,
        period: Int,
        epoch: TimeInterval = 0
    ) -> Double {
        precondition(period > 0, "period must be positive")
        let elapsed = date.timeIntervalSince1970 - epoch
        let intoStep = elapsed.truncatingRemainder(dividingBy: Double(period))
        let remaining = Double(period) - intoStep
        return remaining <= 0 ? Double(period) : remaining
    }

    /// 10^n without going through `Foundation.pow`, which returns a Double and
    /// starts losing integer precision exactly where 10-digit codes live.
    /// Returns 64-bit because 10^10 does not fit in a `UInt32`.
    private static func pow10(_ exponent: Int) -> UInt64 {
        var result: UInt64 = 1
        for _ in 0..<exponent { result *= 10 }
        return result
    }
}
