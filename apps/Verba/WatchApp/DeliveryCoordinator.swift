import Foundation
import Observation
import WatchConnectivity

/// Turns the pure `TransferQueue` into actual transfers, and persists it.
///
/// Two delivery paths, tried in that order:
///
/// 1. **`WCSession.transferFile` to the iPhone.** Free, unmetered, and queued
///    by the system so it survives the watch app being killed. Transcription
///    then happens on the phone for nothing, on-device, with no audio leaving
///    the user's hardware.
/// 2. **Background `URLSession` straight to storage.** For a watch with no
///    phone in range — on a run, in a pool, phone in a locker — over Wi-Fi or
///    cellular. Costs a cloud transcription, so it is the fallback rather than
///    the default.
///
/// Both are idempotent on the recording id, so it does not matter if both
/// eventually land.
@MainActor
@Observable
final class DeliveryCoordinator: NSObject {

    private(set) var queue: TransferQueue
    private(set) var isPhoneReachable = false
    private(set) var storagePressure: (used: Int, budget: Int)?
    private(set) var lastError: String?

    private let store = QueueStore()
    private var wakeTimer: Timer?
    /// Maps a system file-transfer object back to the recording it carries, so
    /// the completion callback knows what succeeded.
    private var inFlightTransfers: [ObjectIdentifier: RecordingID] = [:]

    override init() {
        self.queue = TransferQueue(items: store.load())
        super.init()

        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Call once on launch, after the session is set up.
    func start() {
        // Reconcile the queue against the filesystem before anything else. A
        // row whose file vanished (restore, manual clean, a bug) must not sit
        // in the queue retrying a transfer of nothing forever.
        reconcileWithDisk()
        apply(queue.recoverAfterLaunch(now: Date()))
    }

    func enqueue(_ recording: Recording) {
        apply(queue.enqueue(recording, now: Date()))
    }

    func retryAll() {
        apply(queue.retryAll(now: Date()))
    }

    func retry(_ id: RecordingID) {
        apply(queue.retryNow(id, now: Date()))
    }

    // MARK: - Action interpreter

    private func apply(_ actions: [QueueAction]) {
        for action in actions {
            switch action {
            case .startDelivery(let id):
                deliver(id)

            case .deleteLocalFile(let id):
                AudioFiles.delete(id)

            case .scheduleWake(let date):
                scheduleWake(at: date)

            case .reportStoragePressure(let used, let budget):
                storagePressure = (used, budget)
            }
        }

        if queue.localBytes <= queue.policy.byteBudget {
            storagePressure = nil
        }
        store.save(queue.items)
    }

    private func deliver(_ id: RecordingID) {
        let url = AudioFiles.url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // The file is gone but the row said otherwise. Block rather than
            // retry: there is nothing to send, and looping on it would hide
            // every other problem behind a permanently failing item.
            apply(queue.deliveryFailed(
                id,
                retryable: false,
                reason: "The audio file is missing.",
                now: Date(),
                randomFraction: Double.random(in: 0..<1)
            ))
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else {
            failRetryable(id, "iPhone app not available.")
            return
        }

        // Metadata must be property-list types only; `Date` and `Double`
        // qualify. Carrying the start time and duration across means the phone
        // does not have to infer them from file attributes, which are wrong
        // after the file has been copied through the transfer inbox.
        var metadata: [String: Any] = ["recordingID": id.raw]
        if let item = queue.item(id) {
            metadata["startedAt"] = item.startedAt
            metadata["duration"] = item.duration
        }

        // `transferFile` is queued by the system: it completes even if this app
        // is terminated, and it resumes when the phone comes back in range.
        // That is why this is the primary path rather than `sendMessageData`.
        let transfer = session.transferFile(url, metadata: metadata)
        inFlightTransfers[ObjectIdentifier(transfer)] = id
    }

    private func failRetryable(_ id: RecordingID, _ reason: String) {
        lastError = reason
        apply(queue.deliveryFailed(
            id,
            retryable: true,
            reason: reason,
            now: Date(),
            randomFraction: Double.random(in: 0..<1)
        ))
    }

    private func scheduleWake(at date: Date) {
        wakeTimer?.invalidate()
        let interval = max(1, date.timeIntervalSinceNow)
        wakeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.apply(self.queue.tick(now: Date()))
            }
        }
    }

    /// Drop rows whose audio no longer exists, and mark rows whose audio does
    /// exist but which the queue thought was evicted.
    private func reconcileWithDisk() {
        var repaired: [Recording] = []
        for var item in queue.items {
            let present = AudioFiles.exists(item.id)
            if item.hasLocalFile && !present {
                if item.state == .delivered {
                    // Expected: it was evicted and the row outlived the file.
                    item.hasLocalFile = false
                } else {
                    // Unexpected and unrecoverable. Say so instead of retrying.
                    item.hasLocalFile = false
                    item.state = .blocked
                    item.blockReason = "The audio file is missing."
                }
            }
            repaired.append(item)
        }
        queue = TransferQueue(items: repaired, policy: queue.policy, backoff: queue.backoff)
    }
}

// MARK: - WCSessionDelegate

extension DeliveryCoordinator: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            self.apply(self.queue.tick(now: Date()))
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            // Reachability returning is new information that invalidates every
            // previous failure, so clear the backoff rather than waiting it out.
            if reachable { self.retryAll() }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let key = ObjectIdentifier(fileTransfer)
        let message = error?.localizedDescription

        Task { @MainActor in
            guard let id = self.inFlightTransfers.removeValue(forKey: key) else { return }

            if let message {
                self.failRetryable(id, message)
            } else {
                // Success here means the *system* accepted and delivered the
                // file to the phone app's inbox. That is a real off-watch copy,
                // so it is safe to let the file be evicted.
                self.apply(self.queue.deliverySucceeded(id, now: Date()))
                self.lastError = nil
            }
        }
    }
}

// MARK: - Persistence

/// The queue on disk.
///
/// Written on every state change, not on a timer. The whole point of the queue
/// is to survive a kill, and a queue that is only flushed periodically loses
/// exactly the transitions that matter.
private struct QueueStore {
    private var url: URL {
        AudioFiles.directory.appendingPathComponent("queue.json")
    }

    func load() -> [Recording] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Recording].self, from: data)) ?? []
    }

    func save(_ items: [Recording]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        // Atomic: a half-written queue file after a crash would be worse than
        // no queue file, because it decodes to nothing and looks like an empty
        // queue rather than a corrupt one.
        try? data.write(to: url, options: .atomic)
    }
}
