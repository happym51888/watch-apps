import Foundation

/// What the player should do next. The state machine performs no I/O, which is
/// the only reason it can be tested exhaustively without a watch.
public enum PlaybackAction: Sendable, Equatable {
    /// Load this file and seek to this offset before playing.
    case load(trackID: String, offsetMS: Int64)
    case play
    case pause
    /// Persist the place. Emitted on every event that could be the last one
    /// before the app is killed.
    case persist(Bookmark)
    /// The file a saved bookmark named is no longer in the book, so the place
    /// was reconstructed by position instead of by identity. Say so; do not
    /// let it look like the place was kept.
    case reportJump(from: Bookmark, to: Bookmark, reason: JumpReason)
    /// Sleep timer expired.
    case fadeOutAndPause
}

public enum JumpReason: Sendable, Equatable {
    /// The named file is gone; the position was carried over from the library
    /// as it was last seen.
    case trackMissing
    /// The named file is present but shorter than the bookmark claimed, so the
    /// offset was clamped to its end.
    case offsetPastEnd
}

/// When the sleep timer should stop playback.
public enum SleepTimer: Sendable, Equatable {
    case off
    /// Stop after this much more playing time.
    ///
    /// Playing time, not wall-clock: a timer that keeps counting while paused
    /// is the classic version of this bug, and it stops the book in the middle
    /// of the night after the listener paused to answer the door.
    case after(playingMS: Int64)
    /// Stop when the current chapter ends. The usual reason a listener sets a
    /// timer at all.
    case endOfChapter
}

/// The player's position, and everything about keeping it that can be wrong
/// without anything visibly breaking.
///
/// `Book` owns the arithmetic; this owns the decisions around it — when to
/// persist, what to do with a bookmark whose file has vanished, and when the
/// sleep timer fires.
public struct PlaybackState: Sendable {

    public private(set) var book: Book
    public private(set) var mark: Bookmark
    public private(set) var isPlaying: Bool
    public private(set) var sleepTimer: SleepTimer
    public private(set) var chapters: [Chapter]

    /// Playing time accumulated since the sleep timer was set.
    private var sleepElapsedMS: Int64 = 0

    public init(book: Book, resuming saved: Bookmark? = nil) {
        self.book = book
        self.mark = saved.map(book.resolve) ?? Bookmark(trackID: book.tracks[0].id, offsetMS: 0)
        self.isPlaying = false
        self.sleepTimer = .off
        self.chapters = book.chaptersFromTracks()
    }

    // MARK: - Derived

    public var absoluteMS: Int64 { book.absolute(mark) }
    public var remainingMS: Int64 { book.remainingMS(from: mark) }

    public var chapterIndex: Int {
        Chapter.index(in: chapters, at: absoluteMS)
    }

    public var currentChapter: Chapter { chapters[chapterIndex] }

    /// Time left in the chapter being played. What the watch face shows, and
    /// what `.endOfChapter` counts down.
    public var chapterRemainingMS: Int64 {
        max(0, currentChapter.endMS - absoluteMS)
    }

    /// Use the tag's chapter list instead of one-chapter-per-file.
    public mutating func adopt(chapters: [Chapter]) {
        guard !chapters.isEmpty else { return }
        self.chapters = chapters
    }

    // MARK: - Opening a book

    /// Restore a saved place, reporting honestly when it could not be kept.
    ///
    /// Split out from `init` because the answer is not always "here you are":
    /// a re-downloaded or re-encoded file has a different id, and the listener
    /// deserves to be told the place was reconstructed rather than kept.
    public static func open(
        book: Book,
        saved: Bookmark?,
        previous: Book? = nil
    ) -> (PlaybackState, [PlaybackAction]) {
        var state = PlaybackState(book: book)
        var actions: [PlaybackAction] = []

        guard let saved else {
            actions.append(.load(trackID: state.mark.trackID, offsetMS: 0))
            return (state, actions)
        }

        if book.index(ofTrack: saved.trackID) == nil {
            // The file is gone. Carrying the absolute position over from the
            // library as it was last seen is the least wrong answer available,
            // and it is still a jump.
            let landed = previous.map { book.rebase(saved, from: $0) }
                ?? Bookmark(trackID: book.tracks[0].id, offsetMS: 0)
            state.mark = landed
            actions.append(.reportJump(from: saved, to: landed, reason: .trackMissing))
        } else {
            let resolved = book.resolve(saved)
            if resolved.offsetMS != saved.offsetMS {
                // Metadata said the file was longer than it is.
                actions.append(.reportJump(from: saved, to: resolved, reason: .offsetPastEnd))
            }
            state.mark = resolved
        }

        actions.append(.load(trackID: state.mark.trackID, offsetMS: state.mark.offsetMS))
        actions.append(.persist(state.mark))
        return (state, actions)
    }

