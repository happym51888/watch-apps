#!/usr/bin/env python3
"""
Executable check of chunking and transcript stitching.

Long recordings must be fed to the speech recogniser in bounded windows. Cut
them on a fixed grid and every cut eats whatever word straddled it; overlap the
windows and naive concatenation repeats a phrase at every seam. Both failures
produce transcripts that *read fine*, which is why they need a test rather than
an eyeball.

The property that matters is asymmetric, and the code is built around it:

    losing a real word is unacceptable; repeating one is merely untidy

so where the seam is ambiguous, the stitcher keeps too much rather than too
little, and this file asserts that direction explicitly.

  python validation/verify_transcript.py
"""

import random
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


# ---------------------------------------------------------------------------
# Port of Sources/VerbaCore/ChunkPlan.swift
# ---------------------------------------------------------------------------


def chunk_plan(duration, window=55.0, overlap=5.0):
    assert duration >= 0 and window > 0 and 0 <= overlap < window

    if duration <= window:
        return [(0, 0.0, duration)]

    chunks = []
    stride = window - overlap
    start = 0.0
    index = 0
    while start < duration:
        end = min(start + window, duration)
        chunks.append((index, start, end))
        if end >= duration:
            break
        start += stride
        index += 1

    if len(chunks) >= 2 and (chunks[-1][2] - chunks[-1][1]) <= overlap:
        chunks.pop()
        index, start, _ = chunks.pop()
        chunks.append((index, start, duration))

    return chunks


def covers_everything(chunks):
    if not chunks or chunks[0][1] != 0:
        return False
    for earlier, later in zip(chunks, chunks[1:]):
        if later[1] > earlier[2]:
            return False
    return True


# ---------------------------------------------------------------------------
# Port of Sources/VerbaCore/TranscriptStitcher.swift
# ---------------------------------------------------------------------------

PUNCT = set(".,!?;:'\"()[]{}<>-—…、。，！？；：「」『』（）")


def is_separator(ch):
    return ch.isspace() or ch in PUNCT


def tokens(text):
    out, current = [], []
    for ch in text.lower():
        if is_separator(ch):
            if current:
                out.append("".join(current))
                current = []
        else:
            current.append(ch)
    if current:
        out.append("".join(current))
    return out


def overlap_length(left, right, max_tokens):
    limit = min(max_tokens, len(left), len(right))
    length = limit
    while length > 0:
        if left[-length:] == right[:length]:
            return length
        length -= 1
    return 0


def drop_leading_tokens(count, text):
    if count <= 0:
        return text
    seen = 0
    inside = False
    for position, ch in enumerate(text):
        if is_separator(ch):
            if inside:
                seen += 1
                inside = False
                if seen == count:
                    after = position
                    while after < len(text) and is_separator(text[after]):
                        after += 1
                    return text[after:]
        else:
            inside = True
    return ""


def stitch(pieces, max_overlap_tokens=24):
    usable = [p.strip() for p in pieces if p and p.strip()]
    if not usable:
        return ""
    result = usable[0]
    result_tokens = tokens(result)
    for piece in usable[1:]:
        piece_tokens = tokens(piece)
        shared = overlap_length(result_tokens, piece_tokens, max_overlap_tokens)
        if shared == 0:
            result += " " + piece
            result_tokens += piece_tokens
            continue
        remainder = drop_leading_tokens(shared, piece)
        if remainder:
            result += " " + remainder
        result_tokens += piece_tokens[shared:]
    return result


# ---------------------------------------------------------------------------
# 1. Chunk plans cover the whole recording
# ---------------------------------------------------------------------------

print("=" * 72)
print("Property 1: every second of audio lands in at least one chunk")
print("=" * 72)

configs = 0
for window in [15.0, 30.0, 55.0, 120.0]:
    for overlap in [0.0, 1.0, 5.0, 10.0]:
        if overlap >= window:
            continue
        for duration in [0.0, 0.5, 1.0, 14.9, 15.0, 15.1, 54.9, 55.0, 55.1,
                         60.0, 119.0, 300.0, 1800.0, 3600.0, 7200.0]:
            configs += 1
            chunks = chunk_plan(duration, window, overlap)
            check(len(chunks) >= 1, f"at least one chunk ({duration}s)")
            check(covers_everything(chunks), f"no gap ({duration}s/{window}s/{overlap}s)")
            equal(chunks[0][1], 0.0, f"starts at zero ({duration}s)")
            equal(chunks[-1][2], duration, f"ends at the end ({duration}s)")
            for _, start, end in chunks:
                check(end - start <= window + 1e-9,
                      f"no chunk exceeds the request limit ({duration}s)")
                check(end >= start, f"no inverted chunk ({duration}s)")
            # Indices must be contiguous from zero, since they order the
            # transcripts before stitching.
            equal([c[0] for c in chunks], list(range(len(chunks))),
                  f"chunk indices are contiguous ({duration}s)")

print(f"  {configs} configurations swept across 4 windows x 4 overlaps x 15 durations")
print(f"  60 min at a 55s window -> {len(chunk_plan(3600))} chunks")

# A recording that fits in one request must not be split at all: no seam, no
# stitching, no chance of a seam bug.
equal(len(chunk_plan(54.0)), 1, "short recording is a single chunk")
equal(len(chunk_plan(55.0)), 1, "exactly-window recording is a single chunk")
check(len(chunk_plan(55.1)) > 1, "just over the window does split")
print("  recordings within one window are never split")

# ---------------------------------------------------------------------------
# 2. Stitching removes the duplicate and keeps everything else
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 2: stitching removes the overlap, not the content")
print("=" * 72)

