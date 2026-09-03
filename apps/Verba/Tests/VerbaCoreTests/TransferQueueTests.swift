import XCTest
@testable import VerbaCore

/// The queue is the only part of this app whose failure is unrecoverable.
/// Everything here defends one sentence: audio that exists only on the watch is
/// never deleted.
final class TransferQueueTests: XCTestCase {

    private func recording(
        _ name: String,
        at seconds: TimeInterval,
        bytes: Int = 1_000
    ) -> Recording {
        Recording(
            id: RecordingID(raw: name),
            startedAt: Date(timeIntervalSince1970: seconds),
            byteCount: bytes
        )
    }

    // MARK: - The invariant

    func testEvictionOnlyEverTargetsDeliveredRecordings() {
        var queue = TransferQueue(
            policy: StoragePolicy(byteBudget: 1_000, keepDeliveredCount: 0)
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Twenty recordings, none delivered, all far over the budget.
        for index in 0..<20 {
            let actions = queue.enqueue(
                recording("r\(index)", at: 1_700_000_000 + Double(index), bytes: 900),
                now: now
            )
            for action in actions {
                if case .deleteLocalFile = action {
                    XCTFail("evicted audio that exists nowhere else")
                }
            }
        }

        XCTAssertEqual(queue.items.filter(\.hasLocalFile).count, 20)
        XCTAssertEqual(queue.soleCopyBytes, 20 * 900)
    }

    func testStoragePressureIsReportedRatherThanResolvedByDeleting() {
        var queue = TransferQueue(
            policy: StoragePolicy(byteBudget: 1_000, keepDeliveredCount: 5)
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = queue.enqueue(recording("a", at: 1, bytes: 800), now: now)
        let actions = queue.enqueue(recording("b", at: 2, bytes: 800), now: now)

        let reported = actions.contains {
            if case .reportStoragePressure = $0 { return true }
            return false
        }
        XCTAssertTrue(reported, "the user must be warned before recording fails")
        XCTAssertEqual(queue.items.filter(\.hasLocalFile).count, 2)
    }

    // MARK: - Crash recovery

    func testCrashMidTransferRestartsRatherThanStranding() {
        var queue = TransferQueue()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = queue.enqueue(recording("a", at: 1), now: now)
        XCTAssertEqual(queue.item(RecordingID(raw: "a"))?.state, .inFlight)

        // The process dies. No success, no failure, ever.
        let actions = queue.recoverAfterLaunch(now: now.addingTimeInterval(60))

        XCTAssertEqual(queue.item(RecordingID(raw: "a"))?.state, .inFlight)
        XCTAssertTrue(actions.contains(.startDelivery(RecordingID(raw: "a"))))
    }

    /// A crash must not be charged as a failed attempt, or an app that is
    /// killed often enough marks healthy recordings as blocked.
    func testRepeatedCrashesCostNoAttempts() {
        var queue = TransferQueue()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = queue.enqueue(recording("a", at: 1), now: now)

        for _ in 0..<50 {
            _ = queue.recoverAfterLaunch(now: now)
        }

        XCTAssertEqual(queue.item(RecordingID(raw: "a"))?.attempts, 0)
        XCTAssertEqual(queue.item(RecordingID(raw: "a"))?.state, .inFlight)
    }

    // MARK: - Idempotence

    func testDuplicateEnqueueIsAbsorbed() {
        var queue = TransferQueue()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = queue.enqueue(recording("dup", at: 1), now: now)
        let second = queue.enqueue(recording("dup", at: 1), now: now)

        XCTAssertEqual(queue.items.count, 1)
        XCTAssertTrue(second.isEmpty)
    }

    /// Both delivery paths can win the race. A late failure arriving after a
    /// success must not drag a delivered recording back into the retry loop.
    func testLateFailureCannotUndoDelivery() {
        var queue = TransferQueue()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = queue.enqueue(recording("a", at: 1), now: now)
        _ = queue.deliverySucceeded(RecordingID(raw: "a"), now: now)

        let actions = queue.deliveryFailed(
            RecordingID(raw: "a"), retryable: true, reason: "late",
            now: now, randomFraction: 0.5
        )

        XCTAssertEqual(queue.item(RecordingID(raw: "a"))?.state, .delivered)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: - Ordering

    func testBacklogDrainsOldestFirstWhateverOrderItLoadedIn() {
        let stored = [50.0, 10.0, 30.0, 0.0, 40.0, 20.0].map {
            recording("t\(Int($0))", at: 1_700_000_000 + $0)
        }
        var queue = TransferQueue(items: stored, maxConcurrent: 1)
        var now = Date(timeIntervalSince1970: 1_700_000_100)
        _ = queue.recoverAfterLaunch(now: now)

        var order: [String] = []
        for _ in 0..<6 {
            let inFlight = queue.items.filter { $0.state == .inFlight }
            XCTAssertEqual(inFlight.count, 1, "one delivery at a time")
            guard let next = inFlight.first else { break }
            order.append(next.id.raw)
            now = now.addingTimeInterval(1)
            _ = queue.deliverySucceeded(next.id, now: now)
        }

        XCTAssertEqual(order, ["t0", "t10", "t20", "t30", "t40", "t50"])
    }

    // MARK: - Blocking

    func testNonRetryableFailureBlocksButKeepsTheFile() {
        var queue = TransferQueue()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = queue.enqueue(recording("a", at: 1), now: now)

        _ = queue.deliveryFailed(
            RecordingID(raw: "a"), retryable: false, reason: "corrupt",
            now: now, randomFraction: 0
        )

        let item = queue.item(RecordingID(raw: "a"))
        XCTAssertEqual(item?.state, .blocked)
        XCTAssertEqual(item?.blockReason, "corrupt")
        XCTAssertTrue(item?.hasLocalFile == true, "a blocked recording keeps its audio")
        XCTAssertNil(item?.nextAttemptAt)
    }

    func testRetryClearsBlockedState() {
        var queue = TransferQueue()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = queue.enqueue(recording("a", at: 1), now: now)
        _ = queue.deliveryFailed(
            RecordingID(raw: "a"), retryable: false, reason: "nope",
            now: now, randomFraction: 0
        )

        _ = queue.retryNow(RecordingID(raw: "a"), now: now)

        XCTAssertEqual(queue.item(RecordingID(raw: "a"))?.state, .inFlight)
        XCTAssertEqual(queue.item(RecordingID(raw: "a"))?.attempts, 0)
        XCTAssertNil(queue.item(RecordingID(raw: "a"))?.blockReason)
    }
}

// MARK: - Backoff

final class BackoffTests: XCTestCase {

    func testDelayStaysWithinBounds() {
        let backoff = Backoff(base: 2, cap: 3600, attemptsBeforePausing: 12)
        for attempts in 0..<60 {
            for fraction in [0.0, 0.25, 0.5, 0.9999] {
                let delay = backoff.delay(afterFailures: attempts, randomFraction: fraction)
                XCTAssertGreaterThanOrEqual(delay, 1)
                XCTAssertLessThanOrEqual(delay, 3600)
                XCTAssertTrue(delay.isFinite)
            }
        }
    }

    /// Without a cap the doubling overflows to infinity, and a recording that
    /// fails forty times is scheduled for the heat death of the universe.
    func testCeilingSaturatesRatherThanOverflowing() {
        let backoff = Backoff(base: 2, cap: 3600)
        let ceilings = (0..<40).map {
            backoff.delay(afterFailures: $0, randomFraction: 0.9999)
        }
        for (earlier, later) in zip(ceilings, ceilings.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later, earlier - 1e-9)
        }
        XCTAssertEqual(ceilings.last ?? 0, 3600, accuracy: 1)
    }
}

// MARK: - Chunking and stitching

final class TranscriptTests: XCTestCase {

    func testChunkPlanCoversEverySecond() {
        for duration in [0.0, 1.0, 54.9, 55.0, 55.1, 300.0, 3600.0] {
            let plan = ChunkPlan(duration: duration, window: 55, overlap: 5)
            XCTAssertTrue(plan.coversEverything, "gap at \(duration)s")
            XCTAssertEqual(plan.chunks.first?.start, 0)
            XCTAssertEqual(plan.chunks.last?.end, duration)
            for chunk in plan.chunks {
                XCTAssertLessThanOrEqual(chunk.duration, 55 + 1e-9)
            }
        }
    }

    func testShortRecordingIsNeverSplit() {
        XCTAssertEqual(ChunkPlan(duration: 54, window: 55).chunks.count, 1)
        XCTAssertEqual(ChunkPlan(duration: 55, window: 55).chunks.count, 1)
        XCTAssertGreaterThan(ChunkPlan(duration: 55.1, window: 55).chunks.count, 1)
    }

    func testStitchRemovesTheOverlap() {
        XCTAssertEqual(
            TranscriptStitcher.stitch(["the quick brown fox jumps", "brown fox jumps over the lazy dog"]),
            "the quick brown fox jumps over the lazy dog"
        )
    }

    func testStitchIgnoresCaseAndPunctuationAtTheSeam() {
        XCTAssertEqual(
            TranscriptStitcher.stitch(["we ship on Friday", "Friday, if tests pass"]),
            "we ship on Friday if tests pass"
        )
    }

    /// When no seam can be found, keeping both chunks is correct. A visible
    /// repetition can be deleted by the user; deleted speech cannot be
    /// recovered by anyone.
    func testUnrecognisedSeamKeepsEverything() {
        let result = TranscriptStitcher.stitch(["completely unrelated", "entirely different"])
        XCTAssertTrue(result.contains("completely unrelated"))
        XCTAssertTrue(result.contains("entirely different"))
    }

    func testRepetitiveSpeechIsNotOverCollapsed() {
        let result = TranscriptStitcher.stitch(["yes yes yes yes", "yes yes yes yes no"])
        let count = result.split(separator: " ").filter { $0 == "yes" }.count
        XCTAssertGreaterThanOrEqual(count, 4, "must not delete a real repetition")
        XCTAssertTrue(result.hasSuffix("no"))
    }

    func testTitleTruncatesOnAWordBoundary() {
        let title = Transcript.title(
            from: "remember to call the dentist about the appointment on Thursday morning",
            limit: 30
        )
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.dropLast().hasSuffix(" "))
        XCTAssertLessThanOrEqual(title.count, 31)
    }

    func testTitleHandlesEmptyInput() {
        XCTAssertEqual(Transcript.title(from: "   "), "Untitled")
    }
}
