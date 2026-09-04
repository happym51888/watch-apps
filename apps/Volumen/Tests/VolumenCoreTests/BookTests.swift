import Foundation
import XCTest
@testable import VolumenCore

/// The position model is the only part of this app whose failure is invisible.
/// A crash is obvious; landing forty minutes from where you stopped is not, and
/// by the time the listener notices, the place they wanted is gone.
///
/// The vectors here are the ones `validation/verify_book.py` runs against 234
/// real LibriVox books. This suite pins the same behaviour in Swift.
final class BookTests: XCTestCase {

    /// Three files of 10, 20 and 30 seconds. Small enough to reason about by
    /// hand, which is the point: every boundary below is checkable on paper.
    private func threeFileBook(declaredTotalMS: Int64? = nil) throws -> Book {
        try Book(
            id: "b",
            title: "Three",
            tracks: [
                Track(id: "t1", title: "One", durationMS: 10_000),
                Track(id: "t2", title: "Two", durationMS: 20_000),
                Track(id: "t3", title: "Three", durationMS: 30_000)
            ],
            declaredTotalMS: declaredTotalMS
        )
    }

    // MARK: - W1, boundaries

    func testABoundaryBelongsToTheTrackThatFollowsIt() throws {
        let book = try threeFileBook()

        // 10,000 ms is simultaneously the end of file 1 and the start of file
        // 2. It has to be read as the start of file 2, or a bookmark saved at
        // a chapter end replays the whole previous file.
        XCTAssertEqual(book.locate(10_000), Bookmark(trackID: "t2", offsetMS: 0))
        XCTAssertEqual(book.locate(30_000), Bookmark(trackID: "t3", offsetMS: 0))

        // One millisecond either side, to pin which way the comparison runs.
        XCTAssertEqual(book.locate(9_999), Bookmark(trackID: "t1", offsetMS: 9_999))
        XCTAssertEqual(book.locate(10_001), Bookmark(trackID: "t2", offsetMS: 1))
    }

    func testEveryBoundaryRoundTrips() throws {
        let book = try threeFileBook()
        for index in book.tracks.indices {
            let start = book.start(of: index)
            XCTAssertEqual(book.absolute(book.locate(start)), start)
        }
        XCTAssertEqual(book.absolute(book.locate(book.totalMS)), book.totalMS)
    }

    // MARK: - W2, outside the book

    func testPositionsOutsideTheBookClampRatherThanWrap() throws {
        let book = try threeFileBook()

        XCTAssertEqual(book.locate(-1), Bookmark(trackID: "t1", offsetMS: 0))
        XCTAssertEqual(book.locate(Int64.min), Bookmark(trackID: "t1", offsetMS: 0))

        let end = Bookmark(trackID: "t3", offsetMS: 30_000)
        XCTAssertEqual(book.locate(60_000), end)
        XCTAssertEqual(book.locate(999_999_999), end)
        XCTAssertEqual(book.locate(Int64.max), end)
    }

    // MARK: - W3, the declared total

    func testTheDeclaredTotalIsReportedAndNeverUsed() throws {
        // A publisher claiming 45 seconds for a book whose files add to 60.
        // In the LibriVox corpus 103 of 234 books disagree with themselves
        // this way, the worst by more than five hours.
        let book = try threeFileBook(declaredTotalMS: 45_000)

        XCTAssertEqual(book.totalMS, 60_000)
        XCTAssertEqual(book.declaredDisagreementMS, -15_000)

        // The disagreement must not leak into position arithmetic.
        XCTAssertEqual(book.locate(50_000), Bookmark(trackID: "t3", offsetMS: 20_000))
        XCTAssertEqual(book.remainingMS(from: Bookmark(trackID: "t3", offsetMS: 20_000)), 10_000)
    }

    // MARK: - W4, surviving a changed library

