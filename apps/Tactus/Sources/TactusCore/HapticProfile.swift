import Foundation

/// How hard the taps should feel.
///
/// This exists because of the single most common complaint about metronome apps
/// on Apple Watch: the tap is too faint to feel while you are actually holding an
/// instrument. There is no API for haptic intensity on watchOS — only the nine
/// stock `WKHapticType` values — so "intensity" has to be expressed as a choice of
/// which stock haptic to fire, and the loud ones have to be the default rather
/// than a setting nobody finds.
///
/// The enum lives in the core, with no WatchKit import, so the complication target
/// can read persisted settings without pulling in the app's playback code. The
/// mapping to concrete haptic types is in the watch layer.
public enum HapticProfile: String, CaseIterable, Identifiable, Sendable {
    case gentle
    case firm
    case strongest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gentle: return "Gentle"
        case .firm: return "Firm"
        case .strongest: return "Strongest"
        }
    }

    public var detail: String {
        switch self {
        case .gentle: return "Quiet practice, wrist against a desk"
        case .firm: return "Default. Felt through a guitar strap"
        case .strongest: return "Drums, loud stages, thick sleeves"
        }
    }
}
