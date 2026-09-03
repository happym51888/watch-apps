import XCTest
@testable import KairosCore

#if canImport(CryptoKit)

/// The published RFC vectors, as executable tests.
///
/// These are not illustrative. They are the entire safety net for an app whose
/// failure mode is a website saying "that code is wrong" with no further
/// explanation, and where the user will always assume the fault is theirs.
final class OTPVectorTests: XCTestCase {

    private let hmac = CryptoKitHMAC()

    /// RFC 6238 uses a *different seed length per algorithm*. Reusing the
    /// 20-byte SHA-1 seed for all three is the classic way to appear to pass
    /// this table while being wrong; erratum 2866 spells out the intent.
    private let seeds: [OTPAlgorithm: [UInt8]] = [
        .sha1: Array("12345678901234567890".utf8),
        .sha256: Array("12345678901234567890123456789012".utf8),
        .sha512: Array("1234567890123456789012345678901234567890123456789012345678901234".utf8)
    ]

    // MARK: - RFC 4226 Appendix D

    func testHOTPMatchesRFC4226AppendixD() {
        let secret = Array("12345678901234567890".utf8)
        let published = [
            "755224", "287082", "359152", "969429", "338314",
            "254676", "287922", "162583", "399871", "520489"
        ]

        for (counter, expected) in published.enumerated() {
            let actual = OTP.hotp(key: secret, counter: UInt64(counter), hmac: hmac)
            XCTAssertEqual(actual, expected, "HOTP counter \(counter)")
        }
    }

    // MARK: - RFC 6238 Appendix B

    func testTOTPMatchesRFC6238AppendixB() {
        // (unix time, SHA1, SHA256, SHA512), all at 8 digits with a 30s step.
        let published: [(TimeInterval, String, String, String)] = [
            (59, "94287082", "46119246", "90693936"),
            (1111111109, "07081804", "68084774", "25091201"),
            (1111111111, "14050471", "67062674", "99943326"),
            (1234567890, "89005924", "91819424", "93441116"),
            (2000000000, "69279037", "90698825", "38618901"),
            (20000000000, "65353130", "77737706", "47863826")
        ]

        for (unixTime, sha1, sha256, sha512) in published {
            let date = Date(timeIntervalSince1970: unixTime)
            let expectations: [(OTPAlgorithm, String)] = [
                (.sha1, sha1), (.sha256, sha256), (.sha512, sha512)
            ]
            for (algorithm, expected) in expectations {
                let actual = OTP.totp(
                    key: seeds[algorithm]!,
                    date: date,
                    period: 30,
                    digits: 8,
                    algorithm: algorithm,
                    hmac: hmac
                )
                XCTAssertEqual(actual, expected, "TOTP \(algorithm.rawValue) at t=\(unixTime)")
            }
        }
    }

    /// `07081804` is in the table above precisely because leading zeros are the
    /// most commonly shipped bug in this algorithm: format the code as an
    /// integer and one login in ten silently fails.
    func testLeadingZerosSurvive() {
        let date = Date(timeIntervalSince1970: 1111111109)
        let code = OTP.totp(
            key: seeds[.sha1]!, date: date, period: 30, digits: 8, hmac: hmac
        )
        XCTAssertEqual(code, "07081804")
        XCTAssertEqual(code.count, 8)
        XCTAssertTrue(code.hasPrefix("0"))
    }

    func testEveryCodeHasExactlyTheRequestedDigitCount() {
        for digits in 6...8 {
            for algorithm in OTPAlgorithm.allCases {
                for counter in UInt64(0)..<200 {
                    let code = OTP.hotp(
                        key: seeds[algorithm]!,
                        counter: counter,
                        digits: digits,
                        algorithm: algorithm,
                        hmac: hmac
                    )
                    XCTAssertEqual(code.count, digits)
                    XCTAssertTrue(code.allSatisfy(\.isNumber))
                }
            }
        }
    }

