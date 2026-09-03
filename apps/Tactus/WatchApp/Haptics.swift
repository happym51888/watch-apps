import Foundation
import WatchKit

extension HapticProfile {
    /// watchOS exposes no haptic intensity, only nine fixed patterns, so a
    /// "strength" setting has to be a choice among them. `.notification` and
    /// `.start` are the ones users actually feel through a strap; `.click` is the
    /// one the existing metronome apps use, and the one reviewers call too faint.
    func hapticType(for strength: HapticStrength) -> WKHapticType {
        switch (self, strength) {
        case (.gentle, .strong):     return .start
        case (.gentle, .medium):     return .click
        case (.gentle, .light):      return .click

        case (.firm, .strong):       return .notification
        case (.firm, .medium):       return .start
        case (.firm, .light):        return .click

        case (.strongest, .strong):  return .notification
        case (.strongest, .medium):  return .notification
        case (.strongest, .light):   return .start
        }
    }
}

/// Thin wrapper over the Taptic Engine.
///
/// Deliberately dumb: it plays what it is told and keeps no schedule of its own.
/// All the rate-limit reasoning lives in `HapticPlanner`, which is tested, rather
/// than being spread through the playback path where it cannot be.
struct HapticDriver {
    var profile: HapticProfile = .firm

    func play(_ strength: HapticStrength) {
        WKInterfaceDevice.current().play(profile.hapticType(for: strength))
    }

    /// Distinct confirmation that a run started or stopped, so the user knows the
    /// difference between "running silently" and "not running" without looking.
    func playTransition(starting: Bool) {
        WKInterfaceDevice.current().play(starting ? .start : .stop)
    }
}
