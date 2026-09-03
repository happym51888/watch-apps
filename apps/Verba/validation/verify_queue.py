#!/usr/bin/env python3
"""
Executable check of VerbaCore's delivery queue.

A voice recorder has exactly one unforgivable bug: losing a recording. Late
delivery is a nuisance; a deleted sole copy is unrecoverable and the user will
not find out until they go looking for something that mattered.

So the queue is written as a pure state machine, ported here line-for-line, and
hammered with randomised event sequences — including crashes mid-transfer,
which is the case that strands recordings in real apps.

The central invariant, asserted after every single event of every run:

    audio that exists only on the watch is never deleted

  python validation/verify_queue.py
"""

import math
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
# Port of Sources/VerbaCore/Backoff.swift
# ---------------------------------------------------------------------------


class Backoff:
    def __init__(self, base=2.0, cap=3600.0, attempts_before_pausing=12):
        assert base > 0 and cap >= base
        self.base = base
        self.cap = cap
        self.attempts_before_pausing = attempts_before_pausing

    def delay(self, attempts, random_fraction):
        assert attempts >= 0
        ceiling = self.base
        for _ in range(min(attempts, 40)):
            ceiling *= 2
            if ceiling >= self.cap:
                ceiling = self.cap
                break
        ceiling = min(ceiling, self.cap)
        return max(1.0, ceiling * random_fraction)

    def should_keep_retrying(self, attempts):
        return attempts < self.attempts_before_pausing


# ---------------------------------------------------------------------------
# Port of Sources/VerbaCore/Recording.swift + TransferQueue.swift
# ---------------------------------------------------------------------------

PENDING, IN_FLIGHT, DELIVERED, BLOCKED = "pending", "inFlight", "delivered", "blocked"


class Recording:
    def __init__(self, rid, started_at, byte_count):
        self.id = rid
        self.started_at = started_at
        self.byte_count = byte_count
        self.state = PENDING
        self.attempts = 0
        self.next_attempt_at = None
        self.block_reason = None
        self.has_local_file = True

    @property
    def is_sole_copy(self):
        return self.state != DELIVERED and self.has_local_file

    @property
    def local_bytes(self):
        return self.byte_count if self.has_local_file else 0


class StoragePolicy:
    def __init__(self, byte_budget=200 * 1024 * 1024, keep_delivered_count=10):
        self.byte_budget = byte_budget
        self.keep_delivered_count = keep_delivered_count


