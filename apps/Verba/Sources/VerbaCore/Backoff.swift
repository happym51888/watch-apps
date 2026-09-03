import Foundation

/// Retry schedule for failed deliveries.
///
/// A watch spends most of its life out of range of something. Failures are the
/// normal case, not the exception, so the schedule has to be aggressive early
/// (the phone is usually a second away) and patient later (the user is on a
/// plane) without ever hammering the radio flat.
///
/// Full jitter rather than a fixed doubling. Without it, a backlog of thirty
/// recordings that all failed together retries in a synchronised burst forever,
/// and each burst fails together again for the same reason.
public struct Backoff: Sendable, Equatable {

    public let base: TimeInterval
    public let cap: TimeInterval
    /// After this many failures a recording stops retrying automatically and
    /// waits for the user or for a connectivity change. It is never discarded.
    public let attemptsBeforePausing: Int

    public init(
        base: TimeInterval = 2,
        cap: TimeInterval = 3600,
        attemptsBeforePausing: Int = 12
    ) {
        precondition(base > 0, "base delay must be positive")
        precondition(cap >= base, "cap must be at least the base delay")
        self.base = base
        self.cap = cap
        self.attemptsBeforePausing = attemptsBeforePausing
    }

    /// Delay before attempt number `attempts + 1`, given `attempts` failures.
    ///
    /// `randomFraction` is injected so the schedule is deterministic under test.
    /// In production it is `Double.random(in: 0..<1)`.
    public func delay(afterFailures attempts: Int, randomFraction: Double) -> TimeInterval {
        precondition(attempts >= 0)
        precondition((0..<1).contains(randomFraction) || randomFraction == 0)

        // Exponential ceiling, computed without `pow` so a large attempt count
        // cannot overflow into infinity.
        var ceiling = base
        for _ in 0..<min(attempts, 40) {
            ceiling *= 2
            if ceiling >= cap { ceiling = cap; break }
        }
        ceiling = min(ceiling, cap)

        // Full jitter: anywhere in [0, ceiling]. The floor of one second keeps
        // a same-instant retry storm off the radio.
        return max(1, ceiling * randomFraction)
    }

    public func shouldKeepRetrying(after attempts: Int) -> Bool {
        attempts < attemptsBeforePausing
    }
}
