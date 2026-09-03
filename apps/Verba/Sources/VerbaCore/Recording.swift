import Foundation

/// A single captured recording.
///
/// The identifier is assigned at capture time on the watch and never changes.
/// It travels with the audio through every hop — watch, phone, storage bucket,
/// database row — which is what makes the whole pipeline idempotent: delivering
/// the same recording twice writes the same row twice, which the database
/// rejects on the primary key, which is exactly the behaviour we want.
public struct RecordingID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: String

    public init(raw: String) { self.raw = raw }

    /// Sortable by construction: the timestamp prefix means a plain string sort
    /// is also a chronological sort, in the database and in a bucket listing.
    /// The suffix disambiguates two recordings started in the same second.
    public init(startedAt: Date, entropy: String) {
        let seconds = UInt64(max(0, startedAt.timeIntervalSince1970))
        self.raw = String(format: "%012llu-%@", seconds, entropy)
    }

    public var description: String { raw }
}

/// Where a recording is in its journey off the watch.
///
/// Deliberately *not* modelling "transcribed" here. The watch neither performs
/// nor observes transcription — there is no speech API on watchOS at all — so
/// as far as the watch is concerned its job ends the moment the audio is
/// confirmed to exist somewhere else.
public enum DeliveryState: String, Sendable, Codable, Equatable {
    /// On disk, waiting for a delivery attempt.
    case pending
    /// A transfer or upload is in flight right now.
    case inFlight
    /// Confirmed to exist off the watch. The local file may now be evicted.
    case delivered
    /// Rejected in a way that retrying cannot fix (e.g. the file is corrupt).
    /// Kept on disk and surfaced in the UI rather than silently dropped.
    case blocked
}

public struct Recording: Sendable, Codable, Equatable, Identifiable {
    public let id: RecordingID
    public let startedAt: Date
    /// Seconds of audio. Zero until the recorder finishes and reports it.
    public var duration: TimeInterval
    public var byteCount: Int
    public var state: DeliveryState
    /// How many delivery attempts have failed. Drives the backoff.
    public var attempts: Int
    /// Earliest instant the next attempt may start.
    public var nextAttemptAt: Date?
    /// Set when `state == .blocked`, shown to the user verbatim.
    public var blockReason: String?
    /// A short user-visible label. Populated on the phone once transcription
    /// runs, then mirrored back so the watch list is readable.
    public var title: String?
    /// Whether the audio file still exists on this watch. Goes false only after
    /// delivery is confirmed and the eviction policy reclaims the space; the
    /// row itself stays so the recording remains visible in the list.
    public var hasLocalFile: Bool

    public init(
        id: RecordingID,
        startedAt: Date,
        duration: TimeInterval = 0,
        byteCount: Int = 0,
        state: DeliveryState = .pending,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil,
        blockReason: String? = nil,
        title: String? = nil,
        hasLocalFile: Bool = true
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.byteCount = byteCount
        self.state = state
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.blockReason = blockReason
        self.title = title
        self.hasLocalFile = hasLocalFile
    }

    /// True when the audio still exists only on this watch. These are the ones
    /// that must never be deleted, whatever else happens.
    public var isSoleCopy: Bool {
        state != .delivered && hasLocalFile
    }

    /// Bytes this recording is currently occupying on the watch.
    public var localBytes: Int {
        hasLocalFile ? byteCount : 0
    }
}