class TransferQueue:
    def __init__(self, items=None, policy=None, backoff=None, max_concurrent=1):
        self.items = sorted(items or [], key=lambda entry: entry.started_at)
        self.policy = policy or StoragePolicy()
        self.backoff = backoff or Backoff()
        self.max_concurrent = max_concurrent

    # -- derived ---------------------------------------------------------

    @property
    def local_bytes(self):
        return sum(item.local_bytes for item in self.items)

    @property
    def sole_copy_bytes(self):
        return sum(item.byte_count for item in self.items if item.is_sole_copy)

    def item(self, rid):
        for entry in self.items:
            if entry.id == rid:
                return entry
        return None

    # -- events ----------------------------------------------------------

    def enqueue(self, recording, now):
        if any(entry.id == recording.id for entry in self.items):
            return []
        recording.state = PENDING
        recording.attempts = 0
        recording.next_attempt_at = None
        self.items.append(recording)
        self.items.sort(key=lambda entry: entry.started_at)
        return self._pump(now)

    def recover_after_launch(self, now):
        for entry in self.items:
            if entry.state == IN_FLIGHT:
                entry.state = PENDING
                entry.next_attempt_at = None
        return self._pump(now)

    def tick(self, now):
        return self._pump(now)

    def delivery_succeeded(self, rid, now):
        entry = self.item(rid)
        if entry is None or entry.state == DELIVERED:
            return []
        entry.state = DELIVERED
        entry.next_attempt_at = None
        entry.block_reason = None
        return self._evict() + self._pump(now)

    def delivery_failed(self, rid, retryable, reason, now, random_fraction):
        entry = self.item(rid)
        if entry is None or entry.state != IN_FLIGHT:
            return []
        entry.attempts += 1
        if not retryable or not self.backoff.should_keep_retrying(entry.attempts):
            entry.state = BLOCKED
            entry.block_reason = reason
            entry.next_attempt_at = None
            return self._pump(now)
        entry.state = PENDING
        entry.next_attempt_at = now + self.backoff.delay(entry.attempts, random_fraction)
        return self._pump(now)

    def retry_now(self, rid, now):
        entry = self.item(rid)
        if entry is None or entry.state not in (PENDING, BLOCKED):
            return []
        entry.state = PENDING
        entry.attempts = 0
        entry.next_attempt_at = None
        entry.block_reason = None
        return self._pump(now)

    def retry_all(self, now):
        for entry in self.items:
            if entry.state in (PENDING, BLOCKED):
                entry.state = PENDING
                entry.attempts = 0
                entry.next_attempt_at = None
                entry.block_reason = None
        return self._pump(now)

    # -- engine ----------------------------------------------------------

    def _pump(self, now):
        actions = []
        in_flight = sum(1 for entry in self.items if entry.state == IN_FLIGHT)

        for entry in self.items:
            if in_flight >= self.max_concurrent:
                break
            if entry.state != PENDING or not entry.has_local_file:
                continue
            if entry.next_attempt_at is not None and entry.next_attempt_at > now:
                continue
            entry.state = IN_FLIGHT
            entry.next_attempt_at = None
            in_flight += 1
            actions.append(("startDelivery", entry.id))

        if in_flight < self.max_concurrent:
            deadlines = [
                entry.next_attempt_at
                for entry in self.items
                if entry.state == PENDING
                and entry.has_local_file
                and entry.next_attempt_at is not None
                and entry.next_attempt_at > now
            ]
            if deadlines:
                actions.append(("scheduleWake", min(deadlines)))

        if self.local_bytes > self.policy.byte_budget:
            actions.append(
                ("reportStoragePressure", self.local_bytes, self.policy.byte_budget)
            )
        return actions

    def _evict(self):
        actions = []

        def evictable():
            return sorted(
                (e for e in self.items if e.state == DELIVERED and e.has_local_file),
                key=lambda e: e.started_at,
            )

        pool = evictable()
        while len(pool) > self.policy.keep_delivered_count:
            entry = pool.pop(0)
            entry.has_local_file = False
            actions.append(("deleteLocalFile", entry.id))

        pool = evictable()
        while self.local_bytes > self.policy.byte_budget and pool:
            entry = pool.pop(0)
            entry.has_local_file = False
            actions.append(("deleteLocalFile", entry.id))

        return actions


# ---------------------------------------------------------------------------
# Invariants checked after every event of every run
# ---------------------------------------------------------------------------


def assert_invariants(queue, actions, enqueued_ids, context):
    # THE invariant. Every deletion must target a delivered recording.
    for action in actions:
        if action[0] == "deleteLocalFile":
            entry = queue.item(action[1])
            check(
                entry is not None and entry.state == DELIVERED,
                f"{context}: deleted a file for a non-delivered recording {action[1]}",
            )

    # Nothing is ever forgotten. A row may lose its file, never its existence.
    for rid in enqueued_ids:
        check(queue.item(rid) is not None, f"{context}: recording {rid} vanished")

    # Concurrency ceiling.
    in_flight = [e for e in queue.items if e.state == IN_FLIGHT]
    check(
        len(in_flight) <= queue.max_concurrent,
        f"{context}: {len(in_flight)} in flight, max is {queue.max_concurrent}",
    )

    # An item with no local file can never be started.
    for action in actions:
        if action[0] == "startDelivery":
            entry = queue.item(action[1])
            check(
                entry is not None and entry.has_local_file,
                f"{context}: started delivery of an evicted file {action[1]}",
            )

    # Delivered-with-file count respects the retention rule.
    kept = [e for e in queue.items if e.state == DELIVERED and e.has_local_file]
    check(
        len(kept) <= queue.policy.keep_delivered_count,
        f"{context}: {len(kept)} delivered files kept, policy is "
        f"{queue.policy.keep_delivered_count}",
    )

    # Nothing is simultaneously blocked and scheduled.
    for entry in queue.items:
        if entry.state == BLOCKED:
            check(entry.next_attempt_at is None, f"{context}: blocked item has a deadline")
            check(entry.has_local_file, f"{context}: blocked item lost its file")


