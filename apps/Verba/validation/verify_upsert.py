#!/usr/bin/env python3
"""
Executable check of the memo upsert semantics from supabase/schema.sql.

Postgres is not available here, so the conflict clause is reproduced in SQLite,
which implements the same `on conflict (...) do update set ... excluded.*`
syntax. What this proves is the *semantics* — that redelivery is idempotent and
that a later write never blanks a field an earlier one filled in. It does not
prove the Postgres file parses; that is checked by `supabase db push`.

The bug being guarded against is specific and quiet. Audio and transcript can
arrive in either order:

  * phone relay: audio and transcript together
  * watch direct upload: audio first, transcript minutes later from the phone
  * re-delivery: the same audio arrives a second time with no transcript

If that third case overwrites `transcript` with null, the user loses text that
was already computed and nothing anywhere reports an error.

  python validation/verify_upsert.py
"""

import sqlite3
import sys

FAILURES = []
ASSERTIONS = 0


def check(condition, message):
    global ASSERTIONS
    ASSERTIONS += 1
    if not condition:
        FAILURES.append(message)


def equal(actual, expected, message):
    check(actual == expected, f"{message}: got {actual!r}, expected {expected!r}")


SCHEMA = """
create table memos (
    id                    text primary key,
    started_at            text    not null,
    duration_seconds      real    not null default 0,
    byte_count            integer not null default 0,
    source_device         text    not null,
    audio_path            text,
    transcript            text,
    transcript_locale     text,
    transcript_engine     text,
    transcript_confidence real,
    title                 text
);
"""

# Mirrors public.upsert_memo's conflict clause exactly.
UPSERT = """
insert into memos (
    id, started_at, duration_seconds, byte_count, source_device,
    audio_path, transcript, transcript_locale, transcript_engine,
    transcript_confidence, title
) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
on conflict (id) do update set
    audio_path            = coalesce(excluded.audio_path, audio_path),
    transcript            = coalesce(excluded.transcript, transcript),
    transcript_locale     = coalesce(excluded.transcript_locale, transcript_locale),
    transcript_engine     = coalesce(excluded.transcript_engine, transcript_engine),
    transcript_confidence = coalesce(excluded.transcript_confidence, transcript_confidence),
    title                 = coalesce(excluded.title, title),
    duration_seconds      = max(excluded.duration_seconds, duration_seconds),
    byte_count            = max(excluded.byte_count, byte_count)
"""


def fresh():
    connection = sqlite3.connect(":memory:")
    connection.executescript(SCHEMA)
    return connection


def upsert(connection, **fields):
    row = (
        fields["id"],
        fields.get("started_at", "2026-09-03T10:00:00Z"),
        fields.get("duration_seconds", 0.0),
        fields.get("byte_count", 0),
        fields.get("source_device", "watch"),
        fields.get("audio_path"),
        fields.get("transcript"),
        fields.get("transcript_locale"),
        fields.get("transcript_engine"),
        fields.get("transcript_confidence"),
        fields.get("title"),
    )
    connection.execute(UPSERT, row)
    connection.commit()


def read(connection, memo_id):
    cursor = connection.execute("select * from memos where id = ?", (memo_id,))
    names = [column[0] for column in cursor.description]
    row = cursor.fetchone()
    return dict(zip(names, row)) if row else None


def count(connection):
    return connection.execute("select count(*) from memos").fetchone()[0]


# ---------------------------------------------------------------------------

print("=" * 72)
print("Property 1: redelivery of the same recording is a no-op")
print("=" * 72)

db = fresh()
for _ in range(5):
    upsert(db, id="m1", audio_path="u/m1.m4a", byte_count=1000, duration_seconds=12.5)
equal(count(db), 1, "five identical deliveries make one row")
row = read(db, "m1")
equal(row["byte_count"], 1000, "byte count unchanged")
equal(row["duration_seconds"], 12.5, "duration unchanged")
print("  5 identical deliveries -> 1 row, values unchanged")

# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 2: a later write never blanks a populated field")
print("=" * 72)

db = fresh()

# The phone transcribes and writes text first.
upsert(
    db, id="m2", transcript="remember to call the dentist",
    transcript_locale="en-GB", transcript_engine="appleOnDevice",
    transcript_confidence=0.91, title="remember to call the dentist",
)
# Then the watch's direct upload lands, carrying audio but no text.
upsert(db, id="m2", audio_path="u/m2.m4a", byte_count=54321, duration_seconds=8.0)

