"""
Check every PrivacyInfo.xcprivacy parses and says something coherent.

A malformed privacy manifest is not a build error. Xcode copies the file into
the bundle either way, and the first sign of trouble is an email from App Store
Connect after upload. Same failure shape as everything else verified in this
repo: no error, wrong result.

Beyond parsing, this asserts the declarations match what the code actually
does — the required-reason API list is derived from grepping the sources, so a
new UserDefaults or file-attribute call in an app that has not declared it
gets caught here rather than at submission.

Run:  python tools/check_privacy_manifests.py
"""

from __future__ import annotations

import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APPS = ["Kairos", "Tactus", "Awqat", "Verba"]

# Required-reason API categories, mapped to the source patterns that trigger
# them. Only the categories these apps could plausibly touch.
TRIGGERS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": [r"\bUserDefaults\b"],
    "NSPrivacyAccessedAPICategoryFileTimestamp": [
        r"attributesOfItem",
        r"\.creationDate\b",
        r"contentModificationDate",
    ],
    "NSPrivacyAccessedAPICategoryDiskSpace": [
        r"volumeAvailableCapacity",
        r"systemFreeSize",
    ],
    "NSPrivacyAccessedAPICategorySystemBootTime": [
        r"systemUptime",
        r"mach_absolute_time",
    ],
}

VALID_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
}

failures: list[str] = []
checks = 0


def check(condition: bool, label: str, detail: str = "") -> None:
    global checks
    checks += 1
    if condition:
        print(f"  ok    {label}")
    else:
        print(f"  FAIL  {label}{(' — ' + detail) if detail else ''}")
        failures.append(label)


BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT = re.compile(r"//[^\n]*")


def strip_comments(source: str) -> str:
    """Drop comments before looking for API usage.

    Without this, a comment explaining *why* an app avoids UserDefaults counts
    as using it. Kairos has exactly that comment, and it made this check demand
    a declaration for an API the app never calls — which would have put a false
    entry in the privacy manifest.
    """
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub("", source))


def swift_sources(app: str) -> str:
    root = ROOT / "apps" / app
    text = []
    for path in root.rglob("*.swift"):
        if "Tests" in path.parts:
            continue
        text.append(strip_comments(path.read_text(encoding="utf-8", errors="replace")))
    return "\n".join(text)


def main() -> int:
    print("=" * 72)
    print("Privacy manifests")
    print("=" * 72)

    for app in APPS:
        print(f"\n{app}")
        print("-" * len(app))

        path = ROOT / "apps" / app / "Resources" / "PrivacyInfo.xcprivacy"
        if not path.exists():
            check(False, "PrivacyInfo.xcprivacy exists", str(path))
            continue

        try:
            manifest = plistlib.loads(path.read_bytes())
        except Exception as error:  # noqa: BLE001
            check(False, "parses as a plist", str(error))
            continue
        check(True, "parses as a plist")

        for key in (
            "NSPrivacyTracking",
            "NSPrivacyTrackingDomains",
            "NSPrivacyCollectedDataTypes",
            "NSPrivacyAccessedAPITypes",
        ):
            check(key in manifest, f"declares {key}")

        tracking = manifest.get("NSPrivacyTracking")
        domains = manifest.get("NSPrivacyTrackingDomains", [])
        check(tracking is False, "tracking is off")
        # Declaring tracking domains while tracking is off is contradictory and
        # App Store Connect rejects the combination.
        check(
            not (tracking is False and domains),
            "no tracking domains alongside tracking = false",
        )

        declared = {
            entry["NSPrivacyAccessedAPIType"]: set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
            for entry in manifest.get("NSPrivacyAccessedAPITypes", [])
        }

        for category, reasons in declared.items():
            check(bool(reasons), f"{category.replace('NSPrivacyAccessedAPICategory', '')} gives a reason")
            allowed = VALID_REASONS.get(category)
            if allowed:
                unknown = reasons - allowed
                check(not unknown, f"its reason codes are real", f"unknown: {unknown}")

        sources = swift_sources(app)
        for category, patterns in TRIGGERS.items():
            used = any(re.search(pattern, sources) for pattern in patterns)
            short = category.replace("NSPrivacyAccessedAPICategory", "")
            if used:
                check(category in declared, f"uses {short} and declares it")
            else:
                check(
                    category not in declared,
                    f"does not declare {short} it never uses",
                )

        for entry in manifest.get("NSPrivacyCollectedDataTypes", []):
            name = entry.get("NSPrivacyCollectedDataType", "?")
            short = name.replace("NSPrivacyCollectedDataType", "")
            check(
                entry.get("NSPrivacyCollectedDataTypeTracking") is False,
                f"{short} is not marked as used for tracking",
            )
            check(
                bool(entry.get("NSPrivacyCollectedDataTypePurposes")),
                f"{short} states a purpose",
            )

        icon = ROOT / "apps" / app / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png"
        check(icon.exists(), "the 1024 app icon exists", str(icon))
        if icon.exists():
            header = icon.read_bytes()[:26]
            width = int.from_bytes(header[16:20], "big")
            height = int.from_bytes(header[20:24], "big")
            colour_type = header[25]
            check((width, height) == (1024, 1024), "the icon is 1024x1024", f"{width}x{height}")
            # Colour type 2 is truecolour without alpha. Apple rejects an alpha
            # channel in the marketing icon.
            check(colour_type == 2, "the icon has no alpha channel", f"PNG colour type {colour_type}")

    print()
    print("=" * 72)
    if failures:
        print(f"RESULT: FAIL  ({len(failures)} of {checks} checks failed)")
        for failure in failures:
            print(f"  - {failure}")
        print("=" * 72)
        return 1
    print(f"RESULT: PASS  ({checks} checks)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
