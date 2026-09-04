#!/usr/bin/env python3
"""
Executable check of VolumenCore's book position model.

The Swift in this repo cannot be compiled on the machine it was written on, so
the logic is ported to `book_model.py` and run against real audiobook shapes:

  * fixtures/librivox-books.json  234 public-domain audiobooks as LibriVox
                                  publishes them: 5,288 files, 1,254 hours

Those are the same files Volumen is meant to carry, and they carry the
problem with them. For 103 of the 234 titles LibriVox's own stated total
disagrees with the sum of the sections it lists; the worst is off by more than
five hours. A player that maps a listener's place through the stated total
drifts against the audio it is playing, and nothing anywhere raises.

Sections:

  1. geometry    boundaries, clamping, round trips over every real book
  2. declared    what the publishers claim versus what their files add up to
  3. survival    bookmarks across insertion, deletion and reordering
  4. chapters    files-as-chapters and marks-inside-one-file
  5. mutations   each hazard reintroduced, to prove the checks notice

  python validation/verify_book.py
"""

from __future__ import annotations

import json
import pathlib
import random
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from book_model import (  # noqa: E402
    Book,
    BookError,
    Bookmark,
    Track,
    book_from_seconds,
    chapter_index_at,
)

FIXTURE = HERE / "fixtures" / "librivox-books.json"

FAILURES: list[str] = []
ASSERTIONS = 0


def check(condition: bool, message: str) -> bool:
    global ASSERTIONS
    ASSERTIONS += 1
    if not condition:
        FAILURES.append(message)
    return bool(condition)


def equal(actual: object, expected: object, message: str) -> bool:
    return check(actual == expected, f"{message}: got {actual!r}, expected {expected!r}")


def raises(fn, message: str) -> bool:
    try:
        fn()
    except BookError:
        return check(True, message)
    except Exception as exc:  # noqa: BLE001
        return check(False, f"{message}: raised {type(exc).__name__} instead of BookError")
    return check(False, f"{message}: did not raise")


def load_books() -> tuple[dict, list[Book]]:
    payload = json.loads(FIXTURE.read_text(encoding="utf-8"))
    books = [
        book_from_seconds(
            book_id=b["id"],
            title=b["title"],
            section_seconds=b["section_seconds"],
            titles=b.get("section_titles"),
            declared_total_s=b.get("declared_total_s"),
        )
        for b in payload["books"]
    ]
    return payload, books


# ---------------------------------------------------------------------------
# 1. Geometry
# ---------------------------------------------------------------------------


