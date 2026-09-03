"""
Assert every text file in the repo is valid UTF-8 with no BOM.

Added after a self-inflicted outage. Renaming a bundle identifier with
PowerShell's `Set-Content` rewrote apps/Tactus/project.yml in the machine's
ANSI code page, which truncated three em-dashes in comments into invalid byte
sequences. Nothing local complained: the file still looked right in an editor,
`git add` took it, `git diff` showed a plausible diff, and the change was
pushed. XcodeGen on the macOS runner then refused to parse it —

    Parsing project spec failed: The file "project.yml" couldn't be opened
    using text encoding Unicode (UTF-8)

— and the build failed on a comment, in a file whose functional content was
fine. Exactly the shape of failure this project keeps running into: no error
where the mistake was made, an error a long way away.

Two lessons, one of them enforced here:

  * Never edit text files with PowerShell redirection or `Set-Content`. It
    defaults to the ANSI code page, which is lossy for anything non-ASCII.
  * Catch it at the point of commit rather than four minutes into CI.

A BOM is also rejected. It is valid UTF-8, and it breaks tools that expect a
file to begin with what it appears to begin with — a YAML document, a shebang,
or `#!/bin/bash`.

Run:  python tools/check_encoding.py
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

SUFFIXES = {
    ".swift", ".yml", ".yaml", ".json", ".md", ".py", ".sh", ".sql",
    ".js", ".css", ".html", ".plist", ".xcprivacy", ".gitignore", ".txt",
}

BOMS = {
    b"\xef\xbb\xbf": "UTF-8 BOM",
    b"\xff\xfe": "UTF-16 LE BOM",
    b"\xfe\xff": "UTF-16 BE BOM",
}


def tracked_files() -> list[pathlib.Path]:
    """Only files git will actually carry to CI. Respects .gitignore for free."""
    listing = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout.decode("utf-8", "surrogateescape")
    return [ROOT / name for name in listing.split("\0") if name]


def main() -> int:
    # This script exists to report bad bytes, so it must survive printing them.
    # A Windows console defaults to the ANSI code page, which cannot encode the
    # U+FFFD that decoding with errors="replace" produces — the checker would
    # die with UnicodeEncodeError while describing the problem it found, exit
    # non-zero, and print no reason. Same class of bug it is here to catch.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")

    print("=" * 72)
    print("Text file encoding")
    print("=" * 72)

    checked = 0
    problems: list[str] = []

    for path in sorted(tracked_files()):
        if not path.is_file():
            continue
        if path.suffix not in SUFFIXES and path.name not in {".gitignore"}:
            continue

        checked += 1
        raw = path.read_bytes()
        relative = path.relative_to(ROOT).as_posix()

        for bom, label in BOMS.items():
            if raw.startswith(bom):
                problems.append(f"{relative}: starts with a {label}")
                break
        else:
            try:
                raw.decode("utf-8")
            except UnicodeDecodeError as error:
                line = raw.count(b"\n", 0, error.start) + 1
                context = raw[max(0, error.start - 40):error.start]
                problems.append(
                    f"{relative}:{line}: invalid UTF-8 at byte {error.start} "
                    f"({raw[error.start:error.end].hex()}) "
                    f"after {context.decode('ascii', 'backslashreplace')!r}"
                )

    print(f"\n  {checked} text files checked")
    print()
    print("=" * 72)
    if problems:
        print(f"RESULT: FAIL  ({len(problems)} file(s))")
        for problem in problems:
            print(f"  - {problem}")
        print()
        print("  Fix with an editor or Python, not PowerShell Set-Content:")
        print("    python -c \"p='path';import pathlib;"
              "pathlib.Path(p).write_text(pathlib.Path(p).read_text('gbk'),encoding='utf-8')\"")
        print("=" * 72)
        return 1
    print(f"RESULT: PASS  (all {checked} files are UTF-8, no BOM)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
