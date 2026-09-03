import XCTest
@testable import TactusCore

final class HapticPlanTests: XCTestCase {

    private let planner = HapticPlanner()

    /// The whole point of the planner: whatever the tempo, taps never land closer
    /// together than the engine can render them.
    func testNoPlanEverViolatesTheRateLimit() {
        let signatures: [TimeSignature] = [.fourFour, .threeFour, .sevenEight, TimeSignature(beatsPerBar: 1)]
        for bpmInt in Int(MetronomeSettings.bpmRange.lowerBound)...Int(MetronomeSettings.bpmRange.upperBound) {
            for signature in signatures {
                for subdivision in 1...4 {
                    let settings = MetronomeSettings(
                        bpm: Double(bpmInt),
                        timeSignature: signature,
                        subdivision: subdivision,
                        accentedBeats: [1]
                    )
                    let plan = planner.plan(for: settings)
                    XCTAssertGreaterThanOrEqual(
                        plan.tightestGap,
                        planner.minInterval - 1e-9,
                        "bpm \(bpmInt) \(signature.beatsPerBar)/\(signature.beatUnit) sub \(subdivision)"
                    )
                }
            }
        }
    }

    /// The claimed tightest gap has to match what `fires(_:)` actually produces,
    /// otherwise the guarantee above is only true on paper.
    func testClaimedGapMatchesSimulatedFiring() {
        let cases: [MetronomeSettings] = [
            MetronomeSettings(bpm: 60),
            MetronomeSettings(bpm: 120, subdivision: 2),
            MetronomeSettings(bpm: 200),
            MetronomeSettings(bpm: 200, accentedBeats: [2]),
            MetronomeSettings(bpm: 320, timeSignature: .threeFour, accentedBeats: [1, 2]),
            MetronomeSettings(bpm: 400, timeSignature: TimeSignature(beatsPerBar: 1)),
            MetronomeSettings(bpm: 180, timeSignature: .sevenEight, subdivision: 3, accentedBeats: [3, 5])
        ]

        for settings in cases {
            let plan = planner.plan(for: settings)
            let grid = PulseGrid(settings)
            var lastFired: TimeInterval?
            var observedTightest = TimeInterval.greatestFiniteMagnitude
            // Ten bars is enough to cover the wrap-around between the last accent
            // of one bar and the downbeat of the next.
            for index in 0..<(settings.pulsesPerBar * 10) {
                let pulse = grid.pulse(at: index)
                guard plan.fires(pulse) else { continue }
                if let last = lastFired {
                    observedTightest = min(observedTightest, pulse.offset - last)
                }
                lastFired = pulse.offset
            }
            XCTAssertNotNil(lastFired, "plan fired nothing for bpm \(settings.bpm)")
            XCTAssertEqual(
                observedTightest,
                plan.tightestGap,
                accuracy: 1e-9,
                "bpm \(settings.bpm) coverage \(plan.coverage)"
            )
            XCTAssertGreaterThanOrEqual(observedTightest, planner.minInterval - 1e-9)
        }
    }

    func testComfortableTempoKeepsEveryPulse() {
        let plan = planner.plan(for: MetronomeSettings(bpm: 100))
        XCTAssertEqual(plan.coverage, .everyPulse)
        XCTAssertFalse(plan.isThinned)
    }

    func testSubdivisionsAreDroppedBeforeBeats() {
        // 120 bpm sixteenths is 0.125 s per pulse — far under the limit — but the
        // beat itself at 0.5 s is fine, so we keep beats and drop the subdivisions.
        let plan = planner.plan(for: MetronomeSettings(bpm: 120, subdivision: 4))
        XCTAssertEqual(plan.coverage, .beatsOnly)
        XCTAssertTrue(plan.isThinned)
        XCTAssertEqual(plan.tightestGap, 0.5, accuracy: 1e-12)
    }

    func testFastTempoFallsBackToAccents() {
        // 240 bpm is 0.25 s per beat, under the limit. With beat 2 accented in 4/4
        // the accent pattern is 0 and 2, giving a 0.5 s gap, which fits.
        let plan = planner.plan(for: MetronomeSettings(bpm: 240, accentedBeats: [2]))
        XCTAssertEqual(plan.coverage, .accentsOnly)
        XCTAssertEqual(plan.tightestGap, 0.5, accuracy: 1e-12)
    }

    func testVeryFastTempoWithNoAccentsFallsBackToDownbeat() {
        let plan = planner.plan(for: MetronomeSettings(bpm: 300))
        XCTAssertEqual(plan.coverage, .downbeatOnly)
        XCTAssertEqual(plan.tightestGap, 60.0 / 300.0 * 4, accuracy: 1e-12)
    }

    /// The pathological case: a single-beat bar at maximum tempo. Bars are 0.15 s
    /// apart, so even downbeat-only is too fast and we have to skip bars.
    func testOneBeatBarAtMaxTempoSkipsBars() {
        let settings = MetronomeSettings(bpm: 400, timeSignature: TimeSignature(beatsPerBar: 1))
        let plan = planner.plan(for: settings)
        guard case .everyNthBar(let n) = plan.coverage else {
            return XCTFail("expected bar skipping, got \(plan.coverage)")
        }
        XCTAssertGreaterThanOrEqual(n, 2)
        XCTAssertGreaterThanOrEqual(plan.tightestGap, planner.minInterval - 1e-9)
    }

    func testAccentGapUsesTheClosestPairIncludingWrapAround() {
        // Accents on 0 and 3 of a 4-beat bar: gaps are 3 beats then 1 beat across
        // the bar line. The 1-beat gap is what has to clear the limit, so at
        // 240 bpm (0.25 s per beat) accents-only must be rejected.
        let settings = MetronomeSettings(bpm: 240, accentedBeats: [3])
        let plan = planner.plan(for: settings)
        XCTAssertNotEqual(plan.coverage, .accentsOnly)
    }

    func testStrengthMapping() {
        let settings = MetronomeSettings(bpm: 100, subdivision: 2, accentedBeats: [2])
        let grid = PulseGrid(settings)
        let plan = planner.plan(for: settings)
        XCTAssertEqual(plan.strength(for: grid.pulse(at: 0)), .strong)
        XCTAssertEqual(plan.strength(for: grid.pulse(at: 1)), .light)
        XCTAssertEqual(plan.strength(for: grid.pulse(at: 4)), .medium)
    }

    func testDownbeatAlwaysFires() {
        for bpm in stride(from: 20.0, through: 400.0, by: 7.0) {
            let settings = MetronomeSettings(bpm: bpm, subdivision: 3)
            let plan = planner.plan(for: settings)
            let grid = PulseGrid(settings)
            // Bar 0 downbeat fires under every coverage mode.
            XCTAssertTrue(plan.fires(grid.pulse(at: 0)), "bpm \(bpm)")
        }
    }

    func testStricterLimitThinsMoreAggressively() {
        let strict = HapticPlanner(minInterval: 1.0)
        let plan = strict.plan(for: MetronomeSettings(bpm: 100))
        XCTAssertNotEqual(plan.coverage, .everyPulse)
        XCTAssertGreaterThanOrEqual(plan.tightestGap, 1.0 - 1e-9)
    }
}