    func testABookmarkSurvivesAFileBeingInsertedBeforeIt() throws {
        let before = try threeFileBook()
        let mark = Bookmark(trackID: "t3", offsetMS: 5_000)
        XCTAssertEqual(before.absolute(mark), 35_000)

        // Someone adds the prologue they forgot to download.
        let after = try Book(
            id: "b",
            title: "Three",
            tracks: [
                Track(id: "t0", title: "Prologue", durationMS: 7_000),
                Track(id: "t1", title: "One", durationMS: 10_000),
                Track(id: "t2", title: "Two", durationMS: 20_000),
                Track(id: "t3", title: "Three", durationMS: 30_000)
            ]
        )

        // The place is unchanged in the story, even though its absolute
        // position moved by the length of the prologue. That is the whole
        // reason bookmarks are anchored to a file id.
        XCTAssertEqual(after.resolve(mark), mark)
        XCTAssertEqual(after.absolute(mark), 42_000)
    }

    func testABookmarkSurvivesReordering() throws {
        let mark = Bookmark(trackID: "t2", offsetMS: 12_000)
        let reordered = try Book(
            id: "b",
            title: "Three",
            tracks: [
                Track(id: "t3", title: "Three", durationMS: 30_000),
                Track(id: "t2", title: "Two", durationMS: 20_000),
                Track(id: "t1", title: "One", durationMS: 10_000)
            ]
        )
        XCTAssertEqual(reordered.resolve(mark), mark)
    }

    func testAMissingFileIsRebasedByPositionAndNotSilentlyKept() throws {
        let previous = try threeFileBook()
        let mark = Bookmark(trackID: "t2", offsetMS: 12_000)   // 22,000 absolute

        // The middle file was deleted to free space.
        let now = try Book(
            id: "b",
            title: "Three",
            tracks: [
                Track(id: "t1", title: "One", durationMS: 10_000),
                Track(id: "t3", title: "Three", durationMS: 30_000)
            ]
        )

        let rebased = now.rebase(mark, from: previous)
        // 22,000 in the old book lands 12,000 into what is now the second
        // file. Not the same place in the story 鈥?nothing could be 鈥?but
        // defined, and reported as a jump by PlaybackState.
        XCTAssertEqual(rebased, Bookmark(trackID: "t3", offsetMS: 12_000))

        // Without the old book there is nothing to measure against, so it
        // returns to the start rather than guessing.
        XCTAssertEqual(now.resolve(mark), Bookmark(trackID: "t1", offsetMS: 0))
    }

    // MARK: - W5, metadata that lies

    func testAnOffsetPastTheEndOfItsFileIsClamped() throws {
        let book = try threeFileBook()
        let optimistic = Bookmark(trackID: "t1", offsetMS: 99_000)

        XCTAssertEqual(book.resolve(optimistic), Bookmark(trackID: "t1", offsetMS: 10_000))
        // And the absolute position stays inside file 1's span rather than
        // running into file 2.
        XCTAssertEqual(book.absolute(optimistic), 10_000)
    }

    func testNegativeOffsetsClamp() throws {
        let book = try threeFileBook()
        XCTAssertEqual(book.absolute(Bookmark(trackID: "t2", offsetMS: -5_000)), 10_000)
    }

    // MARK: - W6, integer milliseconds

    func testALongBookLandsOnExactBoundaries() throws {
        // 55 hours in 200 files. The Count of Monte Cristo in the reference
        // corpus is 54.95 hours; this is that shape, rounded up.
        let tracks = try (0..<200).map {
            try Track(id: "t\($0)", title: "", durationMS: 990_000)
        }
        let book = try Book(id: "long", title: "Long", tracks: tracks)
        XCTAssertEqual(book.totalMS, 198_000_000)

        for index in book.tracks.indices {
            let start = book.start(of: index)
            XCTAssertEqual(book.locate(start), Bookmark(trackID: "t\(index)", offsetMS: 0))
            XCTAssertEqual(book.absolute(book.locate(start)), start)
        }

        // Why this is not a Float: at 198 million the spacing between
        // representable Float values is 16, so the same arithmetic in Float
        // cannot name the second it is in. Asserted rather than asserted-about,
        // so a future "just use TimeInterval" change has to argue with a test.
        let boundary = book.start(of: 199)
        XCTAssertNotEqual(Int64(Float(boundary)), boundary)
        XCTAssertEqual(Int64(Double(boundary)), boundary)
    }

