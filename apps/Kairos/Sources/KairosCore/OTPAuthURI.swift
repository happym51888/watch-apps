import Foundation

/// Parser for the `otpauth://` Key URI that every QR enrolment code encodes.
///
/// There is no RFC for this; the de-facto spec is Google's Key Uri Format wiki
/// page, and real issuers deviate from it constantly. The deviations handled
/// here were all chosen because getting them wrong produces a *silently wrong
/// code* rather than a visible error:
///
/// - `algorithm=SHA256` with the default digit count. Assume SHA-1 and every
///   code is wrong forever.
/// - `period=60`. Assume 30 and codes are right only half the time.
/// - Label `Issuer:name` where the colon is percent-encoded as `%3A`, sometimes
///   followed by a space.
/// - Missing `issuer` parameter, present only as the label prefix.
/// - Lowercase or space-separated secrets, handled in `Base32`.
public enum OTPAuthURI {

    public enum ParseError: Error, Equatable {
        case notAnOTPAuthURI
        case unsupportedType(String)
        case missingSecret
        case invalidSecret(Base32.DecodeError)
        case emptySecret
        case invalidDigits(String)
        case invalidPeriod(String)
        case invalidAlgorithm(String)
        case missingCounter
        case invalidCounter(String)
    }

    public static func parse(_ text: String, sortIndex: Int = 0) throws -> Account {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "otpauth"
        else {
            throw ParseError.notAnOTPAuthURI
        }

        // The type is the URL *host*, not a path component.
        let type = (components.host ?? "").lowercased()
        guard type == "totp" || type == "hotp" else {
            throw ParseError.unsupportedType(type)
        }

        let query = queryItems(from: components)

        // -- secret ------------------------------------------------------
        guard let rawSecret = query["secret"], !rawSecret.isEmpty else {
            throw ParseError.missingSecret
        }
        let secret: [UInt8]
        do {
            secret = try Base32.decode(rawSecret)
        } catch let error as Base32.DecodeError {
            throw ParseError.invalidSecret(error)
        }
        guard !secret.isEmpty else { throw ParseError.emptySecret }

        // -- label -------------------------------------------------------
        // URLComponents already percent-decodes `path`, so `%3A` has become a
        // real colon by now and splitting on ":" is correct.
        let (labelIssuer, accountName) = splitLabel(components.path)

        // Spec says the parameter and the label prefix should agree. When they
        // do not, the parameter wins: it is the machine-written one, whereas
        // the label is what gets truncated and mangled by issuers.
        let issuer = query["issuer"].map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? labelIssuer

        // -- digits ------------------------------------------------------
        var digits = 6
        if let rawDigits = query["digits"] {
            guard let parsed = Int(rawDigits), (6...10).contains(parsed) else {
                throw ParseError.invalidDigits(rawDigits)
            }
            digits = parsed
        }

        // -- algorithm ---------------------------------------------------
        var algorithm = OTPAlgorithm.sha1
        if let rawAlgorithm = query["algorithm"] {
            guard let parsed = OTPAlgorithm(rawValue: rawAlgorithm.uppercased()) else {
                throw ParseError.invalidAlgorithm(rawAlgorithm)
            }
            algorithm = parsed
        }

        // -- kind --------------------------------------------------------
        let kind: Account.Kind
        if type == "totp" {
            var period = 30
            if let rawPeriod = query["period"] {
                guard let parsed = Int(rawPeriod), parsed > 0, parsed <= 3600 else {
                    throw ParseError.invalidPeriod(rawPeriod)
                }
                period = parsed
            }
            kind = .totp(period: period)
        } else {
            guard let rawCounter = query["counter"] else { throw ParseError.missingCounter }
            guard let parsed = UInt64(rawCounter) else {
                throw ParseError.invalidCounter(rawCounter)
            }
            kind = .hotp(counter: parsed)
        }

        return Account(
            issuer: issuer,
            accountName: accountName,
            secret: secret,
            algorithm: algorithm,
            digits: digits,
            kind: kind,
            sortIndex: sortIndex
        )
    }

    /// Case-insensitive query lookup. Some issuers send `Secret=` or
    /// `Algorithm=`, and the wiki spec does not say the keys are case
    /// sensitive.
    private static func queryItems(from components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }
            result[item.name.lowercased()] = value
        }
        return result
    }

    /// Split `/Issuer:account` or `/account` into its two halves.
    private static func splitLabel(_ path: String) -> (issuer: String, account: String) {
        var label = path
        if label.hasPrefix("/") { label.removeFirst() }
        guard let colon = label.firstIndex(of: ":") else {
            return ("", label.trimmingCharacters(in: .whitespaces))
        }
        let issuer = String(label[label.startIndex..<colon])
            .trimmingCharacters(in: .whitespaces)
        let account = String(label[label.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (issuer, account)
    }

    /// Render an account back out as a Key URI, for export and for handing a
    /// migrated account to another device.
    public static func render(_ account: Account) -> String {
        var components = URLComponents()
        components.scheme = "otpauth"

        var query: [URLQueryItem] = [
            URLQueryItem(name: "secret", value: Base32.encode(account.secret))
        ]
        if !account.issuer.isEmpty {
            query.append(URLQueryItem(name: "issuer", value: account.issuer))
        }
        if account.algorithm != .sha1 {
            query.append(URLQueryItem(name: "algorithm", value: account.algorithm.rawValue))
        }
        if account.digits != 6 {
            query.append(URLQueryItem(name: "digits", value: String(account.digits)))
        }

        switch account.kind {
        case .totp(let period):
            components.host = "totp"
            if period != 30 {
                query.append(URLQueryItem(name: "period", value: String(period)))
            }
        case .hotp(let counter):
            components.host = "hotp"
            query.append(URLQueryItem(name: "counter", value: String(counter)))
        }

        let label = account.issuer.isEmpty
            ? account.accountName
            : "\(account.issuer):\(account.accountName)"
        components.path = "/" + label
        components.queryItems = query

        return components.string ?? ""
    }
}
