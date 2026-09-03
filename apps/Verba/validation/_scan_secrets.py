"""Pre-publication scan. Nothing in this tree should carry a credential."""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[3]

PATTERNS = {
    "JWT / Supabase key": re.compile(r"eyJ[A-Za-z0-9_-]{20,}"),
    "OpenAI key": re.compile(r"sk-[A-Za-z0-9]{20,}"),
    "GitHub token": re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    "private key block": re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
    "real Supabase project": re.compile(r"https://[a-z0-9]{15,}\.supabase\.co"),
    "AWS access key": re.compile(r"AKIA[0-9A-Z]{16}"),
    "corporate domain login": re.compile(r"[A-Z]{3,}-[A-Z]{3,}\\\\?\w+"),
    "hardcoded password": re.compile(r"""password\s*[:=]\s*["'][^"'\s]{6,}["']""", re.I),
}

SKIP_DIRS = {".git", ".build", "DerivedData", "node_modules"}

hits = []
scanned = 0

for path in ROOT.rglob("*"):
    if not path.is_file():
        continue
    if any(part in SKIP_DIRS for part in path.parts):
        continue
    if path.name.startswith("_scan_secrets"):
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    scanned += 1
    for label, pattern in PATTERNS.items():
        for match in pattern.finditer(text):
            line = text[: match.start()].count("\n") + 1
            hits.append((label, path.relative_to(ROOT), line, match.group(0)[:60]))

print(f"scanned {scanned} text files under {ROOT.name}")
if hits:
    print(f"\n{len(hits)} POSSIBLE SECRET(S) — review before publishing:\n")
    for label, rel, line, snippet in hits:
        print(f"  [{label}] {rel}:{line}\n      {snippet}")
    raise SystemExit(1)
print("no credentials, tokens, private keys or corporate logins found")
