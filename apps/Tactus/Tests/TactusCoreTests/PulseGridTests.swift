import XCTest
@testable import TactusCore

final class PulseGridTests: XCTestCase {

    func testBeatIntervalMatchesTempo() {
        let settings = MetronomeSettings(bpm: 120)
        XCTAssertEqual(settings.beatInterval, 0.5, accuracy: 1e-12)
        XCTAssertEqual(settings.pulseInterval, 0.5, accuracy: 1e-12)
        XCTAssertEqual(settings.barInterval, 2.0, accuracy: 1e-12)
    }

    func testSubdivisionSplitsTheBeat() {
        let settings = MetronomeSettings(bpm: 120, subdivision: 4)
        XCTAssertEqual(settings.pulseInterval, 0.125, accuracy: 1e-12)
        XCTAssertEqual(settings.pulsesPerBar, 16)
    }

    func testRolesAcrossABarInFourFour() {
        let settings = MetronomeSettings(bpm: 100, timeSignature: .fourFour, accentedBeats: [2])
        let grid = PulseGrid(settings)
        XCTAssertEqual(grid.pulse(at: 0).role, .downbeat)
        XCTAssertEqual(grid.pulse(at: 1).role, .beat)
        XCTAssertEqual(grid.pulse(at: 2).role, .accent)
        XCTAssertEqual(grid.pulse(at: 3).role, .beat)
        // Next bar starts over.
        XCTAssertEqual(grid.pulse(at: 4).role, .downbeat)
        XCTAssertEqual(grid.pulse(at: 4).bar, 1)
        XCTAssertEqual(grid.pulse(at: 4).beat, 0)
    }

    func testSubdivisionPulsesAreNeverAccented() {
        let settings = MetronomeSettings(bpm: 90, timeSignature: .fourFour, subdivision: 2, accentedBeats: [1, 2, 3])
        let grid = PulseGrid(settings)
        for index in 0..<16 where index % 2 == 1 {
            XCTAssertEqual(grid.pulse(at: index).role, .subdivision, "index \(index)")
            XCTAssertEqual(grid.pulse(at: index).tick, 1)
        }
    }

    func testOddMeterBarBoundaries() {
        let settings = MetronomeSettings(bpm: 140, timeSignature: .sevenEight)
        let grid = PulseGrid(settings)
        XCTAssertEqual(grid.pulse(at: 6).bar, 0)
        XCTAssertEqual(grid.pulse(at: 6).beat, 6)
        XCTAssertEqual(grid.pulse(at: 7).bar, 1)
        XCTAssertEqual(grid.pulse(at: 7).beat, 0)
        XCTAssertEqual(grid.pulse(at: 7).role, .downbeat)
    }

    /// The reason `PulseGrid` computes offsets instead of accumulating them.
    /// A repeating timer at 137 bpm accumulates visible error over an hour;
    /// index-based offsets stay exact to the resolution of the arithmetic.
    func testNoDriftOverAnHour() {
        let bpm = 137.0
        let settings = MetronomeSettings(bpm: bpm)
        let grid = PulseGrid(settings)
        let oneHourOfPulses = Int((3600.0 / settings.pulseInterval).rounded(.down))

        let last = grid.pulse(at: oneHourOfPulses)
        let expected = Double(oneHourOfPulses) * (60.0 / bpm)
        XCTAssertEqual(last.offset, expected, accuracy: 1e-9)

        // And an accumulating loop is what we are avoiding: show the two disagree
        // only within floating-point noise here, so any real drift in the app must
        // come from scheduling, not from the grid.
        var accumulated = 0.0
        for _ in 0..<oneHourOfPulses { accumulated += settings.pulseInterval }
        XCTAssertEqual(accumulated, last.offset, accuracy: 1e-6)
    }

    func testNextIndexLandsOnBoundaryExactly() {
        let settings = MetronomeSettings(bpm: 120)
        let grid = PulseGrid(settings)
        XCTAssertEqual(grid.nextIndex(atOrAfter: 0), 0)
        XCTAssertEqual(grid.nextIndex(atOrAfter: 0.5), 1)
        XCTAssertEqual(grid.nextIndex(atOrAfter: 2.0), 4)
    }

    func testNextIndexRoundsUpMidPulse() {
        let settings = MetronomeSettings(bpm: 120)
        let grid = PulseGrid(settings)
        XCTAssertEqual(grid.nextIndex(atOrAfter: 0.01), 1)
        XCTAssertEqual(grid.nextIndex(atOrAfter: 0.49), 1)
        XCTAssertEqual(grid.nextIndex(atOrAfter: 0.51), 2)
    }

    /// Recovery after the app was starved: we resume at the correct musical position
    /// rather than replaying a backlog of missed pulses.
    func testNextIndexAfterALongStall() {
        let settings = MetronomeSettings(bpm: 90, subdivision: 2)
        let grid = PulseGrid(settings)
        let stall: TimeInterval = 12.7
        let resume = grid.nextIndex(atOrAfter: stall)
        XCTAssertGreaterThanOrEqual(grid.pulse(at: resume).offset, stall)
        XCTAssertLessThan(grid.pulse(at: resume).offset - stall, settings.pulseInterval)
    }

    func testPulsesCoveringAWindow() {
        let settings = MetronomeSettings(bpm: 120)
        let grid = PulseGrid(settings)
        let batch = grid.pulses(from: 0, covering: 2.0)
        XCTAssertEqual(batch.count, 4)
        XCTAssertEqual(batch.map(\.index), [0, 1, 2, 3])

        let later = grid.pulses(from: 4, covering: 1.0)
        XCTAssertEqual(later.map(\.index), [4, 5])
    }

    func testBpmIsClampedToSupportedRange() {
        XCTAssertEqual(MetronomeSettings(bpm: 5).bpm, MetronomeSettings.bpmRange.lowerBound)
        XCTAssertEqual(MetronomeSettings(bpm: 9000).bpm, MetronomeSettings.bpmRange.upperBound)
    }

    func testAccentOutsideBarIsIgnoredRatherThanCrashing() {
        // A preset saved in 7/8 then reopened in 3/4 must not trap.
        let settings = MetronomeSettings(bpm: 100, timeSignature: .threeFour, accentedBeats: [1, 6])
        let grid = PulseGrid(settings)
        XCTAssertEqual(grid.pulse(at: 1).role, .accent)
        XCTAssertEqual(grid.pulse(at: 2).role, .beat)
    }
}
