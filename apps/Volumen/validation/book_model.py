"""Reference implementation of Volumen's book position model, in Python.

Volumen carries DRM-free audiobooks onto the watch and keeps your place while
the phone stays at home. A book arrives as a pile of separate files, because
that is how they are published and because the watch will not take a
twelve-hour single file. Keeping a listener's place across that pile is the
entire product, and it is where the quiet failures live.

This file mirrors `Sources/VolumenCore` so the Swift port can be held against
the same vectors that `verify_book.py` holds this against.

The hazards, each of which loses somebody's place in a long book and none of
which raises:

  W1  A boundary belongs to the track that follows it. Absolute position equal
      to the cumulative end of file 3 is the start of file 4, not the last
      instant of file 3. Get it wrong and every bookmark saved at a chapter
      end replays the previous file's final second, or skips one.
  W2  Positions outside the book clamp to its ends. Wrapping or going negative
      turns "finished the book" into "start again from somewhere".
  W3  The publisher's declared total is not the sum of the files. In the
      LibriVox corpus 103 of 234 books disagree with themselves, one of them
      by more than five hours. Mapping positions through the declared total
      drifts against the audio actually being played.
  W4  A bookmark must be anchored to a file identity, not to a book offset.
      Add, delete or reorder a file and every offset-based bookmark silently
      points somewhere else in the story.
  W5  Metadata durations can be wrong. When a file turns out shorter than
      claimed, the position inside it must be clamped rather than left past
      the end where playback would fail or restart.
  W6  Milliseconds as integers. Float32 counts milliseconds exactly only up
      to 2^24, which is 4h39m of audio; past that a stored position cannot
      name its own second, and 72 of the 234 books are longer than that.
      Swift's `Float` is 32-bit and sits one keystroke from `TimeInterval`.
  W7  Chapters and files are different things. One file per chapter, one file
      with many chapters, and chapters that straddle a file boundary all have
      to produce the same "chapter 12 of 43, 4:31 left" answer.
"""

from __future__ import annotations

import bisect
from dataclasses import dataclass, field
from typing import Iterable, Sequence


class BookError(Exception):
    """The book cannot be described coherently."""


@dataclass(frozen=True)
class Track:
    """One file of a book."""

    track_id: str
    title: str
    duration_ms: int

    def __post_init__(self) -> None:
        if not self.track_id:
            raise BookError("a track needs a stable id")
        if self.duration_ms <= 0:
            raise BookError(f"track {self.track_id!r} has duration {self.duration_ms}")


@dataclass(frozen=True)
class Chapter:
    """A named span of the book, in absolute milliseconds."""

    title: str
    start_ms: int
    end_ms: int

    @property
    def duration_ms(self) -> int:
        return self.end_ms - self.start_ms


@dataclass(frozen=True)
class Bookmark:
    """Where the listener is.

    W4. Anchored to a track id and an offset inside that track, never to a
    book-wide offset. The book-wide offset is a view, derived on demand; if it
    were the stored form, inserting a forgotten prologue would move every
    saved place in the library.
    """

    track_id: str
    offset_ms: int


