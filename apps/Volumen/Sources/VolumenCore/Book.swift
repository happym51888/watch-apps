import Foundation

/// The book cannot be described coherently.
public struct BookError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One file of a book.
///
/// `id` is the anchor for every saved place in the library, so it has to
/// survive a re-download. It is derived from the file's own identity — see
/// `TrackIdentity` — not from its position in the list.
public struct Track: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Integer milliseconds. See `Book` for why this is not a `Float`.
    public let durationMS: Int64

    public init(id: String, title: String, durationMS: Int64) throws {
        guard !id.isEmpty else { throw BookError("a track needs a stable id") }
        guard durationMS > 0 else {
            throw BookError("track \(id) has duration \(durationMS)")
        }
        self.id = id
        self.title = title
        self.durationMS = durationMS
    }
}

/// A named span of the book, in absolute milliseconds.
public struct Chapter: Sendable, Equatable {
    public let title: String
    public let startMS: Int64
    public let endMS: Int64

    public var durationMS: Int64 { endMS - startMS }

    public init(title: String, startMS: Int64, endMS: Int64) {
        self.title = title
        self.startMS = startMS
        self.endMS = endMS
    }
}

/// Where the listener is.
///
/// Anchored to a track id and an offset inside that track, never to a
/// book-wide offset. The book-wide offset is a view, derived on demand; if it
/// were the stored form, inserting a forgotten prologue would move every saved
/// place in the library at once. (Hazard W4.)
public struct Bookmark: Sendable, Equatable, Codable {
    public let trackID: String
    public let offsetMS: Int64

    public init(trackID: String, offsetMS: Int64) {
        self.trackID = trackID
        self.offsetMS = offsetMS
    }
}