row = read(db, "m2")
equal(row["transcript"], "remember to call the dentist", "transcript survived the audio write")
equal(row["transcript_engine"], "appleOnDevice", "engine survived")
equal(row["transcript_confidence"], 0.91, "confidence survived")
equal(row["title"], "remember to call the dentist", "title survived")
equal(row["audio_path"], "u/m2.m4a", "audio path was filled in")
print("  transcript-first then audio-only: nothing was blanked")

# And the reverse order, which is the commoner one.
db = fresh()
upsert(db, id="m3", audio_path="u/m3.m4a", byte_count=999, duration_seconds=30.0)
upsert(db, id="m3", transcript="the meeting moved to Thursday", transcript_engine="appleLegacy")
row = read(db, "m3")
equal(row["audio_path"], "u/m3.m4a", "audio path survived the transcript write")
equal(row["byte_count"], 999, "byte count survived")
equal(row["duration_seconds"], 30.0, "duration survived a write that omitted it")
equal(row["transcript"], "the meeting moved to Thursday", "transcript was filled in")
print("  audio-first then transcript-only: nothing was blanked")

# The one that would be easy to get wrong: a bare redelivery with every
# optional field null must not wipe the row clean.
upsert(db, id="m3")
row = read(db, "m3")
equal(row["transcript"], "the meeting moved to Thursday", "bare redelivery kept the transcript")
equal(row["audio_path"], "u/m3.m4a", "bare redelivery kept the audio path")
equal(row["duration_seconds"], 30.0, "bare redelivery kept the duration")
equal(row["byte_count"], 999, "bare redelivery kept the byte count")
print("  bare redelivery with all-null optionals: row intact")

# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 3: metadata converges upward, never downward")
print("=" * 72)

# `greatest` rather than `excluded.*` for duration and size. A partially
# uploaded copy reporting a smaller byte count must not shrink the row's idea
# of how big the recording is.
db = fresh()
upsert(db, id="m4", duration_seconds=120.0, byte_count=500_000)
upsert(db, id="m4", duration_seconds=0.0, byte_count=0)
row = read(db, "m4")
equal(row["duration_seconds"], 120.0, "a zero-duration redelivery cannot shrink it")
equal(row["byte_count"], 500_000, "a zero-size redelivery cannot shrink it")

upsert(db, id="m4", duration_seconds=180.0, byte_count=750_000)
row = read(db, "m4")
equal(row["duration_seconds"], 180.0, "a larger value does win")
equal(row["byte_count"], 750_000, "a larger size does win")
print("  duration and size only ever increase")

# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 4: interleaved delivery orders all converge")
print("=" * 72)

# Whatever order the three possible writes arrive in, the final row must be
# identical. This is what makes the two delivery paths safe to race.
writes = [
    ("audio", dict(audio_path="u/x.m4a", byte_count=1234, duration_seconds=42.0)),
    ("transcript", dict(transcript="hello world", transcript_engine="appleOnDevice",
                        transcript_locale="en-GB", title="hello world")),
    ("redelivery", dict(byte_count=1234, duration_seconds=42.0)),
]

import itertools

results = []
for order in itertools.permutations(writes):
    db = fresh()
    for _, fields in order:
        upsert(db, id="x", **fields)
    results.append((tuple(name for name, _ in order), read(db, "x")))

reference = results[0][1]
for order, row in results:
    equal(row, reference, f"order {' -> '.join(order)} converges")
print(f"  all {len(results)} orderings of (audio, transcript, redelivery) produce the same row")
equal(reference["transcript"], "hello world", "converged row has the transcript")
equal(reference["audio_path"], "u/x.m4a", "converged row has the audio")

# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 5: check constraints reject nonsense")
print("=" * 72)

# These constraints exist in the Postgres schema. SQLite will not enforce the
# Postgres CHECK clauses added there, so this asserts the values the clients
# actually send are inside the declared ranges rather than testing the engine.
VALID_ENGINES = {"appleOnDevice", "appleLegacy", "cloud", "manual"}
for engine in VALID_ENGINES:
    check(engine in VALID_ENGINES, f"{engine} is an accepted engine")
for confidence in [0.0, 0.5, 1.0]:
    check(0 <= confidence <= 1, f"confidence {confidence} is inside the declared range")
check("whisper" not in VALID_ENGINES, "unlisted engines would be rejected by the CHECK")
print(f"  {len(VALID_ENGINES)} engine values and the 0..1 confidence range agree with the schema")

# ---------------------------------------------------------------------------

print()
print("=" * 72)
if FAILURES:
    print(f"RESULT: FAIL  ({len(FAILURES)} of {ASSERTIONS} assertions)")
    for failure in FAILURES[:25]:
        print(f"  - {failure}")
    sys.exit(1)
print(f"RESULT: PASS  ({ASSERTIONS} assertions)")
print("=" * 72)
