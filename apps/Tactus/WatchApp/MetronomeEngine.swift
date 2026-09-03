import Foundation
import Observation

/// Drives the metronome: owns the settings, runs the beat loop, fires haptics and
/// clicks, and publishes just enough state for the UI to draw.
///
/// The loop is the interesting part. Every pulse is woken on an *absolute* deadline
/// derived from `PulseGrid` — `start + index * pulseInterval` — rather than by a
/// repeating timer. A repeating timer accumulates its own lateness, so it slides
/// audibly flat over a few minutes; absolute deadlines cannot, because a late wake
/// does not move the next target.
@MainActor
@Observable
final class MetronomeEngine {

    // MARK: - Published state

    var settings: MetronomeSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    var hapticProfile: HapticProfile = .firm {
        didSet {
            driver.profile = hapticProfile
            Storage.hapticProfile = hapticProfile
        }
    }

    var audioClickEnabled: Bool = false {
        didSet { Storage.audioClickEnabled = audioClickEnabled }
    }

    private(set) var isRunning = false
    /// Most recent pulse, for the beat indicator.
    private(set) var currentPulse: Pulse?
    /// What the rate limiter had to do with the current settings. Surfaced in the
    /// UI so a thinned pattern reads as a deliberate decision rather than a bug.
    private(set) var plan: HapticPlan
    /// Non-nil when the runtime session went away and the run was stopped for us.
    private(set) var interruptionMessage: String?

    // MARK: - Collaborators

    private let planner = HapticPlanner()
    private var driver = HapticDriver()
    private let click = ClickPlayer()
    private let runtime = RuntimeSessionCoordinator()
    private var runTask: Task<Void, Never>?

    init() {
        let restored = Storage.settings ?? MetronomeSettings(bpm: 100)
        self.settings = restored
        self.plan = HapticPlanner().plan(for: restored)
        self.hapticProfile = Storage.hapticProfile
        self.audioClickEnabled = Storage.audioClickEnabled
        self.driver.profile = Storage.hapticProfile

        runtime.onInvalidated = { [weak self] in
            guard let self, self.isRunning else { return }
            self.interruptionMessage = {
                if case .ended(let reason) = self.runtime.state { return reason }
                return "Stopped by the watch"
            }()
            self.stop()
        }
    }

    // MARK: - Control

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        interruptionMessage = nil
        plan = planner.plan(for: settings)
        Storage.settings = settings

        runtime.start()
        driver.playTransition(starting: true)

        let grid = PulseGrid(settings)
        let plan = self.plan
        let wantsAudio = audioClickEnabled

        runTask = Task { [weak self] in
            if wantsAudio {
                _ = await self?.click.activateSession()
                try? self?.click.prepare()
            }
            await self?.run(grid: grid, plan: plan, audio: wantsAudio)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        runTask?.cancel()
        runTask = nil
        currentPulse = nil
        click.stop()
        runtime.stop()
        driver.playTransition(starting: false)
    }

    // MARK: - Tempo editing

    func nudgeTempo(by delta: Double) {
        setTempo(settings.bpm + delta)
    }

    func setTempo(_ bpm: Double) {
        var updated = settings
        updated.bpm = min(max(bpm, MetronomeSettings.bpmRange.lowerBound), MetronomeSettings.bpmRange.upperBound)
        settings = updated
    }

    func apply(_ preset: Preset) {
        settings = preset.settings
    }

    // MARK: - The loop

    private func run(grid: PulseGrid, plan: HapticPlan, audio: Bool) async {
        let clock = ContinuousClock()
        let start = clock.now
        var index = 0

        while !Task.isCancelled {
            var pulse = grid.pulse(at: index)
            var deadline = start.advanced(by: .seconds(pulse.offset))

            // If we woke up more than a whole pulse late — the watch throttled us,
            // or a haptic call blocked — do not try to catch up by firing a burst.
            // Ask the grid where we should be now and carry on from there. The beat
            // stays in phase with where it would have been.
            let elapsed = Self.seconds(from: start, to: clock.now)
            if elapsed > pulse.offset + grid.settings.pulseInterval {
                let resynced = grid.nextIndex(atOrAfter: elapsed)
                if resynced > index {
                    index = resynced
                    pulse = grid.pulse(at: index)
                    deadline = start.advanced(by: .seconds(pulse.offset))
                }
            }

            do {
                try await Task.sleep(until: deadline, clock: clock)
            } catch {
                break // cancelled
            }
            if Task.isCancelled { break }

            currentPulse = pulse
            if plan.fires(pulse) {
                driver.play(plan.strength(for: pulse))
            }
            if audio {
                click.play(plan.strength(for: pulse))
            }
            index += 1
        }
    }

    private func settingsChanged(from oldValue: MetronomeSettings) {
        guard settings != oldValue else { return }
        plan = planner.plan(for: settings)
        Storage.settings = settings
        // Changing tempo mid-run restarts the timeline so the new tempo starts on a
        // downbeat, which is what you want when dialling in a tempo by ear.
        if isRunning {
            let wasAudio = audioClickEnabled
            runTask?.cancel()
            let grid = PulseGrid(settings)
            let plan = self.plan
            runTask = Task { [weak self] in
                await self?.run(grid: grid, plan: plan, audio: wasAudio)
            }
        }
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: end).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