    // MARK: - Time handling

    func testCounterAdvancesExactlyOncePerPeriod() {
        for period in [15, 30, 60, 90] {
            let base = 1_700_000_000 - (1_700_000_000 % TimeInterval(period))
            let start = Date(timeIntervalSince1970: base)
            let justBefore = Date(timeIntervalSince1970: base + TimeInterval(period) - 0.001)
            let next = Date(timeIntervalSince1970: base + TimeInterval(period))

            XCTAssertEqual(
                OTP.counter(at: start, period: period),
                OTP.counter(at: justBefore, period: period),
                "counter must not move inside a step (period \(period))"
            )
            XCTAssertEqual(
                OTP.counter(at: next, period: period),
                OTP.counter(at: start, period: period) + 1,
                "counter must advance by exactly one (period \(period))"
            )
        }
    }

    /// The countdown ring must never read zero. At a step boundary the *new*
    /// code has a full period ahead of it, and returning 0 there makes the ring
    /// blink empty for a frame.
    func testCountdownStaysInsideTheOpenInterval() {
        for period in [15, 30, 60] {
            let base = 1_700_000_000 - (1_700_000_000 % TimeInterval(period))
            for offset in 0..<(period * 2) {
                let date = Date(timeIntervalSince1970: base + TimeInterval(offset))
                let remaining = OTP.secondsRemaining(at: date, period: period)
                XCTAssertGreaterThan(remaining, 0)
                XCTAssertLessThanOrEqual(remaining, Double(period))
            }
            XCTAssertEqual(
                OTP.secondsRemaining(at: Date(timeIntervalSince1970: base), period: period),
                Double(period),
                accuracy: 1e-9
            )
        }
    }

    /// Codes generated within one step of the server's clock still authenticate
    /// against the usual +/-1 step window. This is the number the settings
    /// screen quotes, so it is pinned here.
    func testGuaranteedClockSkewTolerance() {
        let period = 30
        for phase in 0..<period {
            let base = 1_700_000_000 - (1_700_000_000 % TimeInterval(period)) + TimeInterval(phase)
            let server = OTP.counter(at: Date(timeIntervalSince1970: base), period: period)
            for skew in [-30, 30] {
                let drifted = OTP.counter(
                    at: Date(timeIntervalSince1970: base + TimeInterval(skew)), period: period
                )
                let steps = Int(drifted) - Int(server)
                XCTAssertLessThanOrEqual(
                    abs(steps), 1,
                    "30s of drift must stay inside a one-step window (phase \(phase))"
                )
            }
        }
    }

    // MARK: - Truncation

    /// RFC 4226 §5.3 masks the high bit of the first selected byte. Dropping
    /// that mask produces correct codes most of the time and wrong ones
    /// whenever that byte happens to be >= 0x80, which is the worst possible
    /// bug shape: intermittent and unreproducible.
    func testDynamicTruncationMasksTheSignBit() {
        var digest = [UInt8](repeating: 0, count: 20)
        digest[19] = 0x00           // offset 0
        digest[0] = 0xFF            // high bit set, must be masked to 0x7F
        digest[1] = 0xFF
        digest[2] = 0xFF
        digest[3] = 0xFF
        // 0x7FFFFFFF = 2147483647, last six digits 483647
        XCTAssertEqual(OTP.truncate(digest: digest, digits: 6), "483647")
        XCTAssertEqual(OTP.truncate(digest: digest, digits: 10), "2147483647")
    }

    func testDynamicTruncationUsesTheOffsetFromTheFinalNibble() {
        var digest = [UInt8](repeating: 0, count: 20)
        digest[19] = 0x0A           // offset 10
        digest[10] = 0x00
        digest[11] = 0x00
        digest[12] = 0x01
        digest[13] = 0x02           // 0x00000102 = 258
        XCTAssertEqual(OTP.truncate(digest: digest, digits: 6), "000258")
    }
}

#endif
