import Foundation

/// What the queue wants the outside world to do. The queue itself performs no
/// I/O; it is a pure function of state and events, which is the only reason it
/// can be tested exhaustively without a watch.
public enum QueueAction: Sendable, Equatable {
    /// Begin transferring or uploading this recording.
    case startDelivery(RecordingID)
    /// Delete the local audio file. Only ever emitted for delivered items —
    /// this is asserted in the property tests, because it is the one action
    /// that can destroy the user's data.
    case deleteLocalFile(RecordingID)
    /// Nothing is runnable until this instant; schedule a wake-up.
    case scheduleWake(Date)
    /// Undelivered audio has exceeded the storage budget and cannot be evicted.
    /// The UI must tell the user before their next recording is the one that
    /// fails.
    case reportStoragePressure(usedBytes: Int, budget: Int)
}

/// How much of the watch's disk this app may occupy.
public struct StoragePolicy: Sendable, Equatable {
    /// Total bytes of audio kept locally, across every state.
    public let byteBudget: Int
    /// Delivered recordings kept for local playback before being evicted,
    /// even when there is room. Keeps the on-watch list useful without letting
    /// it grow without bound.
    public let keepDeliveredCount: Int

    public init(byteBudget: Int = 200 * 1024 * 1024, keepDeliveredCount: Int = 10) {
        precondition(byteBudget > 0)
        precondition(keepDeliveredCount >= 0)
        self.byteBudget = byteBudget
        self.keepDeliveredCount = keepDeliveredCount
    }
}

/// The delivery queue.
///
/// Everything here exists to protect one invariant:
///
/// > **Audio that exists only on this watch is never deleted, for any reason.**
///
/// Every other behaviour — retries, backoff, eviction, crash recovery — is
/// subordinate to it. A recorder that loses a recording has failed completely,
/// in a way that a recorder which merely delivers late has not. The property
/// sweep in `validation/verify_queue.py` asserts this across randomised event
/// sequences including crashes mid-transfer.
public struct TransferQueue: Sendable {

    public private(set) var items: [Recording]
    public let policy: StoragePolicy
    public let backoff: Backoff
    /// One at a time. The watch's radio and CPU budget do not reward
    /// parallelism, and serialising makes the FIFO guarantee observable.
    public let maxConcurrent: Int

    public init(
        items: [Recording] = [],
        policy: StoragePolicy = StoragePolicy(),
        backoff: Backoff = Backoff(),
        maxConcurrent: Int = 1
    ) {
        precondition(maxConcurrent >= 1)
        self.items = items.sorted { $0.startedAt < $1.startedAt }
        self.policy = policy
        self.backoff = backoff
        self.maxConcurrent = maxConcurrent
    }

    // MARK: - Derived state

    public var undeliveredCount: Int {
        items.filter { $0.state != .delivered }.count
    }

    public var localBytes: Int {
        items.reduce(0) { $0 + $1.localBytes }
    }

    /// Bytes belonging to audio that exists nowhere else.
    public var soleCopyBytes: Int {
        items.filter(\.isSoleCopy).reduce(0) { $0 + $1.byteCount }
    }

    public func item(_ id: RecordingID) -> Recording? {
        items.first { $0.id == id }
    }

    // MARK: - Events

    /// A recording finished capturing and is now on disk.
    public mutating func enqueue(_ recording: Recording, now: Date) -> [QueueAction] {
        // Idempotent by construction: re-enqueuing the same id (a duplicate
        // delegate callback, a replayed event) must not create a second copy.
        guard !items.contains(where: { $0.id == recording.id }) else { return [] }

        var stored = recording
        stored.state = .pending
        stored.attempts = 0
        stored.nextAttemptAt = nil
        items.append(stored)
        items.sort { $0.startedAt < $1.startedAt }

        return pump(now: now)
    }

    /// Called once on every app launch, before anything else.
    ///
    /// An item still marked `inFlight` at launch means the app died mid
    /// transfer. The transfer is definitely not running any more — the process
    /// that owned it is gone — so it must return to `pending`. Leaving it as
    /// `inFlight` is how a recording gets stranded forever, which is the
    /// commonest shape of this bug.
    public mutating func recoverAfterLaunch(now: Date) -> [QueueAction] {
        for index in items.indices where items[index].state == .inFlight {
            items[index].state = .pending
            // Not counted as a failure: the transfer never got a verdict, and
            // charging it an attempt would push a healthy item toward the
            // pause threshold every time the app is killed.
            items[index].nextAttemptAt = nil
        }
        return pump(now: now)
    }

    /// Time passed, or connectivity changed. Start whatever is now runnable.
    public mutating func tick(now: Date) -> [QueueAction] {
        pump(now: now)
    }