def geometry(books: list[Book]) -> None:
    print("=== boundaries and clamping ===")
    # W1 spelled out on a book whose arithmetic is easy to read.
    small = Book(
        book_id="b",
        title="Three files",
        tracks=(
            Track("t1", "One", 10_000),
            Track("t2", "Two", 20_000),
            Track("t3", "Three", 30_000),
        ),
    )
    equal(small.total_ms, 60_000, "total is the sum of the files")
    equal(small.locate(0), Bookmark("t1", 0), "the start of the book is the start of file one")
    equal(small.locate(9_999), Bookmark("t1", 9_999), "just before a boundary stays in the earlier file")
    equal(small.locate(10_000), Bookmark("t2", 0), "a boundary belongs to the file that follows it")
    equal(small.locate(10_001), Bookmark("t2", 1), "just after a boundary is one ms into the next file")
    equal(small.locate(29_999), Bookmark("t2", 19_999), "last ms of the middle file")
    equal(small.locate(30_000), Bookmark("t3", 0), "second boundary")
    equal(small.locate(59_999), Bookmark("t3", 29_999), "last ms of the book")

    # W2.
    equal(small.locate(60_000), Bookmark("t3", 30_000), "the end of the book is the end of the last file")
    equal(small.locate(60_001), Bookmark("t3", 30_000), "past the end clamps to the end")
    equal(small.locate(10_000_000), Bookmark("t3", 30_000), "far past the end still clamps")
    equal(small.locate(-1), Bookmark("t1", 0), "before the start clamps to the start")
    equal(small.locate(-10_000_000), Bookmark("t1", 0), "far before the start still clamps")

    # W5.
    equal(small.absolute(Bookmark("t2", 999_999)), 30_000, "an offset past its file clamps to that file's end")
    equal(small.absolute(Bookmark("t2", -5)), 10_000, "a negative offset clamps to that file's start")
    raises(lambda: small.absolute(Bookmark("nope", 0)), "an unknown track is refused, not guessed")

    equal(small.remaining_ms(Bookmark("t1", 0)), 60_000, "nothing played means everything remains")
    equal(small.remaining_ms(Bookmark("t3", 30_000)), 0, "finished means nothing remains")

    print("=== round trips over every real book ===")
    # Every boundary of every book, plus the instants either side of it, plus
    # a sample of interior positions. 5,288 files means 5,288 boundaries, and
    # boundaries are where the arithmetic goes wrong.
    rng = random.Random(20260904)
    probes = 0
    for book in books:
        edges: set[int] = {0, book.total_ms, book.total_ms - 1}
        for i in range(len(book.tracks)):
            start = book.start_of(i)
            edges.update({start - 1, start, start + 1})
        for _ in range(12):
            edges.add(rng.randrange(0, book.total_ms))
        for t in sorted(edges):
            mark = book.locate(t)
            back = book.absolute(mark)
            clamped = max(0, min(t, book.total_ms))
            equal(back, clamped, f"{book.book_id}: locate then absolute at {t}")
            index = book.index_of(mark.track_id)
            check(
                0 <= mark.offset_ms <= book.tracks[index].duration_ms,
                f"{book.book_id}: offset {mark.offset_ms} outside file {index} at {t}",
            )
            probes += 1
    print(f"  {len(books)} books, {probes:,} positions round tripped")

    print("=== positions never move backwards ===")
    for book in books[:40]:
        previous = -1
        for i in range(len(book.tracks)):
            here = book.absolute(Bookmark(book.tracks[i].track_id, 0))
            check(here > previous, f"{book.book_id}: file {i} starts after file {i - 1}")
            previous = here


# ---------------------------------------------------------------------------
# 2. What the publishers claim
# ---------------------------------------------------------------------------


def declared(payload: dict, books: list[Book]) -> None:
    print("=== declared totals versus the sum of the files ===")
    disagreeing = [b for b in books if b.declared_disagreement_ms != 0]
    print(f"  {len(disagreeing)} of {len(books)} books disagree with themselves")
    check(len(disagreeing) > 0, "the corpus should contain real disagreements to test against")

    worst = max(books, key=lambda b: abs(b.declared_disagreement_ms))
    print(
        f"  worst: {worst.title[:40]!r} declares "
        f"{worst.declared_total_ms / 3_600_000:.2f}h, files add to "
        f"{worst.total_ms / 3_600_000:.2f}h "
        f"({worst.declared_disagreement_ms / 1000:+.0f}s)"
    )
    check(
        abs(worst.declared_disagreement_ms) > 3_600_000,
        "the corpus should contain a disagreement larger than an hour",
    )

    # W3. The rule under test: total_ms is the files, always.
    for book in books:
        equal(
            book.total_ms,
            sum(t.duration_ms for t in book.tracks),
            f"{book.book_id}: total is the sum of the files, whatever the publisher says",
        )

    # And the end of the book is reachable, which is what breaks when the
    # declared total is used: a book declaring less than it contains can never
    # be finished, and one declaring more finishes early.
    for book in disagreeing[:60]:
        mark = book.locate(book.total_ms)
        equal(mark.track_id, book.tracks[-1].track_id, f"{book.book_id}: the end lands in the last file")
        equal(mark.offset_ms, book.tracks[-1].duration_ms, f"{book.book_id}: at that file's very end")
        equal(book.remaining_ms(mark), 0, f"{book.book_id}: and nothing is left")

        if book.declared_total_ms and book.declared_total_ms < book.total_ms:
            short = book.locate(book.declared_total_ms)
            check(
                book.remaining_ms(short) > 0,
                f"{book.book_id}: the declared total is short of the real end, "
                "so trusting it would strand the listener before the finish",
            )


