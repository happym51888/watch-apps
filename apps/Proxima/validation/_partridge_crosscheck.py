"""A second, unrelated GTFS reader over the same committed fixture.

Deliberately not part of CI. The Entur replay in `verify_gtfs.py` validates the
*answers*, which subsumes most of this; and partridge pulls in pandas, numpy
and networkx, which is a lot of runner to buy a check that is mostly redundant.
It is committed because it is cheap to run by hand and because of what it found
about `stops.txt` — see below.

    .venv/Scripts/python.exe apps/Proxima/validation/_partridge_crosscheck.py
"""
from __future__ import annotations

import pathlib
import sys

import partridge as ptg

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from gtfs_engine import load_feed  # noqa: E402

FIXTURE = HERE / "fixtures" / "ruter-slice.zip"

mine = load_feed(FIXTURE)
theirs = ptg.load_feed(str(FIXTURE))

failures: list[str] = []


def compare(label: str, a, b) -> None:
    ok = a == b
    print(f"  {'ok  ' if ok else 'FAIL'}  {label}: mine={a} partridge={b}")
    if not ok:
        failures.append(label)


def check(condition: bool, label: str, detail: str = "") -> None:
    print(f"  {'ok  ' if condition else 'FAIL'}  {label}" + (f"  — {detail}" if detail else ""))
    if not condition:
        failures.append(label)


print("=== two readers over the same fixture ===")
compare("trips", len(mine.trips), len(theirs.trips))
compare("routes", len(mine.routes), len(theirs.routes))
compare(
    "stop_time rows",
    sum(len(v) for v in mine.stop_times.values()),
    len(theirs.stop_times),
)
compare("calendar_dates rows", len(mine.exceptions), len(theirs.calendar_dates))

print("\n=== the same trip, row by row ===")
sample = sorted(mine.stop_times)[0]
ours = mine.stop_times[sample]
rows = theirs.stop_times[theirs.stop_times.trip_id == sample].sort_values("stop_sequence")
compare(f"rows in trip {sample[:32]}…", len(ours), len(rows))
compare("departure seconds", [st.departure for st in ours], [int(v) for v in rows.departure_time])
compare("stop ids", [st.stop_id for st in ours], rows.stop_id.tolist())

# ---------------------------------------------------------------------------
# The one place the two readers disagree, and it is not a disagreement about
# the file. `stops.txt` holds 74 rows: 42 quays and 32 stations. partridge
# prunes to the 42 that `stop_times.txt` references, because a station never
# appears in stop_times — a bus calls at a platform, not at a building.
#
# Those 32 rows are the entire basis of hazard H10, "asking about a station
# asks about its platforms". Loading the pruned view would leave the app unable
# to answer for any station at all, which is the shape of stop a person
# actually names. So this is the third-party tool being sensibly lossy for its
# own purpose, and the engine being right to keep them.
# ---------------------------------------------------------------------------
print("\n=== stops: where they part, and why ===")
stations = [s for s in mine.stops.values() if s.location_type == 1]
quays = [s for s in mine.stops.values() if s.location_type != 1]
check(len(mine.stops) == 74, "the engine keeps every row in stops.txt", f"{len(mine.stops)}")
check(len(quays) == 42, "42 of them are quays", f"{len(quays)}")
check(len(stations) == 32, "32 are stations, referenced by no stop_time", f"{len(stations)}")
check(len(theirs.stops) == 42, "partridge prunes to the quays", f"{len(theirs.stops)}")
check(
    {s.stop_id for s in quays} == set(theirs.stops.stop_id),
    "and the two agree exactly on the quays, so nothing is invented",
)

expanded = mine.expand_stops([stations[0].stop_id])
check(
    len(expanded) > 1 and stations[0].stop_id not in set(theirs.stops.stop_id),
    "a station the engine can expand is absent from the pruned view",
    f"{stations[0].stop_id} → {len(expanded)} quays",
)

print()
if failures:
    print(f"RESULT: FAIL  ({len(failures)})")
    for name in failures:
        print(f"  - {name}")
else:
    print("RESULT: PASS  (two readers, one fixture, one explained difference)")
sys.exit(1 if failures else 0)
