"""Run everything that can be checked without a Mac, and say what was skipped.

There are ten validators and five repo checks, and until now the only way to
run them was one at a time out of the README. This is the single command, and
it is deliberately loud about the things it cannot do: `xcodebuild`, `swift
test` and the simulator all need macOS, and no amount of green here stands in
for them.

    python tools/verify_all.py

Uses `.venv/Scripts/python.exe` when it exists, because Volumen's ID3 check
refuses to pass without mutagen — that check's whole value is that mutagen is
somebody else's parser, so skipping it quietly would be worse than failing.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Ordered fast-to-slow inside each group, so a typo surfaces in seconds.
CHECKS: list[tuple[str, str]] = [
    ("repo", "tools/check_encoding.py"),
    ("repo", "tools/check_secrets.py"),
    ("repo", "tools/check_infoplists.py"),
    ("repo", "tools/check_privacy_manifests.py"),
    ("repo", "tools/check_workflow.py"),
    ("Kairos", "apps/Kairos/validation/verify_totp.py"),
    ("Tactus", "apps/Tactus/validation/verify_haptic_plan.py"),
    ("Awqat", "apps/Awqat/validation/verify_astronomy.py"),
    ("Verba", "apps/Verba/validation/verify_queue.py"),
    ("Verba", "apps/Verba/validation/verify_transcript.py"),
    ("Verba", "apps/Verba/validation/verify_upsert.py"),
    ("Proxima", "apps/Proxima/validation/verify_gtfs.py"),
    ("Proxima", "apps/Proxima/validation/verify_swift_vectors.py"),
    ("Volumen", "apps/Volumen/validation/verify_book.py"),
    ("Volumen", "apps/Volumen/validation/verify_id3.py"),
]

# Real dependencies, not missing work. Named so the summary cannot imply
# coverage the run does not have.
NEEDS_MORE_THAN_PYTHON: list[tuple[str, str]] = [
    ("apps/Verba/supabase/test/verify_schema.py", "needs a running PostgreSQL; CI has one"),
    ("apps/Proxima/validation/_partridge_crosscheck.py", "needs partridge; run by hand"),
]

NEEDS_MACOS = [
    "swift test (6 packages)",
    "xcodebuild (10 targets)",
    "install and screenshot on the watch simulator (6 apps)",
]


def interpreter() -> str:
    for candidate in (".venv/Scripts/python.exe", ".venv/bin/python"):
        path = ROOT / candidate
        if path.exists():
            return str(path)
    return sys.executable


def main() -> int:
    python = interpreter()
    print("=" * 72)
    print("Everything checkable without a Mac")
    print("=" * 72)
    print(f"  interpreter: {python}")
    if pathlib.Path(python) == pathlib.Path(sys.executable) and not (ROOT / ".venv").exists():
        print("  note: no .venv found; Volumen's ID3 check will fail without mutagen")
    print()

    failed: list[str] = []
    started = time.monotonic()

    for group, script in CHECKS:
        label = f"{group:<8} {pathlib.Path(script).name}"
        began = time.monotonic()
        result = subprocess.run(
            [python, script], cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace",
        )
        took = time.monotonic() - began
        tail = [line for line in (result.stdout or "").splitlines() if line.startswith("RESULT")]
        verdict = tail[-1] if tail else f"exit {result.returncode}"
        mark = "ok  " if result.returncode == 0 else "FAIL"
        print(f"  {mark}  {label:<40} {took:5.1f}s  {verdict}")
        if result.returncode != 0:
            failed.append(script)

    print()
    print("  not run here:")
    for script, why in NEEDS_MORE_THAN_PYTHON:
        print(f"    - {pathlib.Path(script).name}: {why}")
    print("  not runnable on this machine at all — macOS only:")
    for item in NEEDS_MACOS:
        print(f"    - {item}")

    print()
    print("=" * 72)
    total = time.monotonic() - started
    if failed:
        print(f"RESULT: FAIL  ({len(failed)} of {len(CHECKS)}) in {total:.0f}s")
        for script in failed:
            print(f"  - {script}")
    else:
        print(f"RESULT: PASS  ({len(CHECKS)} of {len(CHECKS)}) in {total:.0f}s")
        print("  This says the arithmetic is right. It says nothing about whether")
        print("  the apps compile — that is what the macOS jobs in CI are for.")
    print("=" * 72)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