@dataclass
class Book:
    book_id: str
    title: str
    tracks: tuple[Track, ...]
    # W3. What the publisher says the total is. Kept so the disagreement can
    # be reported, never used to map a position.
    declared_total_ms: int | None = None
    _starts: tuple[int, ...] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        if not self.tracks:
            raise BookError("a book needs at least one track")
        ids = [t.track_id for t in self.tracks]
        if len(set(ids)) != len(ids):
            raise BookError("track ids must be unique within a book")
        starts, running = [], 0
        for track in self.tracks:
            starts.append(running)
            running += track.duration_ms
        object.__setattr__(self, "_starts", tuple(starts))

    # ---- geometry -----------------------------------------------------

    @property
    def total_ms(self) -> int:
        """The only total that means anything: the sum of the files."""
        return self._starts[-1] + self.tracks[-1].duration_ms

    @property
    def declared_disagreement_ms(self) -> int:
        """How far the publisher's stated total is from reality. W3."""
        if self.declared_total_ms is None:
            return 0
        return self.declared_total_ms - self.total_ms

    def start_of(self, index: int) -> int:
        return self._starts[index]

    def index_of(self, track_id: str) -> int:
        for i, track in enumerate(self.tracks):
            if track.track_id == track_id:
                return i
        raise BookError(f"no track {track_id!r} in book {self.book_id!r}")

    # ---- position mapping ---------------------------------------------

    def locate(self, absolute_ms: int) -> Bookmark:
        """Absolute position in the book to a place inside one file.

        W1: a boundary belongs to the following track. W2: outside the book
        clamps to its ends.
        """
        if absolute_ms <= 0:
            return Bookmark(self.tracks[0].track_id, 0)
        if absolute_ms >= self.total_ms:
            last = self.tracks[-1]
            return Bookmark(last.track_id, last.duration_ms)
        # bisect_right: at exactly a track's start, pick that track, not the
        # one before it. This single choice is the whole of W1.
        index = bisect.bisect_right(self._starts, absolute_ms) - 1
        return Bookmark(self.tracks[index].track_id, absolute_ms - self._starts[index])

    def absolute(self, mark: Bookmark) -> int:
        """A place inside one file back to an absolute book position.

        W5: an offset past the end of its file is clamped rather than trusted,
        because durations come from metadata and metadata is sometimes wrong.
        """
        index = self.index_of(mark.track_id)
        offset = max(0, min(mark.offset_ms, self.tracks[index].duration_ms))
        return self._starts[index] + offset

    def remaining_ms(self, mark: Bookmark) -> int:
        return self.total_ms - self.absolute(mark)

    # ---- surviving a change of contents -------------------------------

    def resolve(self, mark: Bookmark) -> Bookmark:
        """Re-anchor a bookmark against this book's current contents.

        W4. If the file is still here, the place is exact and nothing moves,
        no matter what was added or removed around it. If the file is gone the
        answer has to be defined rather than accidental, so it lands at the
        start of the track that now occupies that slot, and at the end of the
        book if there is no such track.
        """
        try:
            index = self.index_of(mark.track_id)
        except BookError:
            return Bookmark(self.tracks[0].track_id, 0)
        offset = max(0, min(mark.offset_ms, self.tracks[index].duration_ms))
        return Bookmark(mark.track_id, offset)

    def rebase(self, mark: Bookmark, previous: "Book") -> Bookmark:
        """Best effort when the very file a bookmark named has disappeared.

        Falls back to the same absolute position measured in the old book,
        which is the least wrong thing available, and says nothing about being
        exact. Callers that care show the listener a "jumped here" note.
        """
        if any(t.track_id == mark.track_id for t in self.tracks):
            return self.resolve(mark)
        return self.locate(previous.absolute(mark))

    # ---- chapters ------------------------------------------------------

    def chapters_from_tracks(self) -> list[Chapter]:
        """W7. One file per chapter, the LibriVox shape."""
        return [
            Chapter(track.title or f"Track {i + 1}", self._starts[i], self._starts[i] + track.duration_ms)
            for i, track in enumerate(self.tracks)
        ]

    def chapters_from_marks(self, marks: Sequence[tuple[str, int]]) -> list[Chapter]:
        """W7. One file with internal chapter marks, the M4B shape.

        `marks` are (title, absolute start in ms), in order. Each chapter runs
        to the next mark, the last to the end of the book. A mark at 0 is not
        required; audio before the first mark becomes an untitled opening
        chapter rather than vanishing.
        """
        cleaned: list[tuple[str, int]] = []
        for title, start in marks:
            start = max(0, min(int(start), self.total_ms))
            if cleaned and start < cleaned[-1][1]:
                raise BookError(f"chapter marks are out of order at {start}")
            if cleaned and start == cleaned[-1][1]:
                continue  # a duplicate mark would create a zero-length chapter
            cleaned.append((title, start))
        if not cleaned:
            return [Chapter(self.title or "Book", 0, self.total_ms)]
        if cleaned[0][1] > 0:
            cleaned.insert(0, ("", 0))
        out = []
        for i, (title, start) in enumerate(cleaned):
            end = cleaned[i + 1][1] if i + 1 < len(cleaned) else self.total_ms
            out.append(Chapter(title, start, end))
        return out


def chapter_index_at(chapters: Sequence[Chapter], absolute_ms: int) -> int:
    """Which chapter covers this instant.

    W1 again, on a second axis: a position exactly on a chapter's start is in
    that chapter. Positions outside the book clamp to the first or last.
    """
    if not chapters:
        raise BookError("no chapters")
    if absolute_ms <= chapters[0].start_ms:
        return 0
    if absolute_ms >= chapters[-1].end_ms:
        return len(chapters) - 1
    starts = [c.start_ms for c in chapters]
    return bisect.bisect_right(starts, absolute_ms) - 1


def book_from_seconds(
    book_id: str,
    title: str,
    section_seconds: Iterable[int],
    titles: Sequence[str] | None = None,
    declared_total_s: int | None = None,
) -> Book:
    """Build a Book from a published section listing.

    W6. Seconds in, milliseconds stored. Everything downstream is integer
    milliseconds so that a fifty-hour book still lands on exact boundaries.
    """
    seconds = list(section_seconds)
    tracks = tuple(
        Track(
            track_id=f"{book_id}/{i + 1:04d}",
            title=(titles[i] if titles and i < len(titles) else ""),
            duration_ms=int(s) * 1000,
        )
        for i, s in enumerate(seconds)
    )
    return Book(
        book_id=book_id,
        title=title,
        tracks=tracks,
        declared_total_ms=None if declared_total_s is None else int(declared_total_s) * 1000,
    )
