#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// The production `HMACProviding`, backed by CryptoKit.
///
/// This package deliberately does not implement SHA-1, SHA-256 or HMAC itself.
/// Hand-rolled crypto in an authenticator is how you end up with an app that
/// works for six months and then fails for one user on one account with no
/// diagnosable cause. CryptoKit is available on watchOS 6 and later, so there
/// is no version cost to using it.
///
/// `Insecure.SHA1` is the correct choice here despite the name. RFC 6238 §1.2
/// mandates SHA-1 as the default, and the SHA-1 collision attacks do not affect
/// HMAC-SHA1, which relies on PRF properties rather than collision resistance.
/// Apple files it under `Insecure` to discourage its use for signatures.
public struct CryptoKitHMAC: HMACProviding {

    public init() {}

    public func authenticationCode(
        for message: [UInt8],
        key: [UInt8],
        algorithm: OTPAlgorithm
    ) -> [UInt8] {
        let symmetricKey = SymmetricKey(data: Data(key))
        let data = Data(message)

        switch algorithm {
        case .sha1:
            return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetricKey))
        case .sha256:
            return Array(HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey))
        case .sha512:
            return Array(HMAC<SHA512>.authenticationCode(for: data, using: symmetricKey))
        }
    }
}
#endif
