import Foundation
import Observation

/// Drives the list and the code screens.
///
/// The interesting constraint is refresh. A TOTP code is only correct for its
/// step, so the UI has to re-render on a boundary the user can see. Polling on
/// a 1 Hz timer is the obvious approach and it is wrong twice over: it wakes
/// the watch 30 times more often than needed, and it still lands up to a second
/// late on the boundary that actually matters.
///
/// Instead the model schedules a single sleep to the *next* step boundary,
/// re-renders, and schedules again. Between boundaries the countdown ring is
/// animated by SwiftUI from a known end date, with no model involvement at all.
@MainActor
@Observable
final class CodeModel {

    private(set) var accounts: [Account] = []
    private(set) var codes: [UUID: String] = [:]
    /// When the currently displayed codes stop being valid. Handed straight to
    /// SwiftUI so the ring animates without a timer.
    private(set) var validUntil: Date = .now
    private(set) var loadFailure: String?

    private let vault = Vault()
    private let hmac = CryptoKitHMAC()
    private var refreshTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func load() {
        do {
            accounts = try vault.loadAll()
            loadFailure = nil
        } catch {
            accounts = []
            // Surfaced in the UI rather than swallowed: an authenticator that
            // silently shows an empty list looks like it lost your accounts.
            loadFailure = "Couldn't open the keychain. \(error)"
        }
        regenerate()
    }

    /// Called from `.onAppear` of whichever screen is visible, and cancelled on
    /// disappear. There is no reason to keep computing HMACs for a screen the
    /// user is not looking at.
    func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.regenerate()
                let sleepFor = max(0.05, self.validUntil.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(sleepFor))
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Codes

    private func regenerate() {
        let now = Date()
        var next: [UUID: String] = [:]
        // The soonest expiry across all accounts, since periods can differ
        // (60s accounts are rare but real).
        var soonest = now.addingTimeInterval(3600)

        for account in accounts {
            next[account.id] = account.code(at: now, hmac: hmac)
            if case .totp(let period) = account.kind {
                let remaining = OTP.secondsRemaining(at: now, period: period)
                let expiry = now.addingTimeInterval(remaining)
                if expiry < soonest { soonest = expiry }
            }
        }

        codes = next
        validUntil = soonest
    }

    /// Fraction of the current step still remaining, for the countdown ring.
    func fractionRemaining(for account: Account, at date: Date) -> Double {
        guard case .totp(let period) = account.kind else { return 1 }
        return OTP.secondsRemaining(at: date, period: period) / Double(period)
    }

    func secondsRemaining(for account: Account, at date: Date) -> Int {
        guard case .totp(let period) = account.kind else { return 0 }
        return Int(OTP.secondsRemaining(at: date, period: period).rounded(.up))
    }

    // MARK: - Mutation

    func add(_ account: Account) {
        var stored = account
        stored.sortIndex = (accounts.map(\.sortIndex).max() ?? -1) + 1
        do {
            try vault.save(stored)
            load()
        } catch {
            loadFailure = "Couldn't save that account. \(error)"
        }
    }

    func delete(_ account: Account) {
        do {
            try vault.delete(id: account.id)
            load()
        } catch {
            loadFailure = "Couldn't delete that account. \(error)"
        }
    }

    /// HOTP only. Burns the current counter and moves to the next code.
    func advance(_ account: Account) {
        do {
            _ = try vault.advanceHOTPCounter(for: account)
            load()
        } catch {
            loadFailure = "Couldn't advance the counter. \(error)"
        }
    }
}
