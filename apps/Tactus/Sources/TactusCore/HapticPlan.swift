import Foundation

/// Abstract haptic strength, mapped to a concrete `WKHapticType` in the watch layer.
/// Kept as a plain enum here so the planning logic stays testable off-device.
public enum HapticStrength: Sendable, Equatable, CaseIterable {
    case strong
    case medium
    case light
}

/// How much of the grid survives the Taptic Engine's rate limit.
public enum HapticCoverage: Sendable, Equatable {
    /// Every pulse, subdivisions included.
    case everyPulse
    /// Main beats only; subdivisions are audio/visual only.
    case beatsOnly
    /// Downbeat plus user accents only.
    case accentsOnly
    /// Downbeat only.
    case downbeatOnly
    /// Every `n`th bar's downbeat. Last resort at extreme tempo with a 1-beat bar.
    case everyNthBar(Int)
}

/// The decision about what to tap, and why.
///
/// `WKInterfaceDevice.play(_:)` imposes a documented 100 ms floor between haptics
/// and cancels whatever is mid-pulse when a new call arrives, so pushing a tap per
/// pulse at high tempo produces swallowed and smeared taps rather than a beat.
/// Reviews of the existing watch metronomes read exactly like that failure.
///
/// Rather than let the pattern fall apart, the planner thins the grid until the gap
/// between taps clears `minInterval`, and reports what it had to give up so the UI
/// can say so plainly.
public struct HapticPlan: Sendable, Equatable {
    public let coverage: HapticCoverage
    /// Smallest gap between two taps this plan can produce, in seconds.
    public let tightestGap: TimeInterval
    /// True when the plan had to drop pulses to respect the rate limit.
    public let isThinned: Bool

    /// Whether the pulse at `index` should fire a haptic under this plan.
    public func fires(_ pulse: Pulse) -> Bool {
        switch coverage {
        case .everyPulse:
            return true
        case .beatsOnly:
            return pulse.tick == 0
        case .accentsOnly:
            return pulse.tick == 0 && (pulse.role == .downbeat || pulse.role == .accent)
        case .downbeatOnly:
            return pulse.role == .downbeat
        case .everyNthBar(let n):
            return pulse.role == .downbeat && pulse.bar % n == 0
        }
    }

    public func strength(for pulse: Pulse) -> HapticStrength {
        switch pulse.role {
        case .downbeat: return .strong
        case .accent: return .medium
        case .beat: return .medium
        case .subdivision: return .light
        }
    }
}

public struct HapticPlanner: Sendable {
    /// Minimum gap between two taps.
    ///
    /// Apple documents a 100 ms floor, but a tap only reads as a distinct beat with
    /// more room than that — the engine is still settling. 0.34 s (≈176 bpm) is the
    /// default because it keeps a tap per beat across the tempo range most players
    /// practise in while staying comfortably clear of the point where taps start
    /// merging.
    public static let defaultMinInterval: TimeInterval = 0.34

    public let minInterval: TimeInterval

    public init(minInterval: TimeInterval = HapticPlanner.defaultMinInterval) {
        precondition(minInterval > 0, "minimum haptic interval must be positive")
        self.minInterval = minInterval
    }

    public func plan(for settings: MetronomeSettings) -> HapticPlan {
        // Candidates ordered from most to least detailed. Take the first that fits.
        if settings.pulseInterval >= minInterval {
            return HapticPlan(
                coverage: .everyPulse,
                tightestGap: settings.pulseInterval,
                isThinned: false
            )
        }

        if settings.beatInterval >= minInterval {
            return HapticPlan(
                coverage: .beatsOnly,
                tightestGap: settings.beatInterval,
                isThinned: true
            )
        }

        // Accents are unevenly spaced, so the binding constraint is the closest pair
        // of accented beats anywhere in the bar, wrapping around the bar line.
        if let accentGap = tightestAccentGap(settings), accentGap >= minInterval {
            return HapticPlan(
                coverage: .accentsOnly,
                tightestGap: accentGap,
                isThinned: true
            )
        }

        if settings.barInterval >= minInterval {
            return HapticPlan(
                coverage: .downbeatOnly,
                tightestGap: settings.barInterval,
                isThinned: true
            )
        }

        // A one-beat bar at 400 bpm still leaves bars 0.15 s apart. Skip bars.
        let stride = max(2, Int((minInterval / settings.barInterval).rounded(.up)))
        return HapticPlan(
            coverage: .everyNthBar(stride),
            tightestGap: settings.barInterval * Double(stride),
            isThinned: true
        )
    }

    /// Smallest interval between consecutive accented beats, treating the bar as a
    /// loop so the wrap from the last accent back to the next downbeat counts.
    /// Returns nil when the downbeat is the only accent, since that is
    /// `.downbeatOnly` rather than a distinct plan.
    private func tightestAccentGap(_ settings: MetronomeSettings) -> TimeInterval? {
        let beatsPerBar = settings.timeSignature.beatsPerBar
        var accents = [0]
        accents.append(contentsOf: settings.accentedBeats.filter { $0 > 0 && $0 < beatsPerBar }.sorted())
        guard accents.count > 1 else { return nil }

        var tightest = TimeInterval.greatestFiniteMagnitude
        for i in accents.indices {
            let next = (i + 1) % accents.count
            let beats = next == 0
                ? beatsPerBar - accents[i] + accents[0]
                : accents[next] - accents[i]
            tightest = min(tightest, Double(beats) * settings.beatInterval)
        }
        return tightest
    }
}
