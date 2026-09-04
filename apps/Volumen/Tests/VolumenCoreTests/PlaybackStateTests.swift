import Foundation
import XCTest
@testable import VolumenCore

/// The transport. `Book` decides where a position is; this decides what
/// happens around it 鈥?when the place is written down, what the listener is
/// told when it could not be kept, and when the sleep timer fires.
final class PlaybackStateTests: XCTestCase {

    private func book() throws -> Book {
        try Book(
            id: "b",
            title: "Three",
            tracks: [
                Track(id: "t1", title: "One", durationMS: 10_000),
                Track(id: "t2", title: "Two", durationMS: 20_000),
                Track(id: "t3", title: "Three", durationMS: 30_000)
            ]
        )
    }

    // MARK: - Opening

    func testOpeningWithNoSavedPlaceStartsAtTheBeginning() throws {
        let (state, actions) = PlaybackState.open(book: try book(), saved: nil)
        XCTAssertEqual(state.mark, Bookmark(trackID: "t1", offsetMS: 0))
        XCTAssertEqual(actions, [.load(trackID: "t1", offsetMS: 0)])
    }

    func testOpeningAtASavedPlaceReportsNoJump() throws {
        let saved = Bookmark(trackID: "t2", offsetMS: 12_000)
        let (state, actions) = PlaybackState.open(book: try book(), saved: saved)

        XCTAssertEqual(state.mark, saved)
        XCTAssertFalse(actions.contains { if case .reportJump = $0 { return true }; return false })
        XCTAssertEqual(actions.first, .load(trackID: "t2", offsetMS: 12_000))
    }

    func testAMissingFileIsReportedAsAJumpAndNotPassedOffAsTheSavedPlace() throws {
        let previous = try book()
        let saved = Bookmark(trackID: "t2", offsetMS: 12_000)
        let shrunk = try Book(
            id: "b",
            title: "Three",
            tracks: [
                Track(id: "t1", title: "One", durationMS: 10_000),
                Track(id: "t3", title: "Three", durationMS: 30_000)
            ]
        )

        let (state, actions) = PlaybackState.open(
            book: shrunk, saved: saved, previous: previous
        )

        XCTAssertEqual(state.mark, Bookmark(trackID: "t3", offsetMS: 12_000))
        let jump = actions.compactMap { action -> JumpReason? in
            if case .reportJump(_, _, let reason) = action { return reason }
            return nil
        }
        XCTAssertEqual(jump, [.trackMissing], "a reconstructed place must not look like a kept one")
    }

    func testAnOffsetPastTheEndOfItsFileIsReportedTooCommaNotSilentlyClamped() throws {
        // Metadata said the file was two minutes; it is ten seconds. Clamping
        // is right, but doing it quietly means the listener sees the book jump
        // and has no idea why.
        let saved = Bookmark(trackID: "t1", offsetMS: 120_000)
        let (state, actions) = PlaybackState.open(book: try book(), saved: saved)

        XCTAssertEqual(state.mark, Bookmark(trackID: "t1", offsetMS: 10_000))
        XCTAssertTrue(
            actions.contains { action in
                if case .reportJump(_, _, .offsetPastEnd) = action { return true }
                return false
            }
        )
    }

    // MARK: - Persisting

    func testPauseAlwaysWritesThePlaceDown() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        _ = state.play()
        _ = state.tick(offsetMS: 4_000, elapsedMS: 4_000)

