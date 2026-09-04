#!/usr/bin/env python3
"""
Executable check of VolumenCore's ID3v2 chapter reader.

The Swift in this repo cannot be compiled on the machine it was written on, so
the logic is ported to `id3_chapters.py` and checked against an independent
implementation in both directions:

  * bytes written here are read by mutagen
  * bytes written by mutagen are read here

Two parsers written from the same specification by different people agreeing
on the same bytes is the closest this format comes to published test vectors.
The chapter addendum ships no vector file of its own, so the alternative would
be checking my reader against my writer, which proves only that I am
consistent with myself.

Sections:

  1. integers    syncsafe and plain, and the boundary where they diverge
  2. text        the four encoding markers, including the truncation trap
  3. round trip  through mutagen, both directions
  4. mutations   each hazard reintroduced, to prove mutagen notices

  python validation/verify_id3.py
"""

from __future__ import annotations

import pathlib
import struct
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from id3_chapters import (  # noqa: E402
    NOT_SET,
    ID3Error,
    build_chap,
    build_tag,
    de_unsynchronise,
    decode_text,
    encode_text,
    int_to_syncsafe,
    ordered_chapters,
    parse_tag,
    plain_to_int,
    syncsafe_to_int,
    unsynchronise,
)

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
    except ID3Error:
        return check(True, message)
    except Exception as exc:  # noqa: BLE001
        return check(False, f"{message}: raised {type(exc).__name__} instead of ID3Error")
    return check(False, f"{message}: did not raise")


# ---------------------------------------------------------------------------
# 1. Integers
# ---------------------------------------------------------------------------


def integers() -> None:
    print("=== syncsafe and plain integers ===")
    equal(syncsafe_to_int(b"\x00\x00\x00\x00"), 0, "syncsafe zero")
    equal(syncsafe_to_int(b"\x00\x00\x00\x7f"), 127, "syncsafe 127 fits one byte")
    equal(syncsafe_to_int(b"\x00\x00\x01\x00"), 128, "syncsafe 128 rolls into the next byte")
    equal(syncsafe_to_int(b"\x00\x00\x02\x01"), 257, "syncsafe 257")
    equal(syncsafe_to_int(b"\x7f\x7f\x7f\x7f"), (1 << 28) - 1, "syncsafe maximum")
    raises(lambda: syncsafe_to_int(b"\x80\x00\x00\x00"), "high bit set is rejected")
    raises(lambda: syncsafe_to_int(b"\x00\x00\x00"), "three bytes are rejected")

    for value in (0, 1, 127, 128, 129, 255, 256, 16383, 16384, (1 << 28) - 1):
        equal(syncsafe_to_int(int_to_syncsafe(value)), value, f"syncsafe round trip {value}")
    raises(lambda: int_to_syncsafe(1 << 28), "a value too large for syncsafe is rejected")
    raises(lambda: int_to_syncsafe(-1), "a negative syncsafe value is rejected")

    equal(plain_to_int(b"\x00\x00\x00\x80"), 128, "plain 128")
    equal(plain_to_int(b"\xff\xff\xff\xff"), 0xFFFFFFFF, "plain maximum")

    # T1. Below 128 the two readings agree, which is exactly why a wrong
    # implementation passes a casual test and then mangles a real tag.
    print("  where the two encodings agree and where they part")
    agree = disagree = 0
    for value in range(0, 4096):
        raw = int_to_syncsafe(value)
        if plain_to_int(raw) == value:
            agree += 1
        else:
            disagree += 1
    equal(agree, 128, "the two size encodings agree only below 128")
    check(disagree == 4096 - 128, "and disagree everywhere above it")
    print(f"    of the first 4096 sizes, {agree} read the same either way, {disagree} do not")


# ---------------------------------------------------------------------------
# 2. Text
# ---------------------------------------------------------------------------


