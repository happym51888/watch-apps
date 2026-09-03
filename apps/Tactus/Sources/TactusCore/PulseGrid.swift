import Foundation

/// Where a pulse sits inside the bar. Drives both accent strength and, on watchOS,
/// which `WKHapticType` gets played.
public enum PulseRole: Sendable, Equatable {
    /// First pulse of the bar.
    case downbeat
    /// A beat the user explicitly marked as accented.
    case accent
    /// An unaccented main beat.
    case beat
    /// A pulse that only exists because of a subdivision (eighths, triplets, …).
    case subdivision
}

/// One click of the grid.
public struct Pulse: Sendable, Equatable {
    /// Monotonically increasing index from the moment the metronome started.
    public let index: Int
    /// Seconds from the start instant. Always computed from `index`, never accumulated.
    public let offset: TimeInterval
    /// Zero-based bar number.
    public let bar: Int
    /// Zero-based beat number inside the bar.
    public let beat: Int
    /// Zero-based subdivision number inside the beat.
    public let tick: Int
    public let role: PulseRole
}

/// `Hashable` because the settings screen drives a `Picker` off these values,
/// and both `Picker`'s selection and `.tag(_:)` require it.
public struct TimeSignature: Sendable, Hashable {
    /// Beats in a bar — the numerator. 4 in 4/4, 7 in 7/8.
    public let beatsPerBar: Int
    /// Note value that gets the beat — the denominator. 4 in 4/4, 8 in 7/8.
    public let beatUnit: Int

    public init(beatsPerBar: Int, beatUnit: Int = 4) {
        precondition(beatsPerBar >= 1, "a bar needs at least one beat")
        precondition(beatUnit >= 1, "beat unit must be positive")
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
    }

    public static let fourFour = TimeSignature(beatsPerBar: 4, beatUnit: 4)
    public static let threeFour = TimeSignature(beatsPerBar: 3, beatUnit: 4)
    public static let sevenEight = TimeSignature(beatsPerBar: 7, beatUnit: 8)
}

/// A metronome configuration. `bpm` counts the beat unit, matching how musicians
/// read a tempo marking: 120 in 6/8 with `beatUnit: 8` means 120 eighth notes.
public struct MetronomeSettings: Sendable, Equatable {
    public static let bpmRange: ClosedRange<Double> = 20...400

    public var bpm: Double
    public var timeSignature: TimeSignature
    /// Pulses per beat. 1 = plain beats, 2 = eighths, 3 = triplets, 4 = sixteenths.
    public var subdivision: Int
    /// Beats the user accented, zero-based, excluding the downbeat which is always
    /// accented. Out-of-range entries are ignored rather than trapped so a saved
    /// preset survives a later time-signature change.
    public var accentedBeats: Set<Int>

    public init(
        bpm: Double,
        timeSignature: TimeSignature = .fourFour,
        subdivision: Int = 1,
        accentedBeats: Set<Int> = []
    ) {
        precondition(subdivision >= 1, "subdivision must be at least 1")
        self.bpm = min(max(bpm, Self.bpmRange.lowerBound), Self.bpmRange.upperBound)
        self.timeSignature = timeSignature
        self.subdivision = subdivision
        self.accentedBeats = accentedBeats
    }

    /// Seconds between two consecutive main beats.
    public var beatInterval: TimeInterval { 60.0 / bpm }

    /// Seconds between two consecutive pulses, subdivisions included.
    public var pulseInterval: TimeInterval { beatInterval / Double(subdivision) }

    /// Pulses in one bar.
    public var pulsesPerBar: Int { timeSignature.beatsPerBar * subdivision }

    /// Seconds per bar.
    public var barInterval: TimeInterval { beatInterval * Double(timeSignature.beatsPerBar) }
}

/// Turns a `MetronomeSettings` into an infinite, exactly-spaced sequence of pulses.
///
/// Every offset is `index * pulseInterval`. Nothing accumulates, so a two-hour
/// practice session ends as accurate as it began — the drift that makes
/// `Timer.scheduledTimer(withTimeInterval:repeats:)` unusable for a metronome
/// simply has nowhere to build up.
public struct PulseGrid: Sendable, Equatable {
    public let settings: MetronomeSettings

    public init(_ settings: MetronomeSettings) {
        self.settings = settings
    }

    public func pulse(at index: Int) -> Pulse {
        precondition(index >= 0, "pulse index cannot be negative")
        let perBar = settings.pulsesPerBar
        let bar = index / perBar
        let inBar = index % perBar
        let beat = inBar / settings.subdivision
        let tick = inBar % settings.subdivision

        let role: PulseRole
        if tick != 0 {
            role = .subdivision
        } else if beat == 0 {
            role = .downbeat
        } else if settings.accentedBeats.contains(beat) {
            role = .accent
        } else {
            role = .beat
        }

        return Pulse(
            index: index,
            offset: Double(index) * settings.pulseInterval,
            bar: bar,
            beat: beat,
            tick: tick,
            role: role
        )
    }

    /// Index of the first pulse at or after `elapsed`.
    ///
    /// This is the recovery path: after the app is throttled, the screen wakes, or a
    /// haptic call blocks longer than expected, ask where we should be now rather
    /// than trying to replay pulses that are already in the past.
    public func nextIndex(atOrAfter elapsed: TimeInterval) -> Int {
        guard elapsed > 0 else { return 0 }
        let exact = elapsed / settings.pulseInterval
        let rounded = exact.rounded()
        // Land on `rounded` when elapsed is within a hair of a pulse boundary, so
        // floating-point representation of, say, 120 bpm does not push us a whole
        // pulse late.
        if abs(exact - rounded) < 1e-9 {
            return Int(rounded)
        }
        return Int(exact.rounded(.up))
    }

    /// Pulses covering `[from, from + duration)`, for pre-scheduling a batch of
    /// audio events on an audio render timeline.
    public func pulses(from startIndex: Int, covering duration: TimeInterval) -> [Pulse] {
        precondition(startIndex >= 0, "pulse index cannot be negative")
        precondition(duration >= 0, "duration cannot be negative")
        let startOffset = Double(startIndex) * settings.pulseInterval
        let end = startOffset + duration
        var result: [Pulse] = []
        var index = startIndex
        while Double(index) * settings.pulseInterval < end {
            result.append(pulse(at: index))
            index += 1
        }
        return result
    }
}
