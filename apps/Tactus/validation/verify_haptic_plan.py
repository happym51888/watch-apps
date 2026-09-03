"""Executable check of the Tactus metronome logic.

A Swift toolchain cannot run on this machine (the Windows Swift stdlib needs the
Windows SDK, which needs administrator rights), so the Swift test suite in
Tests/TactusCoreTests is written but unexecuted. This is a faithful port of
Sources/TactusCore/{PulseGrid,HapticPlan,TapTempo}.swift, exercising the same
properties, so the *logic* is verified even though the Swift is not compiled.

The properties that matter:

  1. No configuration, anywhere in the supported tempo/meter/subdivision space,
     ever schedules two haptics closer than the Taptic Engine's floor. This is
     the bug the shipping watch metronomes have.
  2. The gap a plan claims equals the gap it actually produces when simulated.
  3. Pulse offsets never drift.
  4. Tap tempo survives a fumbled tap and a pause.

Usage:
    python verify_haptic_plan.py
"""

import math
from statistics import median

BPM_MIN, BPM_MAX = 20.0, 400.0
DEFAULT_MIN_INTERVAL = 0.34


# --------------------------------------------------------------------------
# PulseGrid.swift
# --------------------------------------------------------------------------

DOWNBEAT, ACCENT, BEAT, SUBDIVISION = "downbeat", "accent", "beat", "subdivision"


class Settings:
    def __init__(self, bpm, beats_per_bar=4, beat_unit=4, subdivision=1, accented=frozenset()):
        assert subdivision >= 1
        assert beats_per_bar >= 1
        self.bpm = min(max(bpm, BPM_MIN), BPM_MAX)
        self.beats_per_bar = beats_per_bar
        self.beat_unit = beat_unit
        self.subdivision = subdivision
        self.accented = frozenset(accented)

    @property
    def beat_interval(self):
        return 60.0 / self.bpm

    @property
    def pulse_interval(self):
        return self.beat_interval / self.subdivision

    @property
    def pulses_per_bar(self):
        return self.beats_per_bar * self.subdivision

    @property
    def bar_interval(self):
        return self.beat_interval * self.beats_per_bar

    def __repr__(self):
        return (f"{self.bpm:g}bpm {self.beats_per_bar}/{self.beat_unit} "
                f"sub{self.subdivision} accents{sorted(self.accented)}")


class Pulse:
    __slots__ = ("index", "offset", "bar", "beat", "tick", "role")

    def __init__(self, index, offset, bar, beat, tick, role):
        self.index, self.offset = index, offset
        self.bar, self.beat, self.tick, self.role = bar, beat, tick, role


def pulse_at(s: Settings, index: int) -> Pulse:
    assert index >= 0
    per_bar = s.pulses_per_bar
    bar, in_bar = divmod(index, per_bar)
    beat, tick = divmod(in_bar, s.subdivision)

    if tick != 0:
        role = SUBDIVISION
    elif beat == 0:
        role = DOWNBEAT
    elif beat in s.accented:
        role = ACCENT
    else:
        role = BEAT

    return Pulse(index, index * s.pulse_interval, bar, beat, tick, role)


def next_index(s: Settings, elapsed: float) -> int:
    if elapsed <= 0:
        return 0
    exact = elapsed / s.pulse_interval
    rounded = round(exact)
    if abs(exact - rounded) < 1e-9:
        return int(rounded)
    return int(math.ceil(exact))


# --------------------------------------------------------------------------
# HapticPlan.swift
# --------------------------------------------------------------------------

EVERY_PULSE, BEATS_ONLY, ACCENTS_ONLY, DOWNBEAT_ONLY, NTH_BAR = (
    "everyPulse", "beatsOnly", "accentsOnly", "downbeatOnly", "everyNthBar")


class Plan:
    def __init__(self, coverage, tightest_gap, thinned, stride=None):
        self.coverage = coverage
        self.tightest_gap = tightest_gap
        self.thinned = thinned
        self.stride = stride

    def fires(self, p: Pulse) -> bool:
        if self.coverage == EVERY_PULSE:
            return True
        if self.coverage == BEATS_ONLY:
            return p.tick == 0
        if self.coverage == ACCENTS_ONLY:
            return p.tick == 0 and p.role in (DOWNBEAT, ACCENT)
        if self.coverage == DOWNBEAT_ONLY:
            return p.role == DOWNBEAT
        return p.role == DOWNBEAT and p.bar % self.stride == 0

    def __repr__(self):
        extra = f"({self.stride})" if self.stride else ""
        return f"{self.coverage}{extra}"