def text() -> None:
    print("=== text encodings ===")
    equal(decode_text(b"\x00Chapter 1\x00"), "Chapter 1", "Latin-1 marker")
    equal(decode_text(b"\x03Chapter 1\x00"), "Chapter 1", "UTF-8 marker")
    equal(
        decode_text(b"\x01" + "Chapter 1".encode("utf-16") + b"\x00\x00"),
        "Chapter 1",
        "UTF-16 with BOM",
    )
    equal(
        decode_text(b"\x02" + "Chapter 1".encode("utf-16-be") + b"\x00\x00"),
        "Chapter 1",
        "UTF-16BE without BOM",
    )

    # T3. The trap, spelled out: for ASCII text in UTF-16 every second byte is
    # a null, so single-null termination keeps one letter.
    utf16 = b"\x01" + "Chapter 1".encode("utf-16") + b"\x00\x00"
    naive = utf16[1:].split(b"\x00", 1)[0].decode("latin-1", "replace")
    check(
        naive != "Chapter 1",
        f"the naive Latin-1 reading of a UTF-16 title should not produce the title, got {naive!r}",
    )
    check(
        "hapter" not in naive,
        f"the naive reading should lose the word, got {naive!r}",
    )
    # The byte order mark leads, then the first letter, then the null that
    # follows it in UTF-16 ends the string. Nine characters become three.
    print(f"    UTF-16 'Chapter 1' read as Latin-1 gives {naive!r} ({len(naive)} chars, not 9)")

    # T4. Byte order actually matters.
    be = decode_text(b"\x02" + "AB".encode("utf-16-be") + b"\x00\x00")
    le_bytes = b"\x02" + "AB".encode("utf-16-le") + b"\x00\x00"
    equal(be, "AB", "UTF-16BE reads in order")
    check(decode_text(le_bytes) != "AB", "little-endian bytes read as big-endian do not match")

    for marker in (0x00, 0x01, 0x02, 0x03):
        for value in ("Chapter 1", "Kapittel 12", "Introduction"):
            equal(decode_text(encode_text(value, marker)), value, f"round trip marker {marker} {value!r}")

    # Non-ASCII survives the encodings that can carry it.
    for marker in (0x01, 0x02, 0x03):
        for value in ("Løkenåsveien", "第一章", "Éirinn"):
            equal(decode_text(encode_text(value, marker)), value, f"round trip marker {marker} {value!r}")

    equal(decode_text(b""), "", "an empty payload is an empty title")
    equal(decode_text(b"\x03\x00"), "", "an immediately terminated payload is empty")
    equal(decode_text(b"Chapter 1\x00"), "Chapter 1", "a missing encoding byte falls back to Latin-1")

    print("=== unsynchronisation ===")
    for payload in (b"\xff\x00\xfe", b"\xff\xff\xff", b"ordinary", b"\xff", b"\xff\xfb\x90"):
        equal(de_unsynchronise(unsynchronise(payload)), payload, f"unsync round trip {payload!r}")


# ---------------------------------------------------------------------------
# 3. Round trip against mutagen
# ---------------------------------------------------------------------------

SILENT_MP3 = bytes.fromhex("fffb90c4") + b"\x00" * 400


def with_mutagen() -> bool:
    try:
        import mutagen  # noqa: F401
    except ImportError:
        print("=== mutagen not installed: cross-parser checks skipped ===")
        FAILURES.append("mutagen is not installed, so no independent parser checked these bytes")
        global ASSERTIONS
        ASSERTIONS += 1
        return False
    return True