    // MARK: - Transport

    public mutating func play() -> [PlaybackAction] {
        guard !isPlaying else { return [] }
        isPlaying = true
        return [.play]
    }

    public mutating func pause() -> [PlaybackAction] {
        guard isPlaying else { return [] }
        isPlaying = false
        // Persist on pause, always. Pause is the commonest last event before
        // the app is suspended and killed, and a place that is only written on
        // a timer loses whatever happened since the last tick.
        return [.pause, .persist(mark)]
    }

    /// The player reported progress inside the current file.
    ///
    /// `elapsedMS` is how much playing time passed since the previous tick,
    /// used for the sleep timer. It is passed in rather than measured from
    /// wall-clock so that a paused player accumulates nothing.
    public mutating func tick(offsetMS: Int64, elapsedMS: Int64) -> [PlaybackAction] {
        var actions: [PlaybackAction] = []
        mark = book.resolve(Bookmark(trackID: mark.trackID, offsetMS: offsetMS))

        if isPlaying, elapsedMS > 0 {
            sleepElapsedMS += elapsedMS
            if case .after(let budget) = sleepTimer, sleepElapsedMS >= budget {
                sleepTimer = .off
                isPlaying = false
                actions.append(.fadeOutAndPause)
                actions.append(.persist(mark))
            }
        }
        return actions
    }

    /// The current file finished. Move to the next one.
    ///
    /// The new position is the *start* of the next file, which is the same
    /// absolute instant as the end of this one — that identity is what makes
    /// a bookmark saved at a boundary replay correctly instead of repeating a
    /// file. (Hazard W1, on the transport side.)
    public mutating func trackDidEnd() -> [PlaybackAction] {
        guard let index = book.index(ofTrack: mark.trackID) else { return [] }

        if case .endOfChapter = sleepTimer {
            let boundary = book.start(of: index) + book.tracks[index].durationMS
            // Compare the chapter on either side of the boundary rather than
            // against the current position. By the time this is called the
            // position is already *at* the boundary, and a boundary belongs to
            // the chapter that follows it — so comparing against `chapterIndex`
            // would say the chapter had not ended when it just had.
            let endsChapter = boundary >= book.totalMS
                || Chapter.index(in: chapters, at: boundary)
                    != Chapter.index(in: chapters, at: boundary - 1)
            if endsChapter {
                sleepTimer = .off
                isPlaying = false
                mark = book.locate(boundary)
                return [.fadeOutAndPause, .persist(mark)]
            }
        }

        guard index + 1 < book.tracks.count else {
            // End of the book. Park at the end rather than wrapping to the
            // start, so "finished" survives a relaunch.
            isPlaying = false
            mark = Bookmark(
                trackID: book.tracks[index].id,
                offsetMS: book.tracks[index].durationMS
            )
            return [.pause, .persist(mark)]
        }

        let next = book.tracks[index + 1]
        mark = Bookmark(trackID: next.id, offsetMS: 0)
        return [.load(trackID: next.id, offsetMS: 0), .play, .persist(mark)]
    }

    /// Seek by an absolute position in the book, crossing files if needed.
    public mutating func seek(toAbsoluteMS absoluteMS: Int64) -> [PlaybackAction] {
        let target = book.locate(absoluteMS)
        let crossesFile = target.trackID != mark.trackID
        mark = target
        var actions: [PlaybackAction] = []
        if crossesFile {
            actions.append(.load(trackID: target.trackID, offsetMS: target.offsetMS))
            if isPlaying { actions.append(.play) }
        } else {
            actions.append(.load(trackID: target.trackID, offsetMS: target.offsetMS))
        }
        actions.append(.persist(mark))
        return actions
    }

    /// Skip forward or back by a number of milliseconds, clamped to the book.
    ///
    /// Clamped rather than wrapped: a 30-second skip back at 10 seconds into
    /// the first file goes to the start, not to the end of the book.
    public mutating func skip(byMS delta: Int64) -> [PlaybackAction] {
        seek(toAbsoluteMS: absoluteMS + delta)
    }

    public mutating func jump(toChapter index: Int) -> [PlaybackAction] {
        guard chapters.indices.contains(index) else { return [] }
        return seek(toAbsoluteMS: chapters[index].startMS)
    }

    // MARK: - Sleep timer

    public mutating func setSleepTimer(_ timer: SleepTimer) {
        sleepTimer = timer
        sleepElapsedMS = 0
    }

    /// How much playing time is left on the timer, for the UI.
    public var sleepRemainingMS: Int64? {
        switch sleepTimer {
        case .off: return nil
        case .after(let budget): return max(0, budget - sleepElapsedMS)
        case .endOfChapter: return chapterRemainingMS
        }
    }
}
