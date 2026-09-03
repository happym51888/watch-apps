import Foundation
import Observation
import WatchConnectivity
import KairosCore

/// Receives newly enrolled accounts from the iPhone app.
///
/// Enrolment has to start on the phone because the watch has no camera and
/// therefore cannot scan a QR code, and because typing a 32-character base32
/// secret on a watch is not a thing anyone will do twice. After that one
/// transfer the phone is irrelevant, which is the entire point of the app.
///
/// `transferUserInfo` is used rather than `sendMessage`: it is queued and
/// delivered by the system even if the watch app is not running, so enrolment
/// works while the watch sits on a charger in another room. `sendMessage`
/// requires both apps to be live and fails exactly when you least want it to.
@MainActor
@Observable
final class SyncSession: NSObject {

    private(set) var isPhoneReachable = false
    private(set) var lastReceived: Date?
    private weak var model: CodeModel?

    func activate(into model: CodeModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    fileprivate func ingest(_ payload: [String: Any]) {
        guard let uris = payload["accounts"] as? [String] else { return }
        guard let model else { return }

        for uri in uris {
            // Parse on this side rather than trusting a decoded struct off the
            // wire. The phone and watch versions can differ after an update,
            // and the Key URI is the stable contract between them.
            guard let account = try? OTPAuthURI.parse(uri) else { continue }
            model.add(account)
        }
        lastReceived = .now
    }
}

extension SyncSession: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in self.isPhoneReachable = reachable }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isPhoneReachable = reachable }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        Task { @MainActor in self.ingest(userInfo) }
    }

    /// Also accept a live message, for the case where the user is watching the
    /// watch screen while scanning on the phone and expects it to appear now.
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            self.ingest(message)
            replyHandler(["ok": true])
        }
    }
}
