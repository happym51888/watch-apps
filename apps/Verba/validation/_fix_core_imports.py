"""
Remove `import <App>Core` from the app-layer sources.

Each project.yml compiles Sources/<App>Core straight into the app and watch
targets, so there is no separate <App>Core module for Xcode to import and every
one of these files failed with "no such module". Package.swift still builds the
core as a real module, which is what `swift test` uses, so the tests keep
working unchanged.
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
PATTERN = re.compile(r"^import (?:Kairos|Tactus|Awqat|Verba)Core[ \t]*\r?\n", re.M)

changed = []
for path in sorted(ROOT.rglob("*.swift")):
    # Leave the core itself and the tests alone; the tests import it properly
    # through SwiftPM.
    parts = path.parts
    if "Sources" in parts or "Tests" in parts:
        continue
    text = path.read_text(encoding="utf-8")
    stripped = PATTERN.sub("", text)
    if stripped != text:
        path.write_text(stripped, encoding="utf-8", newline="")
        changed.append(path.relative_to(ROOT))

print(f"stripped the core import from {len(changed)} files")
for rel in changed:
    print(f"  {rel}")

leftover = [
    path.relative_to(ROOT)
    for path in ROOT.rglob("*.swift")
    if "Sources" not in path.parts
    and "Tests" not in path.parts
    and PATTERN.search(path.read_text(encoding="utf-8"))
]
print("remaining:", leftover or "none")
