"""Reference implementation of Volumen's ID3v2 chapter reader, in Python.

Mirrors `Sources/VolumenCore/ID3Chapters.swift`. Written from:

  * ID3v2.3.0 informal standard, sections 3.1 (tag header) and 3.3 (frames)
  * ID3v2.4.0 structure, section 4 (frames), which changed how frame sizes
    are encoded
  * ID3v2 Chapter Frame Addendum 1.0, which defines CHAP and CTOC

`verify_id3.py` checks this against mutagen in both directions: bytes written
here are read by mutagen, and bytes written by mutagen are read here. Two
independent parsers agreeing on the same bytes is the closest thing to a test
vector this format offers.

The hazards, none of which raises:

  T1  Frame sizes are plain 32-bit big-endian in ID3v2.3 and syncsafe (seven
      bits per byte) in ID3v2.4. Use the wrong rule and every frame at or
      past 128 bytes lands at the wrong offset; short tags read fine, which
      is why this survives casual testing.
  T2  The tag header size is always syncsafe, in both versions.
  T3  A text frame's first byte selects the encoding. Reading UTF-16 as
      Latin-1 stops at the first null, and for ASCII text in UTF-16 that is
      the second byte: "Chapter 1" becomes "C".
  T4  UTF-16 carries a byte order mark; UTF-16BE does not. Guessing wrong
      swaps every character.
  T5  Unsynchronisation rewrites $FF 00 as $FF. Not undoing it leaves stray
      nulls inside titles and shifts every subsequent field.
  T6  CHAP times are milliseconds in 32-bit big-endian, and $FFFFFFFF means
      "not set" for the byte offsets. Treating that as a real offset yields a
      four-billion-byte seek.
  T7  A CHAP frame contains its own subframes. Their sizes follow the same
      version rule as the outer frame, not a fresh guess.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass


class ID3Error(Exception):
    """The tag is not shaped the way the specification says."""


NOT_SET = 0xFFFFFFFF


@dataclass(frozen=True)
class ChapterFrame:
    element_id: str
    start_ms: int
    end_ms: int
    start_offset: int | None
    end_offset: int | None
    title: str


@dataclass(frozen=True)
class TableOfContents:
    element_id: str
    top_level: bool
    ordered: bool
    children: tuple[str, ...]
    title: str


@dataclass(frozen=True)
class Tag:
    version: tuple[int, int]
    chapters: tuple[ChapterFrame, ...]
    toc: tuple[TableOfContents, ...]
    title: str


# --------------------------------------------------------------------------
# Integers
# --------------------------------------------------------------------------


def syncsafe_to_int(data: bytes) -> int:
    """Seven bits per byte, high bit always clear. T2."""
    if len(data) != 4:
        raise ID3Error(f"syncsafe integers are four bytes, got {len(data)}")
    value = 0
    for byte in data:
        if byte & 0x80:
            raise ID3Error("syncsafe byte has its high bit set")
        value = (value << 7) | byte
    return value


def int_to_syncsafe(value: int) -> bytes:
    if value < 0 or value >= 1 << 28:
        raise ID3Error(f"{value} does not fit a syncsafe integer")
    return bytes((value >> shift) & 0x7F for shift in (21, 14, 7, 0))


def plain_to_int(data: bytes) -> int:
    if len(data) != 4:
        raise ID3Error(f"plain integers are four bytes, got {len(data)}")
    return struct.unpack(">I", data)[0]


def unsynchronise(data: bytes) -> bytes:
    """Insert $00 after every $FF that would otherwise look like a frame sync."""
    out = bytearray()
    for byte in data:
        out.append(byte)
        if byte == 0xFF:
            out.append(0x00)
    return bytes(out)


def de_unsynchronise(data: bytes) -> bytes:
    """Undo it. T5."""
    out = bytearray()
    skip = False
    for i, byte in enumerate(data):
        if skip:
            skip = False
            continue
        out.append(byte)
        if byte == 0xFF and i + 1 < len(data) and data[i + 1] == 0x00:
            skip = True
    return bytes(out)


# --------------------------------------------------------------------------
# Text
# --------------------------------------------------------------------------

_ENCODINGS = {
    0x00: ("latin-1", b"\x00"),
    0x01: ("utf-16", b"\x00\x00"),
    0x02: ("utf-16-be", b"\x00\x00"),
    0x03: ("utf-8", b"\x00"),
}


def decode_text(payload: bytes) -> str:
    """Decode an ID3 text frame body: one encoding byte, then the string.

    T3 and T4. The encoding byte is not advisory. Latin-1 is the only one of
    the four whose terminator is a single null, so a parser that assumes
    single-null termination truncates every UTF-16 title to its first letter.
    """
    if not payload:
        return ""
    marker = payload[0]
    if marker not in _ENCODINGS:
        # Some writers omit the encoding byte entirely. Treating a printable
        # first byte as Latin-1 text recovers those without corrupting valid
        # frames, since 0x00-0x03 are not printable.
        return payload.split(b"\x00", 1)[0].decode("latin-1", "replace")
    name, terminator = _ENCODINGS[marker]
    body = payload[1:]
    if len(terminator) == 2:
        # Trim to an even length before looking for a two-byte terminator,
        # otherwise a trailing stray byte shifts the search by one.
        if len(body) % 2:
            body = body[:-1]
        for i in range(0, len(body) - 1, 2):
            if body[i : i + 2] == terminator:
                body = body[:i]
                break
    else:
        index = body.find(terminator)
        if index >= 0:
            body = body[:index]
    return body.decode(name, "replace")


def encode_text(text: str, marker: int = 0x03) -> bytes:
    name, terminator = _ENCODINGS[marker]
    return bytes([marker]) + text.encode(name) + terminator


def read_latin1_terminated(data: bytes, start: int) -> tuple[str, int]:
    """Element ids are Latin-1 and null terminated, whatever the text frames use."""
    end = data.find(b"\x00", start)
    if end < 0:
        raise ID3Error("unterminated element id")
    return data[start:end].decode("latin-1", "replace"), end + 1


# --------------------------------------------------------------------------
# Frames
# --------------------------------------------------------------------------


def _frame_size(raw: bytes, major: int) -> int:
    """T1. The one difference between v2.3 and v2.4 that silently corrupts."""
    if major >= 4:
        return syncsafe_to_int(raw)
    return plain_to_int(raw)


def _walk_frames(body: bytes, major: int):
    """Yield (frame_id, payload) in order, stopping at padding."""
    pos = 0
    header = 6 if major == 2 else 10
    while pos + header <= len(body):
        if major == 2:
            frame_id = body[pos : pos + 3].decode("latin-1", "replace")
            if frame_id == "\x00\x00\x00":
                return
            size = int.from_bytes(body[pos + 3 : pos + 6], "big")
            payload_at = pos + 6
        else:
            frame_id = body[pos : pos + 4].decode("latin-1", "replace")
            if frame_id[:1] == "\x00":
                return  # padding
            size = _frame_size(body[pos + 4 : pos + 8], major)
            payload_at = pos + 10
        if size < 0 or payload_at + size > len(body):
            raise ID3Error(
                f"frame {frame_id!r} claims {size} bytes but only "
                f"{len(body) - payload_at} remain; wrong size encoding for v2.{major}?"
            )
        yield frame_id, body[payload_at : payload_at + size]
        pos = payload_at + size


def _parse_chap(payload: bytes, major: int) -> ChapterFrame:
    element_id, pos = read_latin1_terminated(payload, 0)
    if pos + 16 > len(payload):
        raise ID3Error(f"CHAP {element_id!r} is too short for its four times")
    start_ms, end_ms, start_off, end_off = struct.unpack(">IIII", payload[pos : pos + 16])
    pos += 16
    title = ""
    # T7. Subframes use the same size rule as the frame that contains them.
    for frame_id, sub in _walk_frames(payload[pos:], major):
        if frame_id in ("TIT2", "TT2") and not title:
            title = decode_text(sub)
    return ChapterFrame(
        element_id=element_id,
        start_ms=start_ms,
        end_ms=end_ms,
        # T6.
        start_offset=None if start_off == NOT_SET else start_off,
        end_offset=None if end_off == NOT_SET else end_off,
        title=title,
    )


def _parse_ctoc(payload: bytes, major: int) -> TableOfContents:
    element_id, pos = read_latin1_terminated(payload, 0)
    if pos + 2 > len(payload):
        raise ID3Error(f"CTOC {element_id!r} is too short for flags and count")
    flags, count = payload[pos], payload[pos + 1]
    pos += 2
    children: list[str] = []
    for _ in range(count):
        child, pos = read_latin1_terminated(payload, pos)
        children.append(child)
    title = ""
    for frame_id, sub in _walk_frames(payload[pos:], major):
        if frame_id in ("TIT2", "TT2") and not title:
            title = decode_text(sub)
    return TableOfContents(
        element_id=element_id,
        top_level=bool(flags & 0x02),
        ordered=bool(flags & 0x01),
        children=tuple(children),
        title=title,
    )


def parse_tag(data: bytes) -> Tag:
    """Read an ID3v2 tag from the start of a file."""
    if len(data) < 10 or data[:3] != b"ID3":
        raise ID3Error("no ID3v2 tag at the start of the data")
    major, revision = data[3], data[4]
    if major not in (2, 3, 4):
        raise ID3Error(f"unsupported ID3v2 major version {major}")
    flags = data[5]
    size = syncsafe_to_int(data[6:10])  # T2: always syncsafe
    body = data[10 : 10 + size]
    if len(body) < size:
        raise ID3Error(f"tag claims {size} bytes, only {len(body)} present")

    if flags & 0x80:  # unsynchronisation, whole tag, v2.3 and earlier
        body = de_unsynchronise(body)
    if flags & 0x40:  # extended header
        if major >= 4:
            ext = syncsafe_to_int(body[:4])
            body = body[ext:]
        else:
            ext = plain_to_int(body[:4])
            body = body[4 + ext :]

    chapters: list[ChapterFrame] = []
    toc: list[TableOfContents] = []
    title = ""
    for frame_id, payload in _walk_frames(body, major):
        if frame_id == "CHAP":
            chapters.append(_parse_chap(payload, major))
        elif frame_id == "CTOC":
            toc.append(_parse_ctoc(payload, major))
        elif frame_id in ("TIT2", "TT2") and not title:
            title = decode_text(payload)
    return Tag(version=(major, revision), chapters=tuple(chapters), toc=tuple(toc), title=title)


def ordered_chapters(tag: Tag) -> list[ChapterFrame]:
    """Chapters in playing order.

    An ordered top-level CTOC states the order; without one, the order CHAP
    frames appear in is the only signal, and sorting by start time is wrong
    for books whose chapters were written out of order.
    """
    top = next((t for t in tag.toc if t.top_level and t.ordered), None)
    if top is None:
        return list(tag.chapters)
    by_id = {c.element_id: c for c in tag.chapters}
    out = [by_id[child] for child in top.children if child in by_id]
    out.extend(c for c in tag.chapters if c.element_id not in set(top.children))
    return out


# --------------------------------------------------------------------------
# Writing, so the reader can be checked against another implementation
# --------------------------------------------------------------------------


def build_chap(
    element_id: str,
    start_ms: int,
    end_ms: int,
    title: str | None = None,
    *,
    start_offset: int = NOT_SET,
    end_offset: int = NOT_SET,
    major: int = 4,
    text_marker: int = 0x03,
) -> bytes:
    payload = element_id.encode("latin-1") + b"\x00"
    payload += struct.pack(">IIII", start_ms, end_ms, start_offset, end_offset)
    if title is not None:
        sub = encode_text(title, text_marker)
        size = int_to_syncsafe(len(sub)) if major >= 4 else struct.pack(">I", len(sub))
        payload += b"TIT2" + size + b"\x00\x00" + sub
    return payload


def build_tag(frames: list[tuple[str, bytes]], *, major: int = 4, padding: int = 0) -> bytes:
    body = b""
    for frame_id, payload in frames:
        size = int_to_syncsafe(len(payload)) if major >= 4 else struct.pack(">I", len(payload))
        body += frame_id.encode("latin-1") + size + b"\x00\x00" + payload
    body += b"\x00" * padding
    return b"ID3" + bytes([major, 0, 0]) + int_to_syncsafe(len(body)) + body