# ---------------------------------------------------------------------------
# 1. The invariant, under randomised chaos including crashes
# ---------------------------------------------------------------------------

print("=" * 72)
print("Property 1: sole-copy audio is never deleted, under randomised chaos")
print("=" * 72)

random.seed(20260903)

runs = 400
total_events = 0
total_crashes = 0
total_deleted = 0
total_delivered = 0

for run in range(runs):
    rng = random.Random(run)
    queue = TransferQueue(
        policy=StoragePolicy(
            byte_budget=rng.choice([1_000_000, 8_000_000, 64_000_000]),
            keep_delivered_count=rng.choice([0, 1, 5, 10]),
        ),
        backoff=Backoff(base=2, cap=rng.choice([60, 600, 3600]), attempts_before_pausing=rng.choice([3, 6, 12])),
        max_concurrent=rng.choice([1, 1, 1, 2, 3]),
    )
    now = 1_700_000_000.0
    enqueued = []
    next_id = 0

    for event_index in range(220):
        total_events += 1
        roll = rng.random()
        now += rng.choice([0, 0, 1, 5, 60, 900, 7200])

        if roll < 0.28:
            rid = f"r{next_id:04d}"
            next_id += 1
            recording = Recording(rid, now, rng.choice([200_000, 1_500_000, 12_000_000]))
            enqueued.append(rid)
            actions = queue.enqueue(recording, now)

        elif roll < 0.52:
            candidates = [e.id for e in queue.items if e.state == IN_FLIGHT]
            if not candidates:
                actions = queue.tick(now)
            else:
                actions = queue.delivery_succeeded(rng.choice(candidates), now)
                total_delivered += 1

        elif roll < 0.72:
            candidates = [e.id for e in queue.items if e.state == IN_FLIGHT]
            if not candidates:
                actions = queue.tick(now)
            else:
                actions = queue.delivery_failed(
                    rng.choice(candidates),
                    retryable=rng.random() < 0.85,
                    reason="simulated",
                    now=now,
                    random_fraction=rng.random(),
                )

        elif roll < 0.80:
            # Crash: the process dies. Anything in flight had no verdict.
            total_crashes += 1
            actions = queue.recover_after_launch(now)

        elif roll < 0.88:
            candidates = [e.id for e in queue.items if e.state in (PENDING, BLOCKED)]
            actions = queue.retry_now(rng.choice(candidates), now) if candidates else queue.tick(now)

        elif roll < 0.92:
            actions = queue.retry_all(now)

        else:
            actions = queue.tick(now)

        total_deleted += sum(1 for a in actions if a[0] == "deleteLocalFile")
        assert_invariants(queue, actions, enqueued, f"run {run} event {event_index}")

print(f"  {runs} randomised runs, {total_events} events")
print(f"  {total_crashes} simulated crashes mid-transfer")
print(f"  {total_delivered} deliveries, {total_deleted} file evictions")
print("  every eviction targeted a delivered recording; nothing was forgotten")

# ---------------------------------------------------------------------------
# 2. Crash recovery specifically
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 2: a crash mid-transfer strands nothing")
print("=" * 72)

queue = TransferQueue()
now = 1_700_000_000.0
queue.enqueue(Recording("a", now, 1000), now)
equal(queue.item("a").state, IN_FLIGHT, "delivery starts immediately")

# Process dies here. No success, no failure callback, ever.
actions = queue.recover_after_launch(now + 30)
equal(queue.item("a").state, IN_FLIGHT, "recovered item is restarted, not stranded")
check(("startDelivery", "a") in actions, "recovery re-emits the delivery action")
equal(queue.item("a").attempts, 0, "a crash is not charged as a failed attempt")

