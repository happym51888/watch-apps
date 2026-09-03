"""
Regression test for tools/check_encoding.py.

A guard that has never been seen to fail is not a guard, it is decoration.
This reproduces the two failures the checker exists to catch, on a real
tracked file, and asserts the checker reports each one. The file is restored
in a finally block, and the test refuses to run if the working tree copy is
not byte-identical afterwards.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKER = ROOT / "tools" / "check_encoding.py"
VICTIM = ROOT / "apps" / "Tactus" / "project.yml"


def run_checker() -> tuple[int, str]:
    result = subprocess.run(
        [sys.executable, str(CHECKER)],
        cwd=ROOT, capture_output=True,
    )
    return result.returncode, result.stdout.decode("utf-8", "replace")


def main() -> int:
    print("=" * 72)
    print("check_encoding self-test")
    print("=" * 72)

    original = VICTIM.read_bytes()
    failures: list[str] = []

    try:
        code, output = run_checker()
        if code == 0:
            print("\n  [ok] clean tree passes")
        else:
            failures.append("clean tree should pass but did not")
            print(f"\n  [FAIL] clean tree should pass\n{output}")

        # Failure 1: the actual corruption. PowerShell's ANSI rewrite truncated
        # the three-byte em-dash U+2014 (e2 80 94) to two bytes.
        assert b"\xe2\x80\x94" in original, "expected an em-dash to mangle"
        VICTIM.write_bytes(original.replace(b"\xe2\x80\x94", b"\xe2\x80", 1))
        code, output = run_checker()
        if code != 0 and "invalid UTF-8" in output:
            print("  [ok] truncated em-dash caught")
        else:
            failures.append("truncated em-dash not caught")
            print(f"  [FAIL] truncated em-dash not caught\n{output}")

        # Failure 2: a BOM, which is valid UTF-8 but breaks parsers that expect
        # the file to start with what it looks like it starts with.
        VICTIM.write_bytes(b"\xef\xbb\xbf" + original)
        code, output = run_checker()
        if code != 0 and "BOM" in output:
            print("  [ok] UTF-8 BOM caught")
        else:
            failures.append("UTF-8 BOM not caught")
            print(f"  [FAIL] UTF-8 BOM not caught\n{output}")

    finally:
        VICTIM.write_bytes(original)

    if VICTIM.read_bytes() != original:
        failures.append("failed to restore the victim file")

    code, _ = run_checker()
    if code != 0:
        failures.append("tree not clean after restore")

    print()
    print("=" * 72)
    if failures:
        print(f"RESULT: FAIL  ({len(failures)})")
        for failure in failures:
            print(f"  - {failure}")
        print("=" * 72)
        return 1
    print("RESULT: PASS  (checker catches both, file restored)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