/// A book: an ordered pile of files, and the arithmetic that keeps a place in
/// it.
///
/// Books arrive as separate files because that is how they are published and
/// because a watch will not take a twelve-hour single file. Keeping a
/// listener's place across that pile is the whole product, and every failure
/// in it is silent — nothing throws, the listener just ends up in the wrong
/// part of the story.
///
/// Positions are `Int64` milliseconds throughout. A 55-hour book is 198
/// million milliseconds; `Float` holds integers exactly only to 2^24, which is
/// 4h39m, and 72 of the 234 books in the reference corpus are longer than
/// that. `TimeInterval` is a `Double` and would be fine, but it invites
/// fractional arithmetic into comparisons that must be exact, so the model
/// stays integral and converts at the AVFoundation boundary. (Hazard W6.)
///
/// Held against `validation/book_model.py`, which is in turn held against 234
/// real LibriVox books by `validation/verify_book.py`.
public struct Book: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let tracks: [Track]
    /// What the publisher says the total is.
    ///
    /// Kept only so the disagreement can be reported. It is never used to map
    /// a position: in the reference corpus 103 of 234 books disagree with
    /// their own file list, the worst by more than five hours. (Hazard W3.)
    public let declaredTotalMS: Int64?

    /// Cumulative start of each track. Computed once; `locate` binary-searches
    /// it on every scrub tick.
    private let starts: [Int64]

    public init(id: String, title: String, tracks: [Track], declaredTotalMS: Int64? = nil) throws {
        guard !tracks.isEmpty else { throw BookError("a book needs at least one track") }
        guard Set(tracks.map(\.id)).count == tracks.count else {
            throw BookError("track ids must be unique within a book")
        }
        var running: Int64 = 0
        var starts: [Int64] = []
        starts.reserveCapacity(tracks.count)
        for track in tracks {
            starts.append(running)
            running += track.durationMS
        }
        self.id = id
        self.title = title
        self.tracks = tracks
        self.declaredTotalMS = declaredTotalMS
        self.starts = starts
    }

    // MARK: - Geometry

    /// The only total that means anything: the sum of the files.
    public var totalMS: Int64 {
        starts[starts.count - 1] + tracks[tracks.count - 1].durationMS
    }

    /// How far the publisher's stated total is from reality. (Hazard W3.)
    public var declaredDisagreementMS: Int64 {
        guard let declared = declaredTotalMS else { return 0 }
        return declared - totalMS
    }

    public func start(of index: Int) -> Int64 { starts[index] }

    public func index(ofTrack trackID: String) -> Int? {
        tracks.firstIndex { $0.id == trackID }
    }

    // MARK: - Position mapping

    /// Absolute position in the book to a place inside one file.
    ///
    /// A boundary belongs to the track that *follows* it: an absolute position
    /// equal to the cumulative end of file 3 is the first instant of file 4,
    /// not the last instant of file 3. Off by one here and every bookmark
    /// saved at a chapter end replays a whole file or skips one. (Hazard W1.)
    ///
    /// Positions outside the book clamp to its ends rather than wrapping,
    /// which would turn "finished the book" into "start again somewhere in the
    /// middle". (Hazard W2.)
    public func locate(_ absoluteMS: Int64) -> Bookmark {
        if absoluteMS <= 0 {
            return Bookmark(trackID: tracks[0].id, offsetMS: 0)
        }
        if absoluteMS >= totalMS {
            let last = tracks[tracks.count - 1]
            return Bookmark(trackID: last.id, offsetMS: last.durationMS)
        }
        let index = upperBound(starts, absoluteMS) - 1
        return Bookmark(trackID: tracks[index].id, offsetMS: absoluteMS - starts[index])
    }

    /// A place inside one file back to an absolute book position.
    ///
    /// An offset past the end of its file is clamped rather than trusted,
    /// because durations come from metadata and metadata is sometimes wrong.
    /// (Hazard W5.)
    public func absolute(_ mark: Bookmark) -> Int64 {
        guard let index = index(ofTrack: mark.trackID) else { return 0 }
        let offset = min(max(0, mark.offsetMS), tracks[index].durationMS)
        return starts[index] + offset
    }

    public func remainingMS(from mark: Bookmark) -> Int64 {
        totalMS - absolute(mark)
    }

    // MARK: - Surviving a change of contents

    /// Re-anchor a bookmark against this book's current contents.
    ///
    /// If the file is still here the place is exact and nothing moves, no
    /// matter what was added or removed around it — that is the point of
    /// anchoring to identity. If the file is gone the answer has to be defined
    /// rather than accidental, so it lands at the start of the book and the
    /// caller is expected to say so. (Hazard W4.)
    public func resolve(_ mark: Bookmark) -> Bookmark {
        guard let index = index(ofTrack: mark.trackID) else {
            return Bookmark(trackID: tracks[0].id, offsetMS: 0)
        }
        let offset = min(max(0, mark.offsetMS), tracks[index].durationMS)
        return Bookmark(trackID: mark.trackID, offsetMS: offset)
    }

    /// Best effort when the very file a bookmark named has disappeared.
    ///
    /// Falls back to the same absolute position measured in the *old* book,
    /// which is the least wrong thing available and claims nothing about being
    /// exact. `PlaybackState` surfaces this to the listener as a jump rather
    /// than pretending the place was kept.
    public func rebase(_ mark: Bookmark, from previous: Book) -> Bookmark {
        if index(ofTrack: mark.trackID) != nil { return resolve(mark) }
        return locate(previous.absolute(mark))
    }

    // MARK: - Chapters

    /// One file per chapter — the LibriVox shape. (Hazard W7.)
    public func chaptersFromTracks() -> [Chapter] {
        tracks.enumerated().map { index, track in
            Chapter(
                title: track.title.isEmpty ? "Track \(index + 1)" : track.title,
                startMS: starts[index],
                endMS: starts[index] + track.durationMS
            )
        }
    }

    /// One file carrying internal chapter marks — the M4B shape. (Hazard W7.)
    ///
    /// Each chapter runs to the next mark, the last to the end of the book. A
    /// mark at zero is not required: audio before the first mark becomes an
    /// untitled opening chapter rather than vanishing, which is what happens
    /// if you simply zip the marks together.
    public func chapters(fromMarks marks: [(title: String, startMS: Int64)]) throws -> [Chapter] {
        var cleaned: [(title: String, startMS: Int64)] = []
        for mark in marks {
            let start = min(max(0, mark.startMS), totalMS)
            if let last = cleaned.last {
                if start < last.startMS {
                    throw BookError("chapter marks are out of order at \(start)")
                }
                // A duplicate mark would create a zero-length chapter.
                if start == last.startMS { continue }
            }
            cleaned.append((mark.title, start))
        }
        if cleaned.isEmpty {
            return [Chapter(title: title.isEmpty ? "Book" : title, startMS: 0, endMS: totalMS)]
        }
        if cleaned[0].startMS > 0 {
            cleaned.insert(("", 0), at: 0)
        }
        return cleaned.enumerated().map { index, mark in
            let end = index + 1 < cleaned.count ? cleaned[index + 1].startMS : totalMS
            return Chapter(title: mark.title, startMS: mark.startMS, endMS: end)
        }
    }
}

extension Chapter {
    /// Which chapter covers this instant.
    ///
    /// W1 again on a second axis: a position exactly on a chapter's start is in
    /// that chapter. Positions outside the book clamp to the first or last.
    ///
    /// A static method rather than a free function so that `PlaybackState` can
    /// call it from inside its own `chapterIndex` property. A free function of
    /// the same name needs a `VolumenCore.` prefix there to disambiguate, and
    /// that prefix only exists when this file is a module — which it is under
    /// `swift test` and is not when the sources compile straight into the watch
    /// target. The tests would have kept passing and the app would not build.
    public static func index(in chapters: [Chapter], at absoluteMS: Int64) -> Int {
        precondition(!chapters.isEmpty, "no chapters")
        if absoluteMS <= chapters[0].startMS { return 0 }
        if absoluteMS >= chapters[chapters.count - 1].endMS { return chapters.count - 1 }
        return upperBound(chapters.map(\.startMS), absoluteMS) - 1
    }
}

/// First index whose value is strictly greater than `value`.
///
/// Written out rather than reached for, because Swift's standard library has
/// no `bisect_right` and the obvious `firstIndex(where:)` is linear — this
/// runs on every scrub tick over a 200-file book.
func upperBound(_ sorted: [Int64], _ value: Int64) -> Int {
    var low = 0
    var high = sorted.count
    while low < high {
        let mid = low + (high - low) / 2
        if sorted[mid] <= value {
            low = mid + 1
        } else {
            high = mid
        }
    }
    return low
}