# Repeated crashes must not push a healthy recording toward the pause
# threshold, which would eventually mark it blocked and stop retrying.
for _ in range(50):
    queue.recover_after_launch(now)
equal(queue.item("a").attempts, 0, "50 crashes still cost zero attempts")
equal(queue.item("a").state, IN_FLIGHT, "still runnable after 50 crashes")
print("  in-flight -> pending -> restarted; 50 crashes cost 0 attempts")

# ---------------------------------------------------------------------------
# 3. Idempotence
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 3: duplicate events are absorbed")
print("=" * 72)

queue = TransferQueue()
now = 1_700_000_000.0
first = queue.enqueue(Recording("dup", now, 1000), now)
second = queue.enqueue(Recording("dup", now, 1000), now)
equal(len(queue.items), 1, "re-enqueuing the same id makes one item")
equal(second, [], "re-enqueue emits no actions")

queue.delivery_succeeded("dup", now)
before = len(queue.items)
again = queue.delivery_succeeded("dup", now)
equal(again, [], "success for an already-delivered item is a no-op")
equal(len(queue.items), before, "no duplicate rows")

# A failure arriving after a success — both transports raced — must not
# resurrect a delivered recording into the retry loop.
late = queue.delivery_failed("dup", True, "late", now, 0.5)
equal(queue.item("dup").state, DELIVERED, "late failure cannot undo delivery")
equal(late, [], "late failure emits nothing")
print("  duplicate enqueue, duplicate success, and a late failure after success")

# ---------------------------------------------------------------------------
# 4. FIFO
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 4: a backlog drains oldest first")
print("=" * 72)

# The realistic shape of this: the watch spent a weekend away from the phone,
# the app is relaunched, and a pile of recordings is loaded from disk in
# whatever order the store hands them over.
base = 1_700_000_000.0
stored = [Recording(f"t{offset:03d}", base + offset, 1000) for offset in [50, 10, 30, 0, 40, 20]]
queue = TransferQueue(items=stored, max_concurrent=1)
queue.recover_after_launch(base + 100)

order = []
now = base + 200
for _ in range(6):
    in_flight = [e.id for e in queue.items if e.state == IN_FLIGHT]
    equal(len(in_flight), 1, "exactly one delivery at a time")
    order.append(in_flight[0])
    queue.delivery_succeeded(in_flight[0], now)

equal(
    order,
    ["t000", "t010", "t020", "t030", "t040", "t050"],
    "backlog drains in recording order, whatever order it loaded in",
)
print(f"  loaded out of order, drained: {' -> '.join(order)}")

# The other half of the rule, which the first version of this test got wrong:
# a transfer already in flight is *not* preempted by an older recording
# arriving later. Cancelling live work to satisfy a sort order would waste the
# radio and can never happen on a real watch anyway, since recordings finish in
# the order they start.
queue = TransferQueue(max_concurrent=1)
queue.enqueue(Recording("late-but-newer", base + 50, 1000), base + 50)
equal(queue.item("late-but-newer").state, IN_FLIGHT, "first arrival starts at once")
queue.enqueue(Recording("older", base + 10, 1000), base + 60)
equal(queue.item("late-but-newer").state, IN_FLIGHT, "in-flight work is not preempted")
equal(queue.item("older").state, PENDING, "the older one waits its turn")
queue.delivery_succeeded("late-but-newer", base + 70)
equal(queue.item("older").state, IN_FLIGHT, "and starts as soon as the slot frees")
print("  an in-flight transfer is never preempted by a later-arriving older item")

# ---------------------------------------------------------------------------
# 5. Backoff shape
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 5: retry delays are bounded and jittered")
print("=" * 72)

backoff = Backoff(base=2, cap=3600, attempts_before_pausing=12)
for attempts in range(0, 60):
    for fraction in [0.0, 0.001, 0.25, 0.5, 0.9999]:
        delay = backoff.delay(attempts, fraction)
        check(delay >= 1.0, f"delay floor at {attempts} attempts")
        check(delay <= backoff.cap, f"delay cap at {attempts} attempts")
        check(math.isfinite(delay), f"delay finite at {attempts} attempts")