    public mutating func deliverySucceeded(_ id: RecordingID, now: Date) -> [QueueAction] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }
        // Late success for something already marked delivered is fine and
        // common — both delivery paths can win the race. Do not double-handle.
        guard items[index].state != .delivered else { return [] }

        items[index].state = .delivered
        items[index].nextAttemptAt = nil
        items[index].blockReason = nil

        var actions = evict()
        actions.append(contentsOf: pump(now: now))
        return actions
    }

    /// A delivery attempt failed.
    ///
    /// `retryable` separates "the phone was asleep" from "the server rejected
    /// this file". The first is the normal case; the second must stop retrying
    /// and become visible, because retrying forever on a permanent error is
    /// indistinguishable from the app being broken.
    public mutating func deliveryFailed(
        _ id: RecordingID,
        retryable: Bool,
        reason: String,
        now: Date,
        randomFraction: Double
    ) -> [QueueAction] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }
        guard items[index].state == .inFlight else { return [] }

        items[index].attempts += 1

        guard retryable, backoff.shouldKeepRetrying(after: items[index].attempts) else {
            items[index].state = .blocked
            items[index].blockReason = reason
            items[index].nextAttemptAt = nil
            // Blocked items keep their file. They are the sole copy.
            return pump(now: now)
        }

        items[index].state = .pending
        items[index].nextAttemptAt = now.addingTimeInterval(
            backoff.delay(afterFailures: items[index].attempts, randomFraction: randomFraction)
        )
        return pump(now: now)
    }

    /// User tapped "try again", or the app detected the phone came back.
    /// Clears the backoff and the blocked state, but never the file.
    public mutating func retryNow(_ id: RecordingID, now: Date) -> [QueueAction] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }
        guard items[index].state == .pending || items[index].state == .blocked else {
            return []
        }
        items[index].state = .pending
        items[index].attempts = 0
        items[index].nextAttemptAt = nil
        items[index].blockReason = nil
        return pump(now: now)
    }

    /// Retry everything that is waiting. Used when connectivity is restored,
    /// where the previous failures say nothing about the next attempt.
    public mutating func retryAll(now: Date) -> [QueueAction] {
        for index in items.indices
        where items[index].state == .pending || items[index].state == .blocked {
            items[index].state = .pending
            items[index].attempts = 0
            items[index].nextAttemptAt = nil
            items[index].blockReason = nil
        }
        return pump(now: now)
    }

    // MARK: - Engine

    /// Start work if there is capacity, otherwise say when to come back.
    private mutating func pump(now: Date) -> [QueueAction] {
        var actions: [QueueAction] = []

        var inFlight = items.filter { $0.state == .inFlight }.count

        // Oldest first. `items` is kept sorted by `startedAt`, so a plain scan
        // is already FIFO, and a backlog that accumulated over a weekend away
        // from the phone drains in the order it was recorded, whatever order it
        // loaded off disk in.
        //
        // Note this orders *starts*, not the queue as a whole: a transfer
        // already in flight is never preempted by an older recording arriving
        // afterwards. Cancelling live radio work to satisfy a sort order would
        // waste the one resource worth conserving here, and on a real watch it
        // cannot arise anyway — only one recording is captured at a time, so
        // they finish in the order they start.
        for index in items.indices {
            guard inFlight < maxConcurrent else { break }
            guard items[index].state == .pending else { continue }
            guard items[index].hasLocalFile else { continue }
            if let due = items[index].nextAttemptAt, due > now { continue }

            items[index].state = .inFlight
            items[index].nextAttemptAt = nil
            inFlight += 1
            actions.append(.startDelivery(items[index].id))
        }

        // If nothing could start because everything is backing off, ask to be
        // woken at the soonest deadline rather than polling.
        if inFlight < maxConcurrent {
            let deadlines = items
                .filter { $0.state == .pending && $0.hasLocalFile }
                .compactMap(\.nextAttemptAt)
                .filter { $0 > now }
            if let soonest = deadlines.min() {
                actions.append(.scheduleWake(soonest))
            }
        }

        if let pressure = storagePressureAction() {
            actions.append(pressure)
        }

        return actions
    }

    /// Reclaim space, delivered items only, oldest first.
    private mutating func evict() -> [QueueAction] {
        var actions: [QueueAction] = []

        // Delivered items with a local file, oldest first.
        func evictableIndices() -> [Int] {
            items.indices
                .filter { items[$0].state == .delivered && items[$0].hasLocalFile }
                .sorted { items[$0].startedAt < items[$1].startedAt }
        }

        // Rule 1: keep only the most recent `keepDeliveredCount` delivered
        // recordings, regardless of how much room there is.
        var evictable = evictableIndices()
        while evictable.count > policy.keepDeliveredCount {
            let index = evictable.removeFirst()
            items[index].hasLocalFile = false
            actions.append(.deleteLocalFile(items[index].id))
        }

        // Rule 2: if still over the byte budget, keep evicting delivered items
        // until it fits. Undelivered audio is never touched, so the budget can
        // legitimately be exceeded — that is what `reportStoragePressure` is
        // for.
        evictable = evictableIndices()
        while localBytes > policy.byteBudget, !evictable.isEmpty {
            let index = evictable.removeFirst()
            items[index].hasLocalFile = false
            actions.append(.deleteLocalFile(items[index].id))
        }

        return actions
    }

    private func storagePressureAction() -> QueueAction? {
        guard localBytes > policy.byteBudget else { return nil }
        return .reportStoragePressure(usedBytes: localBytes, budget: policy.byteBudget)
    }
}