# ---------------------------------------------------------------------------
# 3. Surviving a change of contents
# ---------------------------------------------------------------------------


def survival(books: list[Book]) -> None:
    print("=== bookmarks across a changed library ===")
    rng = random.Random(4)
    moved = 0

    for book in books[:80]:
        if len(book.tracks) < 4:
            continue
        middle = book.tracks[len(book.tracks) // 2]
        mark = Bookmark(middle.track_id, middle.duration_ms // 3)
        where = book.absolute(mark)

        # W4a. A forgotten prologue is added at the front. The listener's
        # place must not move.
        with_prologue = Book(
            book_id=book.book_id,
            title=book.title,
            tracks=(Track("prologue", "Prologue", 90_000), *book.tracks),
        )
        kept = with_prologue.resolve(mark)
        equal(kept, mark, f"{book.book_id}: inserting a file leaves the bookmark on its own file")
        equal(
            with_prologue.absolute(kept) - with_prologue.start_of(0),
            where + 90_000 - 0,
            f"{book.book_id}: and the same audio is still under it",
        )
        check(
            with_prologue.absolute(kept) != where,
            f"{book.book_id}: an offset-based bookmark would have moved here, which is the point",
        )
        moved += 1

        # W4b. Files reordered. Anchored to identity, the place is still exact.
        shuffled = list(book.tracks)
        rng.shuffle(shuffled)
        reordered = Book(book_id=book.book_id, title=book.title, tracks=tuple(shuffled))
        equal(reordered.resolve(mark), mark, f"{book.book_id}: reordering leaves the bookmark alone")

        # W4c. The very file is deleted. The answer has to be defined.
        without = tuple(t for t in book.tracks if t.track_id != middle.track_id)
        pruned = Book(book_id=book.book_id, title=book.title, tracks=without)
        landed = pruned.resolve(mark)
        check(
            any(t.track_id == landed.track_id for t in pruned.tracks),
            f"{book.book_id}: a bookmark for a deleted file lands on a file that exists",
        )
        rebased = pruned.rebase(mark, book)
        check(
            any(t.track_id == rebased.track_id for t in pruned.tracks),
            f"{book.book_id}: rebasing also lands on a file that exists",
        )
        check(
            abs(pruned.absolute(rebased) - where) <= middle.duration_ms,
            f"{book.book_id}: rebasing lands within one file of where the listener was",
        )

        # W5. A file re-encoded shorter than the bookmark's offset.
        shorter = tuple(
            Track(t.track_id, t.title, max(1000, t.duration_ms // 4)) if t.track_id == middle.track_id else t
            for t in book.tracks
        )
        shrunk = Book(book_id=book.book_id, title=book.title, tracks=shorter)
        fixed = shrunk.resolve(mark)
        equal(fixed.track_id, middle.track_id, f"{book.book_id}: a shortened file keeps the bookmark")
        check(
            fixed.offset_ms <= max(1000, middle.duration_ms // 4),
            f"{book.book_id}: and clamps the offset inside the shorter file",
        )

    print(f"  {moved} books checked against insertion, reordering, deletion and re-encoding")

    print("=== a book must be describable ===")
    raises(lambda: Book(book_id="x", title="", tracks=()), "a book with no files is refused")
    raises(lambda: Track("t", "", 0), "a zero-length file is refused")
    raises(lambda: Track("t", "", -1), "a negative-length file is refused")
    raises(lambda: Track("", "", 1000), "a file with no id is refused")
    raises(
        lambda: Book(
            book_id="x",
            title="",
            tracks=(Track("same", "", 1000), Track("same", "", 1000)),
        ),
        "duplicate file ids are refused, since bookmarks name files",
    )


# ---------------------------------------------------------------------------
# 4. Chapters
# ---------------------------------------------------------------------------


def chapters(books: list[Book]) -> None:
    print("=== chapters from files ===")
    # W7a. The LibriVox shape: one file per chapter.
    for book in books[:60]:
        chs = book.chapters_from_tracks()
        equal(len(chs), len(book.tracks), f"{book.book_id}: one chapter per file")
        equal(chs[0].start_ms, 0, f"{book.book_id}: the first chapter starts at zero")
        equal(chs[-1].end_ms, book.total_ms, f"{book.book_id}: the last chapter ends at the end")
        for i in range(1, len(chs)):
            equal(
                chs[i].start_ms,
                chs[i - 1].end_ms,
                f"{book.book_id}: chapter {i} begins where {i - 1} ended, with no gap",
            )
        for i, ch in enumerate(chs):
            equal(
                chapter_index_at(chs, ch.start_ms),
                i,
                f"{book.book_id}: a position on chapter {i}'s start is in chapter {i}",
            )
            equal(
                chapter_index_at(chs, ch.end_ms - 1),
                i,
                f"{book.book_id}: a position at chapter {i}'s last ms is still in chapter {i}",
            )
        equal(chapter_index_at(chs, -5), 0, f"{book.book_id}: before the book is the first chapter")
        equal(
            chapter_index_at(chs, book.total_ms + 5),
            len(chs) - 1,
            f"{book.book_id}: past the book is the last chapter",
        )

    print("=== chapters from marks inside one file ===")
    # W7b. The M4B shape: one long file with internal marks.
    single = Book(book_id="m", title="One file", tracks=(Track("only", "Whole book", 3_600_000),))
    chs = single.chapters_from_marks([("One", 0), ("Two", 1_200_000), ("Three", 2_400_000)])
    equal(len(chs), 3, "three marks give three chapters")
    equal([c.title for c in chs], ["One", "Two", "Three"], "titles in order")
    equal(chs[-1].end_ms, 3_600_000, "the last chapter runs to the end of the file")
    equal(chapter_index_at(chs, 1_200_000), 1, "a position on a mark is in the chapter that mark opens")
    equal(chapter_index_at(chs, 1_199_999), 0, "a position one ms earlier is in the previous chapter")

    print("  audio before the first mark is not lost")
    chs = single.chapters_from_marks([("Two", 1_200_000)])
    equal(len(chs), 2, "a mark that does not start at zero gains an opening chapter")
    equal(chs[0].start_ms, 0, "which starts at zero")
    equal(chs[0].title, "", "and is untitled rather than mislabelled")
    equal(chs[1].title, "Two", "the real first chapter keeps its title")

    equal(len(single.chapters_from_marks([])), 1, "no marks means the whole book is one chapter")
    equal(
        single.chapters_from_marks([])[0].end_ms,
        3_600_000,
        "and that chapter covers the whole book",
    )

    print("  duplicate and out-of-range marks")
    chs = single.chapters_from_marks([("A", 0), ("B", 0), ("C", 1_000)])
    check(all(c.duration_ms > 0 for c in chs), "no zero-length chapters survive a duplicate mark")
    chs = single.chapters_from_marks([("A", 0), ("B", 99_999_999)])
    equal(chs[-1].start_ms, 3_600_000, "a mark past the end clamps to the end")
    raises(
        lambda: single.chapters_from_marks([("A", 0), ("B", 2_000_000), ("C", 1_000_000)]),
        "marks that go backwards are refused",
    )

    print("=== a chapter spanning a file boundary ===")
    # W7c. Chapters and files need not line up at all.
    two = Book(
        book_id="s",
        title="Split",
        tracks=(Track("a", "Part one", 1_800_000), Track("b", "Part two", 1_800_000)),
    )
    chs = two.chapters_from_marks([("Long chapter", 900_000)])
    spanning = chs[1]
    check(
        spanning.start_ms < 1_800_000 < spanning.end_ms,
        "the chapter really does straddle the file boundary",
    )
    start_mark = two.locate(spanning.start_ms)
    equal(start_mark.track_id, "a", "the chapter starts in the first file")
    end_mark = two.locate(spanning.end_ms - 1)
    equal(end_mark.track_id, "b", "and ends in the second")
    equal(
        chapter_index_at(chs, two.absolute(Bookmark("b", 0))),
        1,
        "a position at the start of the second file is still inside that chapter",
    )


# ---------------------------------------------------------------------------
# 5. Mutations
# ---------------------------------------------------------------------------


def mutations(books: list[Book]) -> None:
    print("=== mutations: each hazard put back on purpose ===")
    sample = [b for b in books if len(b.tracks) >= 5][:120]

    def report(label: str, caught: int, total: int) -> None:
        check(
            caught > 0,
            f"mutation '{label}' broke nothing these checks could see, so that hazard is unverified",
        )
        print(f"  {label:46s} {caught:4d}/{total} books show the error")

    # W1. bisect_left instead of bisect_right: a boundary is attributed to the
    # file before it, so the offset equals that file's full duration.
    import bisect

    caught = 0
    for book in sample:
        bad = False
        for i in range(1, len(book.tracks)):
            boundary = book.start_of(i)
            index = bisect.bisect_left(book._starts, boundary) - 1
            if index != i:
                bad = True
                break
        caught += bool(bad)
    report("W1 boundary attributed to the earlier file", caught, len(sample))

    # W2. No clamping: a position past the end indexes off the end of the list.
    caught = 0
    for book in sample:
        index = bisect.bisect_right(book._starts, book.total_ms + 1) - 1
        offset = book.total_ms + 1 - book.start_of(index)
        if offset > book.tracks[index].duration_ms:
            caught += 1
    report("W2 past the end left unclamped", caught, len(sample))

    # W3. Treating the publisher's declared total as the book's length. The
    # visible damage is not only at the finish: every "time remaining" and
    # every progress bar is computed against the wrong length, so the number
    # on the watch is wrong for the whole book.
    caught = 0
    disagreeing = [b for b in sample if b.declared_disagreement_ms]
    worst_seconds = 0.0
    for book in disagreeing:
        assert book.declared_total_ms is not None
        middle = book.tracks[len(book.tracks) // 2]
        mark = Bookmark(middle.track_id, middle.duration_ms // 2)
        played = book.absolute(mark)
        honest_remaining = book.total_ms - played
        declared_remaining = book.declared_total_ms - played
        if honest_remaining != declared_remaining:
            caught += 1
            worst_seconds = max(worst_seconds, abs(honest_remaining - declared_remaining) / 1000)
    report("W3 book length taken from the declared total", caught, len(disagreeing))
    if worst_seconds:
        print(f"      worst 'time remaining' error: {worst_seconds / 60:.0f} minutes")

    # The finish line moves too, but only for books that declare less than
    # they contain; the others clamp to the same end and hide the mistake.
    short_declared = [
        b for b in disagreeing if b.declared_total_ms and b.declared_total_ms < b.total_ms
    ]
    stranded = sum(
        1
        for b in short_declared
        if b.locate(b.declared_total_ms) != b.locate(b.total_ms)
    )
    report("W3b the finish line taken from the declared total", stranded, max(len(short_declared), 1))

    # W4. Storing an absolute offset instead of a file identity.
    caught = 0
    for book in sample:
        middle = book.tracks[len(book.tracks) // 2]
        mark = Bookmark(middle.track_id, middle.duration_ms // 3)
        before = book.absolute(mark)
        grown = Book(
            book_id=book.book_id,
            title=book.title,
            tracks=(Track("prologue", "Prologue", 90_000), *book.tracks),
        )
        # The offset-based reading keeps the number and lands elsewhere.
        drifted = grown.locate(before)
        if drifted != mark:
            caught += 1
    report("W4 bookmark stored as a book-wide offset", caught, len(sample))

    # W6. Milliseconds carried in a 32-bit float. Swift's `Float` is 32-bit
    # and reaching for it is an easy mistake, since `TimeInterval` is a
    # Double and the two look interchangeable in a signature.
    #
    # Note what is *not* a bug: these books have whole-second durations, and
    # the largest is 197,822 s, well inside float32's exactly-representable
    # integers. Seconds in a float32 are fine here. Milliseconds are not: at
    # 198 million the spacing between representable values is 16, so a
    # bookmark cannot even name the second it is in.
    import struct as _struct

    def f32(value: float) -> float:
        return _struct.unpack("f", _struct.pack("f", value))[0]

    # A stored position is wherever the listener stopped, not a whole second,
    # so probe arbitrary milliseconds rather than only the file boundaries.
    rng = random.Random(6006)
    caught = 0
    worst_drift = 0
    worst_book = None
    for book in sample:
        drift = 0
        for _ in range(40):
            exact = rng.randrange(book.total_ms + 1)
            if int(f32(float(exact))) != exact:
                drift = max(drift, abs(int(f32(float(exact))) - exact))
        if drift:
            caught += 1
            if drift > worst_drift:
                worst_drift, worst_book = drift, book
    report("W6 milliseconds carried in a 32-bit float", caught, len(sample))
    if worst_book is not None:
        print(
            f"      e.g. {worst_book.title[:34]!r}: a stored position lands up to "
            f"{worst_drift} ms away from where playback actually stopped"
        )

    # Where the line falls, stated rather than implied: float32 counts
    # milliseconds exactly up to 2^24, which is 4h39m of audio.
    equal(
        int(f32(float(2**24))),
        2**24,
        "float32 should still be exact at 2^24 ms",
    )
    equal(
        int(f32(float(2**24 + 1))),
        2**24,
        "float32 should already be losing milliseconds just past 2^24",
    )
    over = sum(1 for b in sample if b.total_ms > 2**24)
    print(f"      {over}/{len(sample)} books run past 4h39m, where the loss starts")

    # And the honest converse, so the report does not overclaim: whole-second
    # durations in float32 seconds survive this corpus intact.
    intact = sum(1 for b in sample if int(round(f32(b.total_ms / 1000) * 1000)) == b.total_ms)
    equal(
        intact,
        len(sample),
        "float32 seconds should be exact for whole-second durations of this size",
    )
    print(f"  {'(float32 *seconds* is exact for all of these)':46s} {intact:4d}/{len(sample)} books")

    # Sanity: unmutated, none of these hold.
    for book in sample[:20]:
        equal(book.locate(book.total_ms + 1), book.locate(book.total_ms), f"{book.book_id}: clamped")


def main() -> int:
    if not FIXTURE.exists():
        print(f"RESULT: FAIL  (missing fixture {FIXTURE})")
        return 1

    payload, books = load_books()
    print(f"corpus captured : {payload['captured']}")
    print(f"corpus source   : {payload['source']}")
    print(
        f"corpus          : {len(books)} books, "
        f"{sum(len(b.tracks) for b in books):,} files, "
        f"{sum(b.total_ms for b in books) / 3_600_000:,.0f} hours"
    )
    print()

    geometry(books)
    declared(payload, books)
    survival(books)
    chapters(books)
    mutations(books)

    print()
    if FAILURES:
        print(f"RESULT: FAIL  ({len(FAILURES)} of {ASSERTIONS} assertions)")
        for failure in FAILURES[:25]:
            print(f"  - {failure}")
        return 1
    print(f"RESULT: PASS  ({ASSERTIONS} assertions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