# The ceiling grows then plateaus; it must never shrink or overflow.
ceilings = [backoff.delay(n, 0.9999) for n in range(0, 40)]
for earlier, later in zip(ceilings, ceilings[1:]):
    check(later >= earlier - 1e-9, "ceiling is non-decreasing")
equal(round(ceilings[-1]), 3600, "ceiling saturates at the cap")

# Full jitter must actually spread a synchronised backlog out.
rng = random.Random(7)
samples = [backoff.delay(6, rng.random()) for _ in range(2000)]
spread = len(set(round(value) for value in samples))
check(spread > 50, f"jitter should spread retries; saw {spread} distinct delays")
print(f"  attempts 0..59 x 5 fractions: all within [1s, 3600s], finite, non-decreasing")
print(f"  full jitter produced {spread} distinct delays from 2000 samples")

# ---------------------------------------------------------------------------
# 6. Liveness
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 6: everything eventually gets delivered")
print("=" * 72)

for failure_rate, label in [(0.0, "perfect link"), (0.5, "flaky link"), (0.9, "terrible link")]:
    rng = random.Random(99)
    queue = TransferQueue(backoff=Backoff(base=2, cap=600, attempts_before_pausing=12))
    now = 1_700_000_000.0
    for index in range(40):
        queue.enqueue(Recording(f"L{index:03d}", now + index, 100_000), now)

    steps = 0
    while any(e.state != DELIVERED for e in queue.items) and steps < 20_000:
        steps += 1
        now += 30
        in_flight = [e.id for e in queue.items if e.state == IN_FLIGHT]
        if in_flight:
            if rng.random() < failure_rate:
                queue.delivery_failed(in_flight[0], True, "flaky", now, rng.random())
            else:
                queue.delivery_succeeded(in_flight[0], now)
        else:
            queue.tick(now)
            # A user who notices the backlog taps retry. Without this, a
            # terrible link legitimately parks items after 12 attempts.
            if steps % 50 == 0:
                queue.retry_all(now)

    remaining = sum(1 for e in queue.items if e.state != DELIVERED)
    equal(remaining, 0, f"{label}: all 40 recordings delivered")
    print(f"  {label:16} 40/40 delivered in {steps} steps")

# ---------------------------------------------------------------------------
# 7. Storage pressure never costs data
# ---------------------------------------------------------------------------

print()
print("=" * 72)
print("Property 7: a full disk degrades, it does not delete")
print("=" * 72)

# Budget deliberately smaller than a single recording, and nothing ever
# delivers. The queue must exceed its budget rather than free space by
# destroying the only copy.
queue = TransferQueue(
    policy=StoragePolicy(byte_budget=1_000_000, keep_delivered_count=5)
)
now = 1_700_000_000.0
pressure_reports = 0
for index in range(20):
    actions = queue.enqueue(Recording(f"F{index:03d}", now + index, 900_000), now)
    for action in actions:
        check(action[0] != "deleteLocalFile", "must not evict undelivered audio")
        if action[0] == "reportStoragePressure":
            pressure_reports += 1

equal(
    sum(1 for e in queue.items if e.has_local_file),
    20,
    "every sole copy is still on disk",
)
check(pressure_reports > 0, "the user is warned before their next recording fails")
equal(queue.sole_copy_bytes, 20 * 900_000, "no sole-copy bytes were reclaimed")
print(f"  20 undelivered recordings at 18x the budget: 0 deleted, {pressure_reports} warnings")

# Now let them deliver, and the space must actually come back.
for entry in list(queue.items):
    queue.delivery_succeeded(entry.id, now)
kept = sum(1 for e in queue.items if e.has_local_file)
check(kept <= 5, f"retention honoured after delivery, kept {kept}")
equal(queue.sole_copy_bytes, 0, "nothing is a sole copy any more")
equal(len(queue.items), 20, "all 20 remain listed, even without local audio")
print(f"  after delivery: {kept} files kept for playback, 20 rows still listed")

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
