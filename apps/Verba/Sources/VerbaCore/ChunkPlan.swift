import Foundation

/// Splits a long recording into overlapping windows for transcription.
///
/// Apple's speech recognisers accept a bounded amount of audio per request, so
/// a forty-minute meeting has to be fed through in pieces. Cutting on a fixed
/// grid loses whatever word straddles each cut, which produces transcripts that
/// read fine and are quietly missing a word every few minutes — the worst kind
/// of wrong, because nothing looks broken.
///
/// The fix is to overlap the windows and then remove the duplicated region when
/// stitching. This type computes the windows; `TranscriptStitcher` removes the
/// duplication. Both are pure, and both are swept in
/// `validation/verify_queue.py`.
public struct ChunkPlan: Sendable, Equatable {

    public struct Chunk: Sendable, Equatable {
        public let index: Int
        public let start: TimeInterval
        public let end: TimeInterval

        public var duration: TimeInterval { end - start }
    }

    public let chunks: [Chunk]
    public let overlap: TimeInterval

    /// - Parameters:
    ///   - duration: total seconds of audio.
    ///   - window: maximum seconds fed to the recogniser in one request.
    ///   - overlap: seconds each window extends back into the previous one.
    ///     Needs to comfortably exceed the longest single spoken word; five
    ///     seconds covers even slow, emphatic speech.
    public init(duration: TimeInterval, window: TimeInterval = 55, overlap: TimeInterval = 5) {
        precondition(duration >= 0, "duration cannot be negative")
        precondition(window > 0, "window must be positive")
        precondition(overlap >= 0, "overlap cannot be negative")
        precondition(overlap < window, "overlap must be smaller than the window, or no progress is made")

        self.overlap = overlap

        // Anything that fits in one request is one chunk, with no seam to get
        // wrong.
        guard duration > window else {
            self.chunks = [Chunk(index: 0, start: 0, end: duration)]
            return
        }

        var result: [Chunk] = []
        let stride = window - overlap
        var start: TimeInterval = 0
        var index = 0

        while start < duration {
            let end = min(start + window, duration)
            result.append(Chunk(index: index, start: start, end: end))
            if end >= duration { break }
            start += stride
            index += 1
        }

        // A final sliver shorter than the overlap carries no new audio — every
        // second of it is already inside the previous window — and asking the
        // recogniser to transcribe pure duplication only creates seam work.
        if result.count >= 2, let last = result.last, last.duration <= overlap {
            result.removeLast()
            var extended = result.removeLast()
            extended = Chunk(index: extended.index, start: extended.start, end: duration)
            result.append(extended)
        }

        self.chunks = result
    }

    /// Every second of the original audio appears in at least one chunk.
    /// Checked in tests rather than assumed, because a gap here is silent.
    public var coversEverything: Bool {
        guard let first = chunks.first else { return false }
        guard first.start == 0 else { return false }
        for (earlier, later) in zip(chunks, chunks.dropFirst()) {
            if later.start > earlier.end { return false }
        }
        return true
    }
}