def tightest_accent_gap(s: Settings):
    accents = [0] + sorted(b for b in s.accented if 0 < b < s.beats_per_bar)
    if len(accents) <= 1:
        return None
    tightest = float("inf")
    for i in range(len(accents)):
        nxt = (i + 1) % len(accents)
        if nxt == 0:
            beats = s.beats_per_bar - accents[i] + accents[0]
        else:
            beats = accents[nxt] - accents[i]
        tightest = min(tightest, beats * s.beat_interval)
    return tightest


def plan_for(s: Settings, min_interval=DEFAULT_MIN_INTERVAL) -> Plan:
    if s.pulse_interval >= min_interval:
        return Plan(EVERY_PULSE, s.pulse_interval, False)
    if s.beat_interval >= min_interval:
        return Plan(BEATS_ONLY, s.beat_interval, True)
    gap = tightest_accent_gap(s)
    if gap is not None and gap >= min_interval:
        return Plan(ACCENTS_ONLY, gap, True)
    if s.bar_interval >= min_interval:
        return Plan(DOWNBEAT_ONLY, s.bar_interval, True)
    stride = max(2, int(math.ceil(min_interval / s.bar_interval)))
    return Plan(NTH_BAR, s.bar_interval * stride, True, stride)


# --------------------------------------------------------------------------
# TapTempo.swift
# --------------------------------------------------------------------------

class TapTempo:
    def __init__(self, reset_after=2.5, window=8):
        assert window >= 2
        self.reset_after, self.window = reset_after, window
        self.stamps = []

    def tap(self, time):
        if self.stamps and time - self.stamps[-1] > self.reset_after:
            self.stamps.clear()
        self.stamps.append(time)
        if len(self.stamps) > self.window:
            self.stamps = self.stamps[-self.window:]
        return self.estimate

    @property
    def estimate(self):
        if len(self.stamps) < 2:
            return None
        intervals = [b - a for a, b in zip(self.stamps, self.stamps[1:])]
        typical = median(intervals)
        if typical <= 0:
            return None
        return min(max(60.0 / typical, BPM_MIN), BPM_MAX)


# --------------------------------------------------------------------------
# Properties
# --------------------------------------------------------------------------

failures = []
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def property_rate_limit_never_violated():
    """Property 1: exhaustive sweep of the configuration space."""
    global checks
    worst = float("inf")
    worst_case = None
    meters = [(4, 4), (3, 4), (7, 8), (1, 4), (5, 4), (6, 8), (12, 8), (2, 2)]
    accent_sets = [frozenset(), frozenset({1}), frozenset({2}), frozenset({1, 2}), frozenset({3})]
    count = 0
    for bpm in range(int(BPM_MIN), int(BPM_MAX) + 1):
        for beats, unit in meters:
            for sub in (1, 2, 3, 4):
                for accents in accent_sets:
                    s = Settings(bpm, beats, unit, sub, accents)
                    p = plan_for(s)
                    count += 1
                    if p.tightest_gap < worst:
                        worst, worst_case = p.tightest_gap, (s, p)
                    if p.tightest_gap < DEFAULT_MIN_INTERVAL - 1e-9:
                        failures.append(f"rate limit violated: {s} -> {p} gap {p.tightest_gap:.4f}")
    checks += count
    print(f"  swept {count} configurations")
    print(f"  tightest gap anywhere: {worst:.4f}s "
          f"(floor {DEFAULT_MIN_INTERVAL}s) at {worst_case[0]} -> {worst_case[1]}")


def property_claimed_gap_matches_simulation():
    """Property 2: the claimed gap is what firing actually produces."""
    cases = [
        Settings(60), Settings(120, subdivision=2), Settings(200),
        Settings(200, accented={2}), Settings(320, 3, 4, 1, {1, 2}),
        Settings(400, 1), Settings(180, 7, 8, 3, {3, 5}),
        Settings(240, accented={3}), Settings(90, 5, 4, 4, {2, 4}),
    ]
    for s in cases:
        p = plan_for(s)
        last, observed = None, float("inf")
        fired = 0
        for i in range(s.pulses_per_bar * 12):
            pulse = pulse_at(s, i)
            if not p.fires(pulse):
                continue
            fired += 1
            if last is not None:
                observed = min(observed, pulse.offset - last)
            last = pulse.offset
        check(fired > 0, f"{s}: plan fired nothing")
        check(abs(observed - p.tightest_gap) < 1e-9,
              f"{s} -> {p}: claimed {p.tightest_gap:.6f} but simulated {observed:.6f}")
        check(observed >= DEFAULT_MIN_INTERVAL - 1e-9,
              f"{s} -> {p}: simulated gap {observed:.6f} under floor")


