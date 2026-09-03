"""
Assert every bundle in the repo declares the keys it needs to install.

Why this exists
---------------
`xcodebuild build` succeeded for all six targets while three of the four watch
apps could not be installed on a simulator. Kairos, Awqat and Verba point at a
hand-written `INFOPLIST_FILE`; Tactus uses XcodeGen's `info:` block. XcodeGen
synthesises the identity keys — CFBundleIdentifier and friends — into a plist it
generates, and does not touch one you wrote yourself. Xcode does not add them
either. So three app bundles shipped with no CFBundleIdentifier at all.

Nothing reported this. The build was green, `swift test` was green, and the
failure only appeared when something tried to *install* the result. The one app
that worked was the one written differently, which is the only reason the
difference was visible at all.

That is worth a static check, because the simulator smoke test only covers the
four watch apps. The two iPhone apps and the three complications are never
installed by CI, and had exactly the same hole.

What it checks
--------------
1. Every hand-written Info.plist declares the identity keys.
2. Every `$(SETTING)` a plist interpolates is either an Xcode built-in or is
   actually defined in that project's settings. `$(MARKETING_VERSION)` silently
   becomes an empty CFBundleShortVersionString if nobody defines it, and an
   empty version string is an App Store rejection, not a build error.
3. `WKCompanionAppBundleIdentifier` names a real iOS target in the same
   project. A bundle-id rename that misses this leaves a watch app pointing at
   a phone app that does not exist.
4. A watch-only app sets `WKWatchOnly` and has no companion identifier; a
   paired app has a companion identifier and no `WKWatchOnly`.
5. No placeholder identifiers survive anywhere.

Run:  python tools/check_infoplists.py
"""

from __future__ import annotations

import pathlib
import plistlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Keys Xcode puts in a generated Info.plist and leaves out of a hand-written
# one. CFBundleIdentifier is the one that actually breaks installation; the
# rest are required for submission.
IDENTITY_KEYS = (
    "CFBundleIdentifier",
    "CFBundleExecutable",
    "CFBundleName",
    "CFBundlePackageType",
    "CFBundleInfoDictionaryVersion",
    "CFBundleShortVersionString",
    "CFBundleVersion",
)

# Provided by Xcode itself, so absence from project.yml is not a mistake.
XCODE_BUILTINS = {
    "PRODUCT_BUNDLE_IDENTIFIER",
    "PRODUCT_BUNDLE_PACKAGE_TYPE",
    "PRODUCT_NAME",
    "EXECUTABLE_NAME",
    "DEVELOPMENT_LANGUAGE",
}

PLACEHOLDERS = ("com.example", "com.yourcompany", "YOUR_TEAM", "CHANGEME")

INTERPOLATION = re.compile(r"\$\(([A-Z_][A-Z0-9_]*)\)")

APP_TYPES = {"application"}


class Report:
    def __init__(self) -> None:
        self.passed = 0
        self.failures: list[str] = []

    def check(self, condition: bool, label: str) -> bool:
        if condition:
            self.passed += 1
            print(f"  ok    {label}")
        else:
            self.failures.append(label)
            print(f"  FAIL  {label}")
        return condition


def interpolations(value: object) -> set[str]:
    """Every $(SETTING) appearing anywhere inside a plist value."""
    if isinstance(value, str):
        return set(INTERPOLATION.findall(value))
    if isinstance(value, dict):
        return set().union(*(interpolations(v) for v in value.values())) if value else set()
    if isinstance(value, list):
        return set().union(*(interpolations(v) for v in value)) if value else set()
    return set()


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")

    report = Report()

    for spec_path in sorted(ROOT.glob("apps/*/project.yml")):
        app_dir = spec_path.parent
        spec = yaml.safe_load(spec_path.read_text(encoding="utf-8"))
        targets = spec.get("targets", {})

        print()
        print("=" * 72)
        print(spec_path.relative_to(ROOT).as_posix())
        print("=" * 72)

        project_settings = set(spec.get("settings", {}).get("base", {}))

        # Bundle id of every iOS application, for the companion cross-check.
        ios_app_ids = {
            t.get("settings", {}).get("base", {}).get("PRODUCT_BUNDLE_IDENTIFIER")
            for t in targets.values()
            if t.get("type") in APP_TYPES and t.get("platform") == "iOS"
        }

        for name, target in targets.items():
            base = target.get("settings", {}).get("base", {})
            generated = target.get("info")
            declared_id = base.get("PRODUCT_BUNDLE_IDENTIFIER")

            if generated:
                # XcodeGen writes the identity keys itself; check the rest.
                properties = generated.get("properties", {})
                source = f"{name} (generated)"
            elif "INFOPLIST_FILE" in base:
                plist_path = app_dir / base["INFOPLIST_FILE"]
                if not report.check(plist_path.exists(),
                                    f"{name}: {base['INFOPLIST_FILE']} exists"):
                    continue
                properties = plistlib.loads(plist_path.read_bytes())
                source = f"{name} ({base['INFOPLIST_FILE']})"
                missing = [k for k in IDENTITY_KEYS if k not in properties]
                report.check(
                    not missing,
                    f"{source}: declares identity keys"
                    + (f" — missing {', '.join(missing)}" if missing else ""),
                )
            else:
                # Test bundles get theirs from Xcode's defaults.
                continue

            # 2. Interpolations resolve to something.
            used = interpolations(properties)
            unresolved = sorted(
                s for s in used
                if s not in XCODE_BUILTINS
                and s not in project_settings
                and s not in base
            )
            report.check(
                not unresolved,
                f"{source}: interpolated settings are defined"
                + (f" — {', '.join(unresolved)} undefined" if unresolved else ""),
            )

            # 3/4. Companion wiring is coherent.
            companion = properties.get("WKCompanionAppBundleIdentifier")
            watch_only = properties.get("WKWatchOnly", False)
            if target.get("platform") == "watchOS" and target.get("type") in APP_TYPES:
                if watch_only:
                    report.check(
                        companion is None,
                        f"{source}: watch-only app declares no companion",
                    )
                else:
                    report.check(
                        companion in ios_app_ids,
                        f"{source}: companion {companion!r} is a real iOS target"
                        + (f" — have {sorted(i for i in ios_app_ids if i)}"
                           if companion not in ios_app_ids else ""),
                    )

            # 5. No placeholders.
            blob = repr(properties) + repr(declared_id)
            found = [p for p in PLACEHOLDERS if p in blob]
            report.check(
                not found,
                f"{source}: no placeholder identifiers"
                + (f" — found {', '.join(found)}" if found else ""),
            )

    print()
    print("=" * 72)
    if report.failures:
        print(f"RESULT: FAIL  ({len(report.failures)} of "
              f"{report.passed + len(report.failures)} checks)")
        for failure in report.failures:
            print(f"  - {failure}")
        print("=" * 72)
        return 1
    print(f"RESULT: PASS  ({report.passed} checks)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