    // MARK: - W7, chapters are not files

    func testChaptersFromFilesCoverTheBookWithNoGaps() throws {
        let book = try threeFileBook()
        let chapters = book.chaptersFromTracks()

        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].startMS, 0)
        XCTAssertEqual(chapters[2].endMS, book.totalMS)
        for index in 1..<chapters.count {
            XCTAssertEqual(chapters[index].startMS, chapters[index - 1].endMS)
        }
    }

    func testChapterMarksInsideOneFileDoNotLoseTheAudioBeforeTheFirstMark() throws {
        let book = try Book(
            id: "m4b",
            title: "Single",
            tracks: [Track(id: "only", title: "", durationMS: 60_000)]
        )
        // The first mark is at 5,000: there is five seconds of introduction
        // before it. Zipping the marks together drops it.
        let chapters = try book.chapters(fromMarks: [("One", 5_000), ("Two", 20_000)])

        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].startMS, 0)
        XCTAssertEqual(chapters[0].endMS, 5_000)
        XCTAssertEqual(chapters[0].title, "")
        XCTAssertEqual(chapters[2].endMS, 60_000)
    }

    func testDuplicateAndOutOfRangeMarks() throws {
        let book = try Book(
            id: "m4b",
            title: "Single",
            tracks: [Track(id: "only", title: "", durationMS: 60_000)]
        )
        // A duplicate would create a zero-length chapter, which shows up in
        // the UI as an unreachable row.
        let chapters = try book.chapters(
            fromMarks: [("One", 0), ("Dup", 0), ("Past the end", 90_000)]
        )
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "One")
        XCTAssertEqual(chapters[1].startMS, 60_000)
        XCTAssertEqual(chapters[1].endMS, 60_000)

        XCTAssertThrowsError(try book.chapters(fromMarks: [("Two", 20_000), ("One", 5_000)]))
    }

    func testAChapterSpanningAFileBoundary() throws {
        let book = try threeFileBook()
        // One chapter covering the back half of file 1 and all of file 2.
        let chapters = try book.chapters(fromMarks: [("Spans", 5_000), ("After", 30_000)])

        XCTAssertEqual(chapters[1].startMS, 5_000)
        XCTAssertEqual(chapters[1].endMS, 30_000)
        // Positions inside the span report the same chapter regardless of
        // which file they are physically in.
        XCTAssertEqual(chapterIndex(in: chapters, at: 6_000), 1)
        XCTAssertEqual(chapterIndex(in: chapters, at: 25_000), 1)
        // And the chapter boundary follows the same rule as the file boundary.
        XCTAssertEqual(chapterIndex(in: chapters, at: 30_000), 2)
    }

    // MARK: - Refusing incoherent books

    func testABookMustBeDescribable() throws {
        XCTAssertThrowsError(try Book(id: "b", title: "", tracks: []))
        XCTAssertThrowsError(try Track(id: "", title: "", durationMS: 1_000))
        XCTAssertThrowsError(try Track(id: "t", title: "", durationMS: 0))
        XCTAssertThrowsError(
            try Book(
                id: "b",
                title: "",
                tracks: [
                    Track(id: "same", title: "", durationMS: 1_000),
                    Track(id: "same", title: "", durationMS: 1_000)
                ]
            )
        )
    }

    // MARK: - The search itself

    func testUpperBoundMatchesALinearScan() {
        let sorted: [Int64] = [0, 10, 10, 25, 40, 40, 40, 99]
        for probe in Int64(-5)...105 {
            let expected = sorted.filter { $0 <= probe }.count
            XCTAssertEqual(upperBound(sorted, probe), expected, "probe \(probe)")
        }
    }
}