def cross_check() -> None:
    from mutagen.id3 import CHAP, CTOC, ID3, TIT2, CTOCFlags

    print("=== bytes written here, read by mutagen ===")
    cases = [
        ("Chapter 1", 0, 60_000),
        ("Kapittel 2 - Løkenåsveien", 60_000, 3_600_000),
        ("第三章", 3_600_000, 7_200_500),
        ("A" * 200, 7_200_500, 9_000_000),  # forces a frame past 128 bytes
    ]

    for major in (3, 4):
        for marker in (0x00, 0x01, 0x03):
            frames = []
            expected = []
            for i, (title, start, end) in enumerate(cases, start=1):
                if marker == 0x00 and not title.isascii():
                    continue  # Latin-1 cannot carry these, and the spec agrees
                element = f"ch{i}"
                frames.append(
                    ("CHAP", build_chap(element, start, end, title, major=major, text_marker=marker))
                )
                expected.append((element, start, end, title))
            blob = build_tag(frames, major=major, padding=64)

            mine = parse_tag(blob)
            equal(mine.version[0], major, f"v2.{major} marker {marker}: version read back")
            equal(
                [(c.element_id, c.start_ms, c.end_ms, c.title) for c in mine.chapters],
                expected,
                f"v2.{major} marker {marker}: own reader agrees with what was written",
            )

            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp) / "a.mp3"
                path.write_bytes(blob + SILENT_MP3)
                tags = ID3(path)
                got = []
                for key in sorted(tags.keys()):
                    if not key.startswith("CHAP:"):
                        continue
                    frame = tags[key]
                    sub = frame.sub_frames.get("TIT2")
                    got.append(
                        (
                            frame.element_id,
                            int(frame.start_time),
                            int(frame.end_time),
                            str(sub.text[0]) if sub else "",
                        )
                    )
                equal(
                    sorted(got),
                    sorted(expected),
                    f"v2.{major} marker {marker}: mutagen agrees with what was written",
                )

    print("=== bytes written by mutagen, read here ===")
    for marker, encoding in ((0x00, 0), (0x01, 1), (0x03, 3)):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "b.mp3"
            path.write_bytes(SILENT_MP3)
            tags = ID3()
            written = []
            for i, (title, start, end) in enumerate(cases, start=1):
                if encoding == 0 and not title.isascii():
                    continue
                element = f"m{i}"
                tags.add(
                    CHAP(
                        element_id=element,
                        start_time=start,
                        end_time=end,
                        sub_frames=[TIT2(encoding=encoding, text=[title])],
                    )
                )
                written.append((element, start, end, title))
            tags.add(
                CTOC(
                    element_id="toc",
                    flags=CTOCFlags.TOP_LEVEL | CTOCFlags.ORDERED,
                    child_element_ids=[w[0] for w in written],
                    sub_frames=[TIT2(encoding=encoding, text=["Book"])],
                )
            )
            tags.save(path, v2_version=4)

            mine = parse_tag(path.read_bytes())
            equal(
                sorted((c.element_id, c.start_ms, c.end_ms, c.title) for c in mine.chapters),
                sorted(written),
                f"encoding {encoding}: this reader agrees with mutagen's bytes",
            )
            equal(len(mine.toc), 1, f"encoding {encoding}: the table of contents is found")
            if mine.toc:
                equal(mine.toc[0].element_id, "toc", f"encoding {encoding}: toc element id")
                check(mine.toc[0].top_level, f"encoding {encoding}: toc is marked top level")
                check(mine.toc[0].ordered, f"encoding {encoding}: toc is marked ordered")
                equal(
                    list(mine.toc[0].children),
                    [w[0] for w in written],
                    f"encoding {encoding}: toc lists its children in order",
                )
                equal(
                    [c.element_id for c in ordered_chapters(mine)],
                    [w[0] for w in written],
                    f"encoding {encoding}: playing order follows the ordered toc",
                )

    print("=== offsets that mean 'not set' ===")
    # T6.
    blob = build_tag([("CHAP", build_chap("x", 0, 1000, "T", major=4))], major=4)
    tag = parse_tag(blob)
    equal(tag.chapters[0].start_offset, None, "0xFFFFFFFF start offset reads as absent")
    equal(tag.chapters[0].end_offset, None, "0xFFFFFFFF end offset reads as absent")
    blob = build_tag(
        [("CHAP", build_chap("y", 0, 1000, "T", start_offset=1234, end_offset=5678, major=4))],
        major=4,
    )
    tag = parse_tag(blob)
    equal(tag.chapters[0].start_offset, 1234, "a real start offset is kept")
    equal(tag.chapters[0].end_offset, 5678, "a real end offset is kept")


# ---------------------------------------------------------------------------
# 4. Mutations
# ---------------------------------------------------------------------------


