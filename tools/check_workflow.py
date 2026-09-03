"""
Validate the CI workflow, and assert that it can still fail.

The second part is the point. `continue-on-error: true` was set on the build
and test steps during bring-up so that one run would surface every app's
errors instead of stopping at the first. It worked, and then it quietly turned
CI into theatre: run 5 reported 11 of 11 jobs green while two of the six builds
were failing. A gate that cannot fail is not a gate.

So this refuses any `continue-on-error` in the workflow. If it is ever needed
again, it should be added deliberately and this check updated with a reason,
rather than left behind after a debugging session.

Run:  python tools/check_workflow.py
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "build.yml"

SCRIPT = re.compile(r"python3?\s+((?:tools|apps)/[\w./-]+\.py)")
IMPORT = re.compile(r"^\s*(?:import|from)\s+(\w+)", re.MULTILINE)
PIP = re.compile(r"pip\s+install\s+(?:--\S+\s+)*(.+)")

# Modules the validators may import that are not in the standard library.
THIRD_PARTY = {"yaml", "psycopg", "psycopg2", "requests", "PIL"}

# pip name -> module name, where they differ.
DISTRIBUTIONS = {
    "pyyaml": {"yaml"},
    "psycopg[binary]": {"psycopg"},
    "psycopg2-binary": {"psycopg2"},
    "pillow": {"PIL"},
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


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")

    print("=" * 72)
    print("CI workflow")
    print("=" * 72)
    print()

    try:
        # `on:` parses as the boolean True in YAML 1.1, which is a well-known
        # GitHub Actions quirk and harmless here.
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    except Exception as error:  # noqa: BLE001
        print(f"  FAIL  the workflow parses as YAML — {error}")
        return 1
    check(True, "the workflow parses as YAML")

    jobs = workflow.get("jobs", {})
    check(bool(jobs), "it defines jobs")

    offenders: list[str] = []
    for job_name, job in jobs.items():
        if job.get("continue-on-error"):
            offenders.append(f"job {job_name}")
        for step in job.get("steps", []) or []:
            if isinstance(step, dict) and step.get("continue-on-error"):
                offenders.append(f"{job_name} → {step.get('name', step.get('uses', '?'))}")

    check(
        not offenders,
        "no continue-on-error anywhere",
        "; ".join(offenders) + " — a job that cannot fail reports success while broken",
    )

    # Every job that produces evidence should hand it back even when it fails,
    # otherwise a red run tells you nothing about why.
    for job_name, job in jobs.items():
        uploads = [
            step
            for step in (job.get("steps", []) or [])
            if isinstance(step, dict) and str(step.get("uses", "")).startswith("actions/upload-artifact")
        ]
        for step in uploads:
            check(
                step.get("if") == "always()",
                f"{job_name}: artifacts upload even on failure",
                f"if: {step.get('if')!r}",
            )

    # Every script the workflow names must exist. A rename that misses the
    # workflow fails four minutes into a run instead of here.
    for job_name, job in jobs.items():
        for step in job.get("steps", []) or []:
            if not isinstance(step, dict):
                continue
            for match in SCRIPT.finditer(str(step.get("run", ""))):
                script = match.group(1)
                check(
                    (ROOT / script).exists(),
                    f"{job_name}: {script} exists",
                )

    # A step that imports a third-party module must come after the step that
    # installs it. check_infoplists.py imported yaml one step before the pip
    # install that had always been buried in a later step, and the job died on
    # ModuleNotFoundError with every actual check passing.
    for job_name, job in jobs.items():
        installed: set[str] = set()
        for step in job.get("steps", []) or []:
            if not isinstance(step, dict):
                continue
            run = str(step.get("run", ""))
            for match in SCRIPT.finditer(run):
                path = ROOT / match.group(1)
                if not path.exists():
                    continue
                needed = THIRD_PARTY & set(
                    IMPORT.findall(path.read_text(encoding="utf-8"))
                )
                unmet = sorted(needed - installed)
                check(
                    not unmet,
                    f"{job_name}: {match.group(1)} has its imports installed",
                    f"needs {', '.join(unmet)} installed by an earlier step",
                )
            for spec in PIP.findall(run):
                for token in spec.split():
                    # e.g. "psycopg[binary]" -> psycopg; pyyaml -> yaml
                    name = token.strip("\"'").lower().split("[")[0]
                    installed.add(name)
                    installed.update(DISTRIBUTIONS.get(name, set()))
                    installed.update(
                        DISTRIBUTIONS.get(token.strip("\"'").lower(), set())
                    )

    expected = {
        "validate-logic",
        "postgres-schema",
        "swift-tests",
        "watch-build",
        "simulator-smoke",
    }
    missing = expected - set(jobs)
    check(not missing, "all expected jobs are present", f"missing: {missing}")

    print()
    print("  jobs:")
    for job_name, job in jobs.items():
        matrix = (job.get("strategy") or {}).get("matrix") or {}
        if "include" in matrix:
            count = len(matrix["include"])
        elif "app" in matrix:
            count = len(matrix["app"])
        else:
            count = 1
        needs = job.get("needs", "-")
        print(f"    {job_name:18} {job['runs-on']:12} x{count:<3} needs={needs}")

    print()
    print("=" * 72)
    if failures:
        print(f"RESULT: FAIL  ({len(failures)} of {checks} checks failed)")
        print("=" * 72)
        return 1
    print(f"RESULT: PASS  ({checks} checks)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
