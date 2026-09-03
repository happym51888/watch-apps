import Foundation
import WatchKit

/// Keeps the app alive while the screen is off.
///
/// Background on why this class exists at all: a plain watchOS app is suspended
/// when the wrist drops, and `WKInterfaceDevice.play(_:)` is documented to do
/// nothing at all while the app is `background` or `inactive`. So a metronome
/// without one of these sessions simply stops the moment you stop looking at it,
/// which is what the reviews of the existing watch metronomes describe.
///
/// The session type is `mindfulness`: frontmost runtime, one hour, screen may
/// switch off. It is the longest frontmost session available. See
/// TactusWatch/Info.plist and the App Review note in README.md — this is the one
/// design decision in the app that carries real submission risk, and the audible
/// click is the fallback if it is refused.
@MainActor
final class RuntimeSessionCoordinator: NSObject {
    enum State: Equatable {
        case idle
        case running
        /// The system ended it early — thermal pressure, battery, or the hour ran out.
        case ended(reason: String)
    }

    private(set) var state: State = .idle
    private var session: WKExtendedRuntimeSession?

    /// Called when the session goes away on its own, so the engine can stop rather
    /// than carry on firing haptics that will never be delivered.
    var onInvalidated: (() -> Void)?

    func start() {
        guard session == nil else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.session = session
        // Must be called while the app is active, otherwise the session is refused.
        session.start()
    }

    func stop() {
        session?.invalidate()
        session = nil
        state = .idle
    }
}

extension RuntimeSessionCoordinator: WKExtendedRuntimeSessionDelegate {
    // WKExtendedRuntimeSessionDelegate is nonisolated, so these three cannot be
    // main-actor-isolated members. They hop instead, carrying only Sendable values.
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in self.state = .running }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // One hour is up. Nothing to do but let the invalidation land; the UI reads
        // `state` and tells the user why the click stopped instead of leaving them
        // wondering.
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        // `reason` is a plain enum, so describing it here keeps the hop Sendable
        // without reaching for the session object itself.
        let description = Self.describe(reason)
        Task { @MainActor in
            self.session = nil
            self.state = .ended(reason: description)
            self.onInvalidated?()
        }
    }

    private static func describe(_ reason: WKExtendedRuntimeSessionInvalidationReason) -> String {
        switch reason {
        case .none:
            return "Stopped"
        case .sessionInProgress:
            return "Another session was already running"
        case .expired:
            return "Reached the one hour limit"
        case .resignedFrontmost:
            return "Another app came to the front"
        case .suppressedBySystem:
            return "Paused by the watch to save power"
        case .error:
            return "Ended unexpectedly"
        @unknown default:
            return "Ended"
        }
    }
}
