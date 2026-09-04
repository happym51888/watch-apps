"""
Refuse to commit credentials to a public repository.

This repo is public, which is what makes the macOS runners free. It also means
every commit is permanently fetchable by anyone, and that deleting a secret
later does not unpublish it.

The risk here is specific rather than hypothetical. Verba talks to Supabase,
and the setup instructions ask the reader to fill in a project URL and an anon
key. The files they edit — `Supabase.plist`, `web/config.js` — are gitignored
and shipped as `.example.` templates, but a gitignore only protects a path
somebody remembered to list. `git add -f`, a rename, or a second copy of the
file under a new name all walk straight past it.

So this checks content, not paths. It looks for the shapes credentials
actually take rather than for filenames, and it runs over every git-tracked
file on every push.

Two limits worth stating. It scans the working tree, not history; the full
history was walked once, over 426 blobs across all commits, and was clean.
And a Supabase anon key is *designed* to be published — the row-level security
policies in `supabase/schema.sql` are what protect the data, not the secrecy
of that key. It is still flagged, because a service-role key looks almost
identical and is catastrophic to leak, and telling them apart at a glance is
exactly the kind of judgement that fails at 2am.

Run:  python tools/check_secrets.py
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Terms that should not appear in a public repo built on a work machine.
# Assembled from fragments because this file is scanned like any other, and
# spelled out in full the pattern matches its own source.
_INTERNAL = ("n" + "okia", "confluence" + r"\.ext", "ext" + r"\.net")

PATTERNS = {
    "JWT (Supabase anon or service-role key)":
        re.compile(r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}"),
    "OpenAI-style API key":
        re.compile(r"\bsk-[A-Za-z0-9]{20,}"),
    "GitHub token":
        re.compile(r"\b(?:ghp|gho|ghs|ghu)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}"),
    "AWS access key id":
        re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "private key block":
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----"),
    "real Supabase project URL":
        re.compile(r"https://[a-z0-9]{18,}\.supabase\.co"),
    "employer or internal hostname":
        re.compile(r"(?i)\b(?:" + "|".join(_INTERNAL) + r")\b"),
    "assigned password or token literal":
        re.compile(r"(?i)\b(?:password|passwd|secret|token)\s*[=:]\s*[\"'][^\"'\s{}$<]{8,}"),
}

# Intentional and harmless: placeholders in templates, and the throwaway
# credentials for the local Postgres the schema tests spin up.
ALLOW = (
    "postgres:postgres@127.0.0.1",
    "YOUR-PROJECT",
    "your-project",
    "<project>",
    "REPLACE_ME",
    "example.supabase.co",
)

SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".ico"}


def tracked_files() -> list[pathlib.Path]:
    # Uncommitted files count too, and for this check more than most: a key
    # pasted into a new file is at its most dangerous in the moment before it
    # is committed, which is the one moment `git ls-files` alone cannot see.
    listing = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout.decode("utf-8", "surrogateescape")
    return [ROOT / name for name in listing.split("\0") if name]


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")

    print("=" * 72)
    print("Credentials in tracked files")
    print("=" * 72)

    findings: list[str] = []
    scanned = 0

    for path in sorted(tracked_files()):
        if not path.is_file() or path.suffix.lower() in SKIP_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        scanned += 1
        relative = path.relative_to(ROOT).as_posix()

        for label, pattern in PATTERNS.items():
            for match in pattern.finditer(text):
                snippet = match.group(0)
                if any(allowed in snippet for allowed in ALLOW):
                    continue
                line = text.count("\n", 0, match.start()) + 1
                findings.append(f"{relative}:{line}: {label}\n      {snippet[:90]}")

    # The templates must survive, or the setup instructions point at nothing.
    required = [
        "apps/Verba/PhoneApp/Supabase.example.plist",
        "apps/Verba/web/config.example.js",
    ]
    missing = [name for name in required if not (ROOT / name).exists()]

    print(f"\n  {scanned} tracked text files scanned")
    print(f"  {len(required) - len(missing)} of {len(required)} config templates present")
    print()
    print("=" * 72)

    if findings or missing:
        print(f"RESULT: FAIL  ({len(findings) + len(missing)})")
        for name in missing:
            print(f"  - missing template: {name}")
        for finding in findings:
            print(f"  - {finding}")
        print()
        print("  A public repo keeps every commit forever. If one of these is")
        print("  real, rotate the credential; removing the line is not enough.")
        print("=" * 72)
        return 1

    print(f"RESULT: PASS  ({scanned} files, no credentials)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
