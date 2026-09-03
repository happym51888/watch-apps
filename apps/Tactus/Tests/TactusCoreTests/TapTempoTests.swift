import XCTest
@testable import TactusCore

final class TapTempoTests: XCTestCase {

    func testSingleTapGivesNoEstimate() {
        var tempo = TapTempo()
        XCTAssertNil(tempo.tap(at: 0))
        XCTAssertEqual(tempo.tapCount, 1)
    }

    func testTwoTapsHalfASecondApartReadAs120() {
        var tempo = TapTempo()
        tempo.tap(at: 0)
        let bpm = tempo.tap(at: 0.5)
        XCTAssertEqual(try XCTUnwrap(bpm), 120, accuracy: 1e-9)
    }

    func testSteadyTappingConverges() {
        var tempo = TapTempo()
        var t = 0.0
        for _ in 0..<8 {
            tempo.tap(at: t)
            t += 0.4
        }
        XCTAssertEqual(try XCTUnwrap(tempo.estimate), 150, accuracy: 1e-9)
    }

    /// One fumbled tap in an otherwise steady sequence should barely move the
    /// estimate — this is what the median buys over a mean.
    func testOneBadTapDoesNotWreckTheEstimate() throws {
        var tempo = TapTempo()
        let taps: [TimeInterval] = [0, 0.5, 1.0, 1.5, 1.62, 2.5, 3.0, 3.5]
        for t in taps { tempo.tap(at: t) }
        let bpm = try XCTUnwrap(tempo.estimate)
        XCTAssertEqual(bpm, 120, accuracy: 15)
    }

    func testLongPauseStartsAFreshMeasurement() {
        var tempo = TapTempo(resetAfter: 2.0)
        tempo.tap(at: 0)
        tempo.tap(at: 0.5)
        XCTAssertEqual(try XCTUnwrap(tempo.estimate), 120, accuracy: 1e-9)

        // User stops, thinks, then taps a new, slower tempo.
        XCTAssertNil(tempo.tap(at: 10.0))
        XCTAssertEqual(tempo.tapCount, 1)
        tempo.tap(at: 11.0)
        XCTAssertEqual(try XCTUnwrap(tempo.estimate), 60, accuracy: 1e-9)
    }

    func testWindowDropsOldestTaps() {
        var tempo = TapTempo(window: 3)
        tempo.tap(at: 0)
        tempo.tap(at: 1.0)
        tempo.tap(at: 2.0)
        tempo.tap(at: 2.5)
        XCTAssertEqual(tempo.tapCount, 3)
        // Remaining intervals are 1.0 and 0.5, median 0.75 -> 80 bpm.
        XCTAssertEqual(try XCTUnwrap(tempo.estimate), 80, accuracy: 1e-9)
    }

    func testEstimateIsClampedToTheSupportedRange() throws {
        var tempo = TapTempo()
        tempo.tap(at: 0)
        // An implausibly fast double-tap must not produce a 6000 bpm setting.
        let bpm = try XCTUnwrap(tempo.tap(at: 0.01))
        XCTAssertEqual(bpm, MetronomeSettings.bpmRange.upperBound)
    }

    func testResetClearsState() {
        var tempo = TapTempo()
        tempo.tap(at: 0)
        tempo.tap(at: 0.5)
        tempo.reset()
        XCTAssertEqual(tempo.tapCount, 0)
        XCTAssertNil(tempo.estimate)
    }
}
