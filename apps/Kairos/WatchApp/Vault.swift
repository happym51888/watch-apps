import Foundation
import KairosCore
import Security

/// Keychain-backed storage for enrolled accounts.
///
/// Design decisions here are the product, so they are spelled out:
///
/// **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.** `WhenUnlocked` means the
/// secrets are unreadable while the watch is off your wrist and locked.
/// `ThisDeviceOnly` means they are excluded from encrypted backups and never
/// leave for iCloud Keychain. A TOTP secret that syncs is a TOTP secret that
/// can be exfiltrated from a second device, which defeats the second factor.
///
/// **One item per account, not one blob.** A single blob would be simpler, but
/// it means every read decrypts every secret. Per-account items keep the
/// working set to the one code being displayed.
///
/// **No iCloud, no server, no analytics.** There is nothing to configure and
/// nothing to breach. It also means losing the watch loses the accounts, which
/// is why the phone app keeps the authoritative copy.
@MainActor
final class Vault {

    /// Shared across the watch app and the complication, hence a group.
    /// Must match `keychain-access-groups` in the entitlements.
    private let service = "app.kairos.accounts"

    enum VaultError: Error {
        case unexpectedStatus(OSStatus)
        case decodingFailed
    }

    // MARK: - Reading

    func loadAll() throws -> [Account] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw VaultError.unexpectedStatus(status) }
        guard let items = result as? [[String: Any]] else { throw VaultError.decodingFailed }

        let decoder = JSONDecoder()
        let accounts = items.compactMap { item -> Account? in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            // A single corrupt item must not take the whole list down with it;
            // the user would have no way to recover other than reinstalling.
            return try? decoder.decode(Account.self, from: data)
        }

        return accounts.sorted { $0.sortIndex < $1.sortIndex }
    }

    // MARK: - Writing

    func save(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)

        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.id.uuidString
        ]

        // Try update first: SecItemAdd on an existing item returns
        // errSecDuplicateItem, and re-enrolling an account the user already has
        // should quietly replace it rather than fail.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw VaultError.unexpectedStatus(updateStatus)
        }

        var insert = identity
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // Shown in the system's password UI if it ever surfaces there. Never
        // include the secret or the account name.
        insert[kSecAttrLabel as String] = "Kairos"

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw VaultError.unexpectedStatus(addStatus) }
    }

    func delete(id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.unexpectedStatus(status)
        }
    }

    /// Used by "Remove all accounts" in settings, and after a failed restore.
    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.unexpectedStatus(status)
        }
    }

    /// HOTP counters advance on use and must be persisted immediately, because
    /// a counter that rolls back silently generates codes the server has
    /// already consumed.
    func advanceHOTPCounter(for account: Account) throws -> Account {
        guard case .hotp(let counter) = account.kind else { return account }
        var updated = account
        updated.kind = .hotp(counter: counter + 1)
        try save(updated)
        return updated
    }
}
