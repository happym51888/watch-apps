"""
Regression test for tools/check_secrets.py.

Plants each kind of credential into a real tracked file, confirms the checker
reports it, and restores the file. Also confirms the templates the setup
instructions depend on are treated as required.

The fake keys below are syntactically valid and cryptographically worthless:
the JWT is a real base64 header and payload with a nonsense signature.

Every one of them is assembled from fragments at runtime, so that no literal
credential shape appears in this file's source. That is not decoration. This
file is tracked, so check_secrets.py scans it like any other, and written out
in full the fixtures make the checker fail on a clean tree — which is exactly
what happened on the first push. Exempting the file would have worked and
would also have created the one place in the repo where a real key could hide.
Keep the fragments split.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKER = ROOT / "tools" / "check_secrets.py"
VICTIM = ROOT / "apps" / "Verba" / "web" / "config.example.js"

DOT = "."
JWT_HEADER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

PLANTS = {
    "Supabase anon key":
        JWT_HEADER + DOT + "eyJyb2xlIjoiYW5vbiIsImlhdCI6MTcwMDAwMDAwMH0"
        + DOT + "not_a_real_signature_at_all",
    "service-role JWT":
        JWT_HEADER + DOT + "eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaWF0IjoxNzAwMH0"
        + DOT + "also_entirely_fake_signature",
    "real project URL":
        "https://" + "abcdefghijklmnopqrst" + DOT + "supabase.co",
    "GitHub token":
        "ghp" + "_" + "0123456789abcdefghijklmnopqrstuvwxyz",
    "AWS key id":
        "AKIA" + "IOSFODNN7EXAMPLE",
    "private key block":
        "-----BEGIN RSA " + "PRIVATE KEY-----",
    "assigned password":
        "password: " + '"hunter2hunter2"',
    "employer hostname":
        "confluence" + DOT + "ext.example.internal",
}


def run() -> tuple[int, str]:
    result = subprocess.run([sys.executable, str(CHECKER)],
                            cwd=ROOT, capture_output=True)
    return result.returncode, result.stdout.decode("utf-8", "replace")


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")

    print("=" * 72)
    print("check_secrets self-test")
    print("=" * 72)
    print()

    original = VICTIM.read_bytes()
    failures: list[str] = []

    try:
        code, _ = run()
        if code == 0:
            print("  ok         clean tree passes")
        else:
            failures.append("clean tree should pass")
            print("  FAIL       clean tree should pass")

        for label, payload in PLANTS.items():
            VICTIM.write_bytes(original + f"\n// {payload}\n".encode())
            code, output = run()
            if code != 0:
                print(f"  caught     {label}")
            else:
                failures.append(f"missed {label}")
                print(f"  MISSED     {label}")

        # A template going missing breaks the setup instructions silently.
        VICTIM.write_bytes(original)
        VICTIM.rename(VICTIM.with_suffix(".js.moved"))
        code, output = run()
        if code != 0 and "missing template" in output:
            print("  caught     template deleted")
        else:
            failures.append("missed a deleted template")
            print("  MISSED     template deleted")
        VICTIM.with_suffix(".js.moved").rename(VICTIM)

    finally:
        moved = VICTIM.with_suffix(".js.moved")
        if moved.exists():
            moved.rename(VICTIM)
        VICTIM.write_bytes(original)

    if VICTIM.read_bytes() != original:
        failures.append("failed to restore the victim file")

    code, _ = run()
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
    print(f"RESULT: PASS  ({len(PLANTS)} credential shapes caught, file restored)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
