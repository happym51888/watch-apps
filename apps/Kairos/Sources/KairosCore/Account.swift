import Foundation

/// One enrolled account.
///
/// The secret lives here as raw bytes rather than as the base32 string, so that
/// the only place a human-readable secret exists is the moment of enrolment.
/// `Codable` conformance is used to write into the Keychain, never to a plist
/// or `UserDefaults`.
public struct Account: Identifiable, Sendable, Codable, Equatable {

    /// Whether codes advance with the clock (TOTP) or only when the user asks
    /// (HOTP). HOTP is rare but Yubico and a few banks still issue it, and an
    /// authenticator that cannot import one is just broken from the user's
    /// point of view.
    public enum Kind: Sendable, Codable, Equatable {
        case totp(period: Int)
        case hotp(counter: UInt64)
    }

    public let id: UUID
    /// The service, e.g. "GitHub". May be empty if the QR code omitted it.
    public var issuer: String
    /// The identity within that service, e.g. "alice@example.com".
    public var accountName: String
    public var secret: [UInt8]
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var kind: Kind
    /// User's ordering on the watch. Small integers, rewritten on reorder.
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        issuer: String,
        accountName: String,
        secret: [UInt8],
        algorithm: OTPAlgorithm = .sha1,
        digits: Int = 6,
        kind: Kind = .totp(period: 30),
        sortIndex: Int = 0
    ) {
        self.id = id
        self.issuer = issuer
        self.accountName = accountName
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.kind = kind
        self.sortIndex = sortIndex
    }

    /// What to show as the primary line on a 41mm screen. Issuer if we have
    /// one, because that is what the user is looking for when they scroll.
    public var displayTitle: String {
        issuer.isEmpty ? accountName : issuer
    }

    /// Secondary line, suppressed when it would just repeat the title.
    public var displaySubtitle: String? {
        if issuer.isEmpty { return nil }
        if accountName.isEmpty { return nil }
        if accountName == issuer { return nil }
        return accountName
    }

    public var period: Int {
        switch kind {
        case .totp(let period): period
        case .hotp: 30
        }
    }

    public func code(at date: Date, hmac: some HMACProviding) -> String {
        switch kind {
        case .totp(let period):
            OTP.totp(
                key: secret,
                date: date,
                period: period,
                digits: digits,
                algorithm: algorithm,
                hmac: hmac
            )
        case .hotp(let counter):
            OTP.hotp(
                key: secret,
                counter: counter,
                digits: digits,
                algorithm: algorithm,
                hmac: hmac
            )
        }
    }

    /// Codes are read off a watch face at arm's length, often while holding a
    /// laptop. Grouping halves the number of glances needed to type one.
    /// 6 -> "123 456", 8 -> "1234 5678", 7 -> "1234 567".
    public static func group(_ code: String) -> String {
        switch code.count {
        case 6:
            let middle = code.index(code.startIndex, offsetBy: 3)
            return "\(code[code.startIndex..<middle]) \(code[middle...])"
        case 8:
            let middle = code.index(code.startIndex, offsetBy: 4)
            return "\(code[code.startIndex..<middle]) \(code[middle...])"
        case 7, 9, 10:
            let middle = code.index(code.startIndex, offsetBy: code.count - 4)
            return "\(code[code.startIndex..<middle]) \(code[middle...])"
        default:
            return code
        }
    }
}