def mutations() -> None:
    print("=== mutations: each hazard put back on purpose ===")

    long_title = "A" * 200  # any frame past 128 bytes separates the two rules

    # T1. A v2.3 tag read with v2.4 rules and the other way round.
    for written, read_as in ((3, 4), (4, 3)):
        blob = build_tag(
            [("CHAP", build_chap("ch1", 0, 60_000, long_title, major=written))],
            major=written,
        )
        # Rewrite only the version byte, so the bytes are a genuine v2.N tag
        # misidentified as v2.M -- exactly what happens when a writer lies.
        mutated = blob[:3] + bytes([read_as]) + blob[4:]
        wrong = None
        try:
            wrong = parse_tag(mutated)
        except ID3Error:
            pass
        if wrong is None:
            print(f"  v2.{written} bytes read as v2.{read_as}: rejected outright")
            check(True, f"v2.{written} read as v2.{read_as} is caught")
        else:
            titles = [c.title for c in wrong.chapters]
            check(
                titles != [long_title],
                f"v2.{written} bytes read as v2.{read_as} produced the right title anyway, "
                "so the size encoding is not actually being used",
            )
            print(f"  v2.{written} bytes read as v2.{read_as}: chapters came out as {titles!r:.60}")

    # T3. Latin-1 termination applied to a UTF-16 title.
    def naive_decode(payload: bytes) -> str:
        return payload[1:].split(b"\x00", 1)[0].decode("latin-1", "replace")

    utf16_payload = encode_text("Chapter 1", 0x01)
    equal(decode_text(utf16_payload), "Chapter 1", "the real decoder handles UTF-16")
    check(
        naive_decode(utf16_payload) != "Chapter 1",
        "the naive decoder should have mangled UTF-16 but did not",
    )

    # T5. Unsynchronised body left as-is.
    body = build_tag([("CHAP", build_chap("ch1", 0xFF00FF, 0xFFFFFF, "T", major=4))], major=4)
    inner = body[10:]
    unsynced = unsynchronise(inner)
    tag = b"ID3" + bytes([4, 0, 0x80]) + int_to_syncsafe(len(unsynced)) + unsynced
    fixed = parse_tag(tag)
    equal(fixed.chapters[0].start_ms, 0xFF00FF, "an unsynchronised tag is de-unsynchronised")
    not_flagged = b"ID3" + bytes([4, 0, 0x00]) + int_to_syncsafe(len(unsynced)) + unsynced
    broken = None
    try:
        broken = parse_tag(not_flagged)
    except ID3Error:
        pass
    if broken is None:
        check(True, "ignoring the unsynchronisation flag is caught by a size mismatch")
        print("  unsynchronised body without the flag: rejected outright")
    else:
        check(
            not broken.chapters or broken.chapters[0].start_ms != 0xFF00FF,
            "ignoring the unsynchronisation flag still produced the right time",
        )
        print("  unsynchronised body without the flag: times came out wrong, as expected")

    # T6. 0xFFFFFFFF taken literally is a four-billion-byte seek.
    equal(NOT_SET, 0xFFFFFFFF, "the sentinel is the one the addendum specifies")
    check(NOT_SET > 4_000_000_000, "and it is far past any real file offset")

    print("=== malformed tags are refused, not guessed ===")
    raises(lambda: parse_tag(b"not an id3 tag at all"), "a non-tag is refused")
    raises(lambda: parse_tag(b"ID3" + bytes([9, 0, 0]) + int_to_syncsafe(0)), "an unknown version is refused")
    raises(
        lambda: parse_tag(b"ID3" + bytes([4, 0, 0]) + int_to_syncsafe(100) + b"\x00" * 10),
        "a tag shorter than it claims is refused",
    )
    # A CHAP frame cut off before its four times.
    short = struct.pack(">I", 4)
    raises(
        lambda: parse_tag(build_tag([("CHAP", b"ch\x00" + short)], major=4)),
        "a truncated CHAP frame is refused",
    )


def main() -> int:
    integers()
    text()
    if with_mutagen():
        cross_check()
    mutations()

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