def property_downbeat_always_fires():
    for bpm in range(int(BPM_MIN), int(BPM_MAX) + 1, 7):
        for sub in (1, 2, 3, 4):
            s = Settings(bpm, subdivision=sub)
            check(plan_for(s).fires(pulse_at(s, 0)), f"{s}: downbeat suppressed")


def property_no_drift():
    bpm = 137.0
    s = Settings(bpm)
    n = int(3600.0 / s.pulse_interval)
    exact = n * (60.0 / bpm)
    check(abs(pulse_at(s, n).offset - exact) < 1e-9,
          f"drift: {pulse_at(s, n).offset} vs {exact}")
    accumulated = 0.0
    for _ in range(n):
        accumulated += s.pulse_interval
    print(f"  after {n} pulses ({n * s.pulse_interval / 60:.0f} min at {bpm:g}bpm): "
          f"indexed offset error {abs(pulse_at(s, n).offset - exact):.2e}s, "
          f"accumulating loop error {abs(accumulated - exact):.2e}s")


def property_recovery_after_stall():
    s = Settings(90, subdivision=2)
    for stall in (0.0, 0.01, 12.7, 60.0, 3600.5):
        i = next_index(s, stall)
        offset = pulse_at(s, i).offset
        check(offset >= stall - 1e-9, f"stall {stall}: resumed in the past ({offset})")
        check(offset - stall < s.pulse_interval + 1e-9,
              f"stall {stall}: skipped more than one pulse")
    check(next_index(Settings(120), 0.5) == 1, "boundary at 0.5s should be index 1")
    check(next_index(Settings(120), 2.0) == 4, "boundary at 2.0s should be index 4")


def property_thinning_order():
    """Subdivisions go before beats; beats before accents; accents before downbeat."""
    check(plan_for(Settings(100)).coverage == EVERY_PULSE, "100bpm should keep every pulse")
    check(plan_for(Settings(120, subdivision=4)).coverage == BEATS_ONLY,
          "120bpm sixteenths should fall back to beats")
    check(plan_for(Settings(240, accented={2})).coverage == ACCENTS_ONLY,
          "240bpm with a usable accent pattern should fall back to accents")
    check(plan_for(Settings(300)).coverage == DOWNBEAT_ONLY,
          "300bpm with no accents should fall back to downbeat")
    check(plan_for(Settings(400, 1)).coverage == NTH_BAR,
          "400bpm one-beat bars should skip bars")
    # Accents on 0 and 3 of 4: the wrap-around gap is one beat, so at 240bpm
    # accents-only must be rejected.
    check(plan_for(Settings(240, accented={3})).coverage != ACCENTS_ONLY,
          "wrap-around accent gap ignored")


def property_tap_tempo():
    t = TapTempo()
    check(t.tap(0.0) is None, "one tap should not yield an estimate")
    check(abs(t.tap(0.5) - 120) < 1e-9, "two taps 0.5s apart should read 120")

    steady = TapTempo()
    for i in range(8):
        steady.tap(i * 0.4)
    check(abs(steady.estimate - 150) < 1e-9, f"steady 0.4s taps should read 150, got {steady.estimate}")

    fumbled = TapTempo()
    for stamp in [0, 0.5, 1.0, 1.5, 1.62, 2.5, 3.0, 3.5]:
        fumbled.tap(stamp)
    check(abs(fumbled.estimate - 120) < 15,
          f"one fumbled tap moved the estimate too far: {fumbled.estimate}")

    paused = TapTempo(reset_after=2.0)
    paused.tap(0.0)
    paused.tap(0.5)
    check(paused.tap(10.0) is None, "a long pause should restart the measurement")
    paused.tap(11.0)
    check(abs(paused.estimate - 60) < 1e-9, f"new tempo after pause should be 60, got {paused.estimate}")

    fast = TapTempo()
    fast.tap(0.0)
    check(fast.tap(0.01) == BPM_MAX, "implausibly fast taps should clamp to the range")


def main():
    print("Verifying Tactus metronome logic (Python port of TactusCore)\n")

    print("Property 1: haptic rate limit is never violated")
    property_rate_limit_never_violated()
    print("\nProperty 2: claimed gap == simulated gap")
    property_claimed_gap_matches_simulation()
    print("\nProperty 3: the downbeat always fires")
    property_downbeat_always_fires()
    print("\nProperty 4: pulse offsets do not drift")
    property_no_drift()
    print("\nProperty 5: recovery after a stall lands on the right pulse")
    property_recovery_after_stall()
    print("\nProperty 6: thinning gives up detail in the right order")
    property_thinning_order()
    print("\nProperty 7: tap tempo")
    property_tap_tempo()

    print(f"\n{checks} assertions")
    if failures:
        print(f"RESULT: FAIL ({len(failures)})")
        for f in failures[:20]:
            print(f"  - {f}")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
