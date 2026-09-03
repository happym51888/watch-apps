import Foundation

/// Derives a tempo from the user tapping the screen or the Digital Crown.
///
/// Two things make a naive implementation feel wrong on a watch: one clumsy tap
/// drags the average for the next several taps, and pausing to think gets folded in
/// as a very slow tempo. So intervals older than `resetAfter` start a fresh
/// measurement, and the estimate is a median rather than a mean.
public struct TapTempo: Sendable, Equatable {
    /// A gap longer than this means the user stopped tapping; the next tap starts over.
    public static let defaultResetAfter: TimeInterval = 2.5
    /// Taps kept in the rolling window.
    public static let defaultWindow = 8

    public let resetAfter: TimeInterval
    public let window: Int

    private var timestamps: [TimeInterval] = []

    public init(resetAfter: TimeInterval = TapTempo.defaultResetAfter, window: Int = TapTempo.defaultWindow) {
        precondition(resetAfter > 0, "reset interval must be positive")
        precondition(window >= 2, "need at least two taps to measure an interval")
        self.resetAfter = resetAfter
        self.window = window
    }

    /// Number of taps in the current measurement.
    public var tapCount: Int { timestamps.count }

    /// Registers a tap at `time` and returns the tempo estimate, or nil while there
    /// is still only one tap to go on.
    @discardableResult
    public mutating func tap(at time: TimeInterval) -> Double? {
        if let last = timestamps.last, time - last > resetAfter {
            timestamps.removeAll(keepingCapacity: true)
        }
        timestamps.append(time)
        if timestamps.count > window {
            timestamps.removeFirst(timestamps.count - window)
        }
        return estimate
    }

    public mutating func reset() {
        timestamps.removeAll(keepingCapacity: true)
    }

    /// Current estimate in beats per minute, clamped to the metronome's range.
    public var estimate: Double? {
        guard timestamps.count >= 2 else { return nil }
        var intervals: [TimeInterval] = []
        intervals.reserveCapacity(timestamps.count - 1)
        for i in 1..<timestamps.count {
            intervals.append(timestamps[i] - timestamps[i - 1])
        }
        guard let typical = median(of: intervals), typical > 0 else { return nil }
        let bpm = 60.0 / typical
        return min(max(bpm, MetronomeSettings.bpmRange.lowerBound), MetronomeSettings.bpmRange.upperBound)
    }

    private func median(of values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
}