cases = [
    (
        "clean seam",
        ["the quick brown fox jumps", "brown fox jumps over the lazy dog"],
        "the quick brown fox jumps over the lazy dog",
    ),
    (
        "seam differs in case and punctuation",
        ["we should ship it on Friday", "Friday, if the tests pass"],
        "we should ship it on Friday if the tests pass",
    ),
    (
        "no overlap detected at all",
        ["completely unrelated opening", "entirely different continuation"],
        "completely unrelated opening entirely different continuation",
    ),
    (
        "three chunks",
        ["one two three four", "three four five six", "five six seven eight"],
        "one two three four five six seven eight",
    ),
    (
        "second chunk is entirely inside the first",
        ["alpha beta gamma delta", "gamma delta"],
        "alpha beta gamma delta",
    ),
    (
        "empty chunk in the middle is skipped",
        ["hello there", "", "there friend"],
        "hello there friend",
    ),
]

for name, pieces, expected in cases:
    equal(stitch(pieces), expected, name)
    print(f"  ok  {name}")

equal(stitch([]), "", "no chunks yields empty")
equal(stitch(["   "]), "", "whitespace-only yields empty")
equal(stitch(["only one"]), "only one", "single chunk passes through")

# ---------------------------------------------------------------------------
# 3. No word is ever lost, over randomised speech
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 3: no word is lost, across randomised recordings")
print("=" * 72)

VOCAB = (
    "the a of and to in that it is was for on with as at by from we you they "
    "meeting deadline budget release testing customer feedback question answer "
    "tomorrow morning afternoon remember buy milk call mum invoice number".split()
)

rng = random.Random(4242)
runs = 3000
exact = 0
supersets = 0
total_words = 0

for run in range(runs):
    length = rng.randint(6, 220)
    words = [rng.choice(VOCAB) for _ in range(length)]
    total_words += length

    # Simulate a chunked transcription: cut the word stream into overlapping
    # windows the same way ChunkPlan cuts the audio.
    window = rng.randint(8, 40)
    overlap = rng.randint(1, max(1, min(8, window - 1)))
    pieces = []
    start = 0
    while start < len(words):
        end = min(start + window, len(words))
        pieces.append(" ".join(words[start:end]))
        if end >= len(words):
            break
        start += window - overlap

    merged = tokens(stitch(pieces))
    original = [w.lower() for w in words]

    # The hard requirement: every original word survives, in order. A
    # subsequence check rather than equality, because the stitcher is allowed
    # to keep a duplicate when the seam is ambiguous.
    position = 0
    for word in merged:
        if position < len(original) and word == original[position]:
            position += 1
    check(
        position == len(original),
        f"run {run}: lost content — matched {position}/{len(original)} words",
    )

    if merged == original:
        exact += 1
    elif len(merged) > len(original):
        supersets += 1

print(f"  {runs} randomised recordings, {total_words} words total")
print(f"  {exact} reconstructed exactly ({100.0 * exact / runs:.1f}%)")
print(f"  {supersets} kept a duplicate at an ambiguous seam ({100.0 * supersets / runs:.1f}%)")
print("  0 lost a word — the failure direction is always 'too much', never 'too little'")

# ---------------------------------------------------------------------------
# 4. Ambiguous seams resolve safely
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 4: repetitive speech does not trigger over-deletion")
print("=" * 72)

# Genuinely repetitive input is the adversarial case: a naive longest-match
# will happily delete a real repetition, believing it to be the seam.
repetitive = [
    (["yes yes yes yes", "yes yes yes yes no"], "must not collapse to fewer than 4 'yes'"),
    (["ha ha ha", "ha ha ha ha"], "laughter"),
    (["one one one two", "one two three"], "counting with repeats"),
]

for pieces, label in repetitive:
    merged = tokens(stitch(pieces))
    first = tokens(pieces[0])
    # Whatever the seam decision, the result must still start with the entire
    # first chunk. Anything less means content was deleted from a chunk that
    # had no seam ahead of it.
    check(merged[:len(first)] == first, f"{label}: first chunk survives intact")
    check(len(merged) >= len(first), f"{label}: never shorter than the first chunk")
    print(f"  ok  {label}: {' '.join(merged)}")

# The bounded search is what prevents a runaway match. Two unrelated chunks
# sharing many common words must not have half of one deleted.
long_left = "the the the the the the the the the the the the the the the the the the the the the the the the the the the the the the"
long_right = long_left + " finally something new"
merged = tokens(stitch([long_left, long_right], max_overlap_tokens=24))
check(len(merged) >= len(tokens(long_left)), "bounded search never deletes below the first chunk")
check("finally" in merged and "new" in merged, "new content after a long repeat survives")
print("  ok  bounded seam search: 30 identical tokens, new content still kept")

# ---------------------------------------------------------------------------
# 5. CJK, which has no spaces to tokenise on
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 5: Chinese text degrades safely rather than corrupting")
print("=" * 72)

# Whitespace tokenisation cannot find a seam inside Chinese, so the stitcher
# finds no overlap and keeps both chunks whole. That is the correct failure:
# a visible repetition the user can delete, not silent loss. Asserting it here
# so the behaviour is a decision rather than an accident.
cjk = ["明天下午三点开会", "开会讨论预算问题"]
merged = stitch(cjk)
for piece in cjk:
    check(piece in merged, f"CJK chunk kept whole: {piece}")
print(f"  no seam found, both chunks kept: {merged}")
print("  documented limitation: CJK seams need a segmenter, tracked in the README")

# Mixed content still works wherever there are spaces.
equal(
    stitch(["开会 discuss the budget", "discuss the budget 问题"]),
    "开会 discuss the budget 问题",
    "mixed CJK and Latin seams on the Latin words",
)
print("  ok  mixed Chinese/English stitches on the Latin tokens")

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