        let actions = state.pause()
        // Pause is the commonest last event before the app is suspended and
        // killed. A place written only on a timer loses everything since the
        // last tick.
        XCTAssertEqual(actions, [.pause, .persist(Bookmark(trackID: "t1", offsetMS: 4_000))])
    }

    func testPausingTwiceDoesNothingTheSecondTime() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        _ = state.play()
        XCTAssertFalse(state.pause().isEmpty)
        XCTAssertTrue(state.pause().isEmpty)
        XCTAssertTrue(state.play().count == 1)
    }

    // MARK: - Crossing files

    func testTheEndOfOneFileIsTheStartOfTheNextAndNotAReplay() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        _ = state.play()
        _ = state.tick(offsetMS: 10_000, elapsedMS: 10_000)
        XCTAssertEqual(state.absoluteMS, 10_000)

        let actions = state.trackDidEnd()
        XCTAssertEqual(state.mark, Bookmark(trackID: "t2", offsetMS: 0))
        // Same absolute instant across the transition. If these differed, a
        // bookmark saved at a boundary would replay or skip a whole file.
        XCTAssertEqual(state.absoluteMS, 10_000)
        XCTAssertEqual(actions.first, .load(trackID: "t2", offsetMS: 0))
        XCTAssertTrue(actions.contains(.persist(Bookmark(trackID: "t2", offsetMS: 0))))
    }

    func testTheEndOfTheBookParksAtTheEndRatherThanWrapping() throws {
        var (state, _) = PlaybackState.open(
            book: try book(), saved: Bookmark(trackID: "t3", offsetMS: 29_000)
        )
        _ = state.play()

        let actions = state.trackDidEnd()
        XCTAssertEqual(state.mark, Bookmark(trackID: "t3", offsetMS: 30_000))
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(actions, [.pause, .persist(Bookmark(trackID: "t3", offsetMS: 30_000))])
    }

    // MARK: - Seeking

    func testSkippingBackAtTheStartStopsAtTheStart() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        _ = state.tick(offsetMS: 10_00, elapsedMS: 1_000)
        _ = state.skip(byMS: -30_000)
        XCTAssertEqual(state.mark, Bookmark(trackID: "t1", offsetMS: 0))
    }

    func testSkippingForwardPastTheEndStopsAtTheEnd() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        _ = state.skip(byMS: 999_999)
        XCTAssertEqual(state.mark, Bookmark(trackID: "t3", offsetMS: 30_000))
        XCTAssertEqual(state.remainingMS, 0)
    }

    func testSkippingAcrossAFileBoundaryLoadsTheOtherFile() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        _ = state.play()
        _ = state.tick(offsetMS: 9_000, elapsedMS: 9_000)

        let actions = state.skip(byMS: 5_000)   // 14,000 absolute, inside t2
        XCTAssertEqual(state.mark, Bookmark(trackID: "t2", offsetMS: 4_000))
        XCTAssertEqual(actions.first, .load(trackID: "t2", offsetMS: 4_000))
        XCTAssertTrue(actions.contains(.play), "a seek while playing keeps playing")
    }

    func testJumpingToAChapter() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        _ = state.jump(toChapter: 2)
        XCTAssertEqual(state.absoluteMS, 30_000)
        XCTAssertEqual(state.chapterIndex, 2)
        XCTAssertTrue(state.jump(toChapter: 99).isEmpty)
    }

    // MARK: - The sleep timer

    func testTheSleepTimerCountsPlayingTimeAndNotWallClock() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        state.setSleepTimer(.after(playingMS: 5_000))
        _ = state.play()

        XCTAssertTrue(state.tick(offsetMS: 3_000, elapsedMS: 3_000).isEmpty)
        XCTAssertEqual(state.sleepRemainingMS, 2_000)

        _ = state.pause()
        // Half an hour goes by with the watch on the nightstand. A timer
        // counting wall-clock would have fired and, worse, would have decided
        // the listener was asleep when they were answering the door.
        XCTAssertTrue(state.tick(offsetMS: 3_000, elapsedMS: 1_800_000).isEmpty)
        XCTAssertEqual(state.sleepRemainingMS, 2_000)

        _ = state.play()
        let actions = state.tick(offsetMS: 5_100, elapsedMS: 2_100)
        XCTAssertTrue(actions.contains(.fadeOutAndPause))
        XCTAssertFalse(state.isPlaying)
        XCTAssertNil(state.sleepRemainingMS, "the timer disarms once it has fired")
    }

    func testTheSleepTimerFiresOnceAndNotOnEveryLaterTick() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        state.setSleepTimer(.after(playingMS: 1_000))
        _ = state.play()
        XCTAssertTrue(state.tick(offsetMS: 2_000, elapsedMS: 2_000).contains(.fadeOutAndPause))

        _ = state.play()
        XCTAssertFalse(state.tick(offsetMS: 3_000, elapsedMS: 2_000).contains(.fadeOutAndPause))
    }

    func testEndOfChapterStopsAtTheChapterAndNotAtTheNextFile() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        // One chapter covering files 1 and 2, a second covering file 3.
        state.adopt(chapters: try book().chapters(fromMarks: [("A", 0), ("B", 30_000)]))
        state.setSleepTimer(.endOfChapter)
        _ = state.play()

        // File 1 ends inside chapter A: keep going.
        _ = state.tick(offsetMS: 10_000, elapsedMS: 10_000)
        var actions = state.trackDidEnd()
        XCTAssertFalse(actions.contains(.fadeOutAndPause))
        XCTAssertTrue(state.isPlaying)

        // File 2 ends where chapter A ends: stop.
        _ = state.tick(offsetMS: 20_000, elapsedMS: 20_000)
        actions = state.trackDidEnd()
        XCTAssertTrue(actions.contains(.fadeOutAndPause))
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.absoluteMS, 30_000)
    }

    func testChapterRemainingCountsDownWithinTheChapter() throws {
        var (state, _) = PlaybackState.open(book: try book(), saved: nil)
        state.setSleepTimer(.endOfChapter)
        _ = state.play()
        _ = state.tick(offsetMS: 4_000, elapsedMS: 4_000)
        // One chapter per file by default, so 6 seconds left in file 1.
        XCTAssertEqual(state.chapterRemainingMS, 6_000)
        XCTAssertEqual(state.sleepRemainingMS, 6_000)
    }

    // MARK: - Identity

    func testTrackIdentityDependsOnBothTheBytesAndTheLength() {
        let prefix: [UInt8] = Array("ID3 and then some audio".utf8)
        let full = TrackIdentity.make(prefix: prefix, totalBytes: 6_291_456)

        XCTAssertEqual(full, TrackIdentity.make(prefix: prefix, totalBytes: 6_291_456))

        // A truncated download shares its prefix with the complete file. If it
        // shared its id too, a bookmark would point past the end of the audio
        // that is actually present.
        XCTAssertNotEqual(full, TrackIdentity.make(prefix: prefix, totalBytes: 3_000_000))

        var different = prefix
        different[4] = 0x7A
        XCTAssertNotEqual(full, TrackIdentity.make(prefix: different, totalBytes: 6_291_456))
    }

    func testTheHashIsTheKnownFNV1aVector() {
        // FNV-1a 64-bit of "hello" is a published constant; if this drifts,
        // every bookmark in every library is orphaned at once.
        XCTAssertEqual(TrackIdentity.fnv1a64(Array("hello".utf8)), 0xa430_d846_80aa_bd0b)
        XCTAssertEqual(TrackIdentity.fnv1a64([]), 0xcbf2_9ce4_8422_2325)
    }
}
