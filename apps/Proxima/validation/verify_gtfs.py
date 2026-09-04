#!/usr/bin/env python3
"""
Executable check of ProximaCore's departure engine.

The Swift in this repo cannot be compiled on the machine it was written on, so
the logic is ported to `gtfs_engine.py` and run against an external reference:

  * fixtures/ruter-slice.zip     real rows from Ruter's published GTFS feed
  * fixtures/entur-expected.json what Entur's own journey planner answers

The second file is the point. Entur resolves departures from NeTEx and never
reads the GTFS feed under test, so a shared misreading of the GTFS spec cannot
cancel out. When the engine and Entur agree on an instant, two independent
paths from two data formats produced the same wall-clock time.

Structure:

  1. spec units      parse_gtfs_time, parse_gtfs_date, service-day origin
  2. fixture shape   what the committed slice actually contains
  3. oracle replay   every departure instant Entur reported, re-checked
  4. properties      ordering, dedupe, horizon, limit, station aggregation
  5. mutations       each hazard reintroduced on purpose, to prove the oracle
                     notices; a check that cannot fail is not a check

  python validation/verify_gtfs.py
"""

from __future__ import annotations

import datetime as dt
import io
import json
import pathlib
import sys
import zipfile
from contextlib import contextmanager
from zoneinfo import ZoneInfo

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import gtfs_engine  # noqa: E402
from gtfs_engine import (  # noqa: E402
    ADDED,
    Feed,
    FeedError,
    ServiceWindow,
    StopTime,
    load_feed,
    next_departures,
    parse_gtfs_date,
    parse_gtfs_time,
)

UTC = dt.timezone.utc
FIXTURES = HERE / "fixtures"
SLICE = FIXTURES / "ruter-slice.zip"
EXPECTED = FIXTURES / "entur-expected.json"

FAILURES: list[str] = []
ASSERTIONS = 0


def check(condition: bool, message: str) -> bool:
    global ASSERTIONS
    ASSERTIONS += 1
    if not condition:
        FAILURES.append(message)
    return bool(condition)


def equal(actual: object, expected: object, message: str) -> bool:
    return check(actual == expected, f"{message}: got {actual!r}, expected {expected!r}")


def raises(fn, message: str) -> bool:
    try:
        fn()
    except FeedError:
        return check(True, message)
    except Exception as exc:  # noqa: BLE001
        return check(False, f"{message}: raised {type(exc).__name__} instead of FeedError")
    return check(False, f"{message}: did not raise")


# ---------------------------------------------------------------------------
# 1. Spec units
# ---------------------------------------------------------------------------


def spec_units() -> None:
    print("=== GTFS time and date parsing ===")
    equal(parse_gtfs_time("00:00:00"), 0, "midnight")
    equal(parse_gtfs_time("08:14:00"), 8 * 3600 + 14 * 60, "ordinary morning time")
    equal(parse_gtfs_time("23:59:59"), 86399, "last second before midnight")
    # H2. The whole point: hours are not a clock, they are an offset into the
    # service day, and they keep counting past 24.
    equal(parse_gtfs_time("24:00:00"), 86400, "24:00:00 is the next midnight")
    equal(parse_gtfs_time("25:30:00"), 91800, "25:30:00 is 01:30 the next day")
    equal(parse_gtfs_time("26:23:00"), 26 * 3600 + 23 * 60, "the latest time in the real BART feed")
    equal(parse_gtfs_time("  8:05:00 "), 8 * 3600 + 5 * 60, "single-digit hour with padding")
    equal(parse_gtfs_time(""), None, "blank time is absent, not zero")
    equal(parse_gtfs_time("   "), None, "whitespace time is absent, not zero")

    raises(lambda: parse_gtfs_time("08:05"), "two-part time is rejected")
    raises(lambda: parse_gtfs_time("08:60:00"), "minute 60 is rejected")
    raises(lambda: parse_gtfs_time("08:05:60"), "second 60 is rejected")
    raises(lambda: parse_gtfs_time("-1:00:00"), "negative hour is rejected")
    raises(lambda: parse_gtfs_time("ab:cd:ef"), "non-numeric time is rejected")

    equal(parse_gtfs_date("20261025"), dt.date(2026, 10, 25), "GTFS date")
    raises(lambda: parse_gtfs_date("2026-10-25"), "dashed date is rejected")
    raises(lambda: parse_gtfs_date("202610"), "short date is rejected")

    print("=== service day origin, against IANA tzdata ===")
    # H1. GTFS: times are measured from "noon minus 12h", which equals midnight
    # except on the days the UTC offset moves. Compared here against tzdata
    # rather than against intuition, because the naive version is wrong by
    # exactly one hour and never raises.
    for zone, spring, fall in (
        ("Europe/Oslo", dt.date(2026, 3, 29), dt.date(2026, 10, 25)),
        ("America/Los_Angeles", dt.date(2026, 3, 8), dt.date(2026, 11, 1)),
        ("Australia/Sydney", dt.date(2026, 10, 4), dt.date(2026, 4, 5)),
    ):
        tz = ZoneInfo(zone)
        feed = Feed(timezone=tz, agency_name="t", stops={}, routes={}, trips={})

        def origin(day: dt.date) -> dt.datetime:
            return feed.service_day_origin(day)

        def midnight(day: dt.date) -> dt.datetime:
            return dt.datetime(day.year, day.month, day.day, tzinfo=tz).astimezone(UTC)

        ordinary = dt.date(2026, 6, 17)
        equal(origin(ordinary), midnight(ordinary), f"{zone}: ordinary day origin is midnight")

        for day, label in ((spring, "spring forward"), (fall, "fall back")):
            delta = (origin(day) - midnight(day)).total_seconds()
            check(
                abs(delta) == 3600,
                f"{zone} {day} ({label}): origin should differ from midnight by an hour, got {delta}s",
            )
            # A trip printed as 08:14 must still read 08:14 locally.
            shown = (origin(day) + dt.timedelta(seconds=8 * 3600 + 14 * 60)).astimezone(tz)
            equal(
                (shown.hour, shown.minute),
                (8, 14),
                f"{zone} {day}: a trip timed 08:14 shows as 08:14 local",
            )
            naive = (midnight(day) + dt.timedelta(seconds=8 * 3600 + 14 * 60)).astimezone(tz)
            check(
                (naive.hour, naive.minute) != (8, 14),
                f"{zone} {day}: the naive origin should have been wrong here, but agreed",
            )

    print("=== inclusive calendar bounds ===")
    # H4. Both ends inclusive.
    window = ServiceWindow(
        service_id="s",
        days=(True,) * 7,
        start=dt.date(2026, 9, 1),
        end=dt.date(2026, 9, 30),
    )
    check(window.covers(dt.date(2026, 9, 1)), "start_date is inside the window")
    check(window.covers(dt.date(2026, 9, 30)), "end_date is inside the window")
    check(not window.covers(dt.date(2026, 8, 31)), "the day before start is outside")
    check(not window.covers(dt.date(2026, 10, 1)), "the day after end is outside")

    weekdays = ServiceWindow(
        service_id="w",
        days=(True, True, True, True, True, False, False),
        start=dt.date(2026, 9, 1),
        end=dt.date(2026, 9, 30),
    )
    check(weekdays.covers(dt.date(2026, 9, 7)), "Monday runs on a weekday service")
    check(not weekdays.covers(dt.date(2026, 9, 5)), "Saturday does not run on a weekday service")


# ---------------------------------------------------------------------------
# 1b. Hand-built feeds for the hazards the real fixture cannot isolate
# ---------------------------------------------------------------------------


def synthetic_feed(files: dict[str, str]) -> Feed:
    """Assemble a GTFS zip in memory from literal CSV text."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, text in files.items():
            zf.writestr(name, text)
    buf.seek(0)
    return load_feed(zipfile.ZipFile(buf))


BASE_AGENCY = "agency_id,agency_name,agency_url,agency_timezone\nA,Test,https://x,Europe/Oslo\n"
BASE_ROUTES = "route_id,route_short_name,route_long_name,route_type\nR,7,Long,3\n"


def synthetic_units() -> None:
    """Checks driven by the spec text rather than by Entur.

    Three hazards cannot be separated on the committed Ruter slice, and saying
    "verified" about them on the strength of that fixture would be a lie:

      H6  Ruter marks every terminal arrival pickup_type=1, so the "last stop
          is not a departure" rule never decides anything on its own there.
      H8  the slice has no blank departure_time at all, so interpolation never
          runs.
      H4  Ruter ships no calendar.txt, so inclusive date bounds never apply.

    These get hand-built feeds instead. That is weaker evidence than an
    agency's own answer and is labelled as such in the output.
    """
    print("=== hand-built feeds for what the fixture cannot reach ===")
    tz = ZoneInfo("Europe/Oslo")

    # H6. Three stops, boarding permitted everywhere, including the last stop.
    # The last stop must still not appear as a departure.
    feed = synthetic_feed(
        {
            "agency.txt": BASE_AGENCY,
            "routes.txt": BASE_ROUTES,
            "stops.txt": "stop_id,stop_name,location_type,parent_station\nS1,First,,\nS2,Middle,,\nS3,Last,,\n",
            "trips.txt": "trip_id,route_id,service_id,trip_headsign,direction_id\nT1,R,SVC,To Last,0\n",
            "calendar.txt": (
                "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
                "SVC,1,1,1,1,1,1,1,20260901,20260930\n"
            ),
            "stop_times.txt": (
                "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type\n"
                "T1,08:00:00,08:00:00,S1,1,0\n"
                "T1,08:10:00,08:10:00,S2,2,0\n"
                "T1,08:20:00,08:20:00,S3,3,0\n"
            ),
        }
    )
    at = dt.datetime(2026, 9, 7, 7, 0, tzinfo=tz)
    equal(
        [d.stop_id for d in next_departures(feed, ["S1", "S2", "S3"], at, limit=10)],
        ["S1", "S2"],
        "H6: the terminal stop is not offered as a departure even when boarding is allowed",
    )
    equal(
        next_departures(feed, ["S3"], at, limit=10),
        [],
        "H6: a board at the terminus shows nothing for a trip that ends there",
    )

    # And the terminus of one trip is a real departure for the next working.
    feed = synthetic_feed(
        {
            "agency.txt": BASE_AGENCY,
            "routes.txt": BASE_ROUTES,
            "stops.txt": "stop_id,stop_name,location_type,parent_station\nS1,First,,\nS3,End,,\n",
            "trips.txt": (
                "trip_id,route_id,service_id,trip_headsign,direction_id\n"
                "IN,R,SVC,To End,0\n"
                "OUT,R,SVC,To First,1\n"
            ),
            "calendar.txt": (
                "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
                "SVC,1,1,1,1,1,1,1,20260901,20260930\n"
            ),
            "stop_times.txt": (
                "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type\n"
                "IN,08:00:00,08:00:00,S1,1,0\n"
                "IN,08:20:00,08:20:00,S3,2,0\n"
                "OUT,08:25:00,08:25:00,S3,1,0\n"
                "OUT,08:45:00,08:45:00,S1,2,0\n"
            ),
        }
    )
    board = next_departures(feed, ["S3"], at, limit=10)
    equal(len(board), 1, "H6: the terminus shows only the return working")
    if board:
        equal(board[0].local(tz).strftime("%H:%M"), "08:25", "H6: and it is the return working's own time")

    # H8. Blank times at non-timepoint stops interpolate evenly.
    feed = synthetic_feed(
        {
            "agency.txt": BASE_AGENCY,
            "routes.txt": BASE_ROUTES,
            "stops.txt": (
                "stop_id,stop_name,location_type,parent_station\n"
                "A,A,,\nB,B,,\nC,C,,\nD,D,,\nE,E,,\n"
            ),
            "trips.txt": "trip_id,route_id,service_id,trip_headsign,direction_id\nT,R,SVC,To E,0\n",
            "calendar.txt": (
                "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
                "SVC,1,1,1,1,1,1,1,20260901,20260930\n"
            ),
            "stop_times.txt": (
                "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,timepoint\n"
                "T,08:00:00,08:00:00,A,1,0,1\n"
                "T,,,B,2,0,0\n"
                "T,,,C,3,0,0\n"
                "T,08:30:00,08:30:00,D,4,0,1\n"
                "T,08:40:00,08:40:00,E,5,0,1\n"
            ),
        }
    )
    board = {d.stop_id: d.local(tz).strftime("%H:%M") for d in next_departures(feed, list("ABCDE"), at, limit=10)}
    equal(board.get("A"), "08:00", "H8: timepoint before the gap is untouched")
    equal(board.get("B"), "08:10", "H8: first blank stop lands a third of the way")
    equal(board.get("C"), "08:20", "H8: second blank stop lands two thirds of the way")
    equal(board.get("D"), "08:30", "H8: timepoint after the gap is untouched")
    check("E" not in board, "H8: the terminal stop is still not a departure")

    # H9. A feed whose calendars have run out says so, rather than showing an
    # empty board that reads as "no more trains today".
    expired = synthetic_feed(
        {
            "agency.txt": BASE_AGENCY,
            "routes.txt": BASE_ROUTES,
            "stops.txt": "stop_id,stop_name,location_type,parent_station\nS1,First,,\nS2,Second,,\n",
            "trips.txt": "trip_id,route_id,service_id,trip_headsign,direction_id\nT,R,SVC,To Second,0\n",
            "calendar.txt": (
                "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
                "SVC,1,1,1,1,1,1,1,20260901,20260930\n"
            ),
            "stop_times.txt": (
                "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type\n"
                "T,08:00:00,08:00:00,S1,1,0\nT,08:20:00,08:20:00,S2,2,0\n"
            ),
        }
    )
    equal(expired.validity(dt.date(2026, 9, 15)), "current", "H9: inside the calendar span")
    equal(expired.validity(dt.date(2026, 10, 1)), "expired", "H9: past the last service date")
    equal(expired.validity(dt.date(2026, 8, 31)), "future", "H9: before the first service date")

    # H9 again: feed_info claiming a narrower window than the calendars is a
    # claim to flag, not to obey. The real BART feed does exactly this.
    lying = synthetic_feed(
        {
            "agency.txt": BASE_AGENCY,
            "routes.txt": BASE_ROUTES,
            "stops.txt": "stop_id,stop_name,location_type,parent_station\nS1,First,,\nS2,Second,,\n",
            "trips.txt": "trip_id,route_id,service_id,trip_headsign,direction_id\nT,R,SVC,To Second,0\n",
            "calendar.txt": (
                "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
                "SVC,1,1,1,1,1,1,1,20260901,20261231\n"
            ),
            "feed_info.txt": (
                "feed_publisher_name,feed_publisher_url,feed_lang,feed_start_date,feed_end_date\n"
                "T,https://x,en,20260101,20260830\n"
            ),
            "stop_times.txt": (
                "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type\n"
                "T,08:00:00,08:00:00,S1,1,0\nT,08:20:00,08:20:00,S2,2,0\n"
            ),
        }
    )
    check(lying.feed_info_disagrees(), "H9: feed_info narrower than the calendars is flagged")
    equal(
        lying.validity(dt.date(2026, 11, 1)),
        "current",
        "H9: the calendars decide, so a stale feed_info does not blank the board",
    )
    equal(
        next_departures(feed=lying, stop_ids=["S1"], now=dt.datetime(2026, 11, 2, 7, 0, tzinfo=tz), limit=3)[0]
        .local(tz)
        .strftime("%H:%M"),
        "08:00",
        "H9: and departures still come out on a date feed_info called expired",
    )

    # H2 end to end on a hand-built feed, so the rollover is pinned even
    # without the real slice.
    rollover = synthetic_feed(
        {
            "agency.txt": BASE_AGENCY,
            "routes.txt": BASE_ROUTES,
            "stops.txt": "stop_id,stop_name,location_type,parent_station\nS1,First,,\nS2,Second,,\n",
            "trips.txt": (
                "trip_id,route_id,service_id,trip_headsign,direction_id\n"
                "LATE,R,SVC,Night,0\nEARLY,R,SVC,Morning,0\n"
            ),
            "calendar.txt": (
                "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
                "SVC,1,1,1,1,1,1,1,20260901,20260930\n"
            ),
            "stop_times.txt": (
                "trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type\n"
                "LATE,25:30:00,25:30:00,S1,1,0\n"
                "LATE,25:50:00,25:50:00,S2,2,0\n"
                "EARLY,05:00:00,05:00:00,S1,1,0\n"
                "EARLY,05:20:00,05:20:00,S2,2,0\n"
            ),
        }
    )
    # 01:00 on the 8th: the 25:30 working of the 7th has not gone yet.
    asked = dt.datetime(2026, 9, 8, 1, 0, tzinfo=tz)
    board = next_departures(rollover, ["S1"], asked, limit=5, horizon=dt.timedelta(hours=6))
    equal(len(board), 2, "H2: a 25:30 working is still ahead of a 01:00 question")
    if len(board) == 2:
        equal(board[0].local(tz).strftime("%H:%M"), "01:30", "H2: it shows as 01:30")
        equal(board[0].service_day, dt.date(2026, 9, 7), "H2: and belongs to the previous service day")
        equal(board[1].local(tz).strftime("%H:%M"), "05:00", "H2: today's first working follows it")


# ---------------------------------------------------------------------------
# 2 and 3. Fixture and oracle
# ---------------------------------------------------------------------------


def load_expected() -> dict:
    payload = json.loads(EXPECTED.read_text(encoding="utf-8"))
    check(bool(payload.get("cases")), "oracle fixture has cases")
    check("entur" in payload.get("source", "").lower(), "oracle fixture names its source")
    return payload


def fixture_shape(feed: Feed, payload: dict) -> None:
    print("=== fixture shape ===")
    equal(str(feed.timezone), "Europe/Oslo", "fixture agency timezone")
    check(len(feed.trips) > 1000, f"fixture should hold a realistic trip count, has {len(feed.trips)}")
    check(len(feed.routes) > 10, f"fixture should span several routes, has {len(feed.routes)}")

    # Entur ships no calendar.txt at all: every service day is an explicit
    # calendar_dates row. An engine that only reads calendar.txt shows an
    # empty board for the whole of Norway.
    equal(len(feed.calendars), 0, "Ruter feed has no calendar.txt")
    check(len(feed.exceptions) > 100, f"service comes only from calendar_dates, has {len(feed.exceptions)}")
    check(
        all(kind == ADDED for kind in feed.exceptions.values()),
        "Ruter expresses service as added dates",
    )

    span = feed.coverage()
    check(span is not None, "fixture reports a coverage span")
    if span:
        start, end = span
        print(f"  coverage {start} .. {end}")
        for case in payload["cases"]:
            day = dt.datetime.fromisoformat(case["at"]).date()
            check(
                feed.validity(day) == "current",
                f"probe date {day} should fall inside coverage, got {feed.validity(day)}",
            )

    # H2 on real data.
    late = [
        st
        for times in feed.stop_times.values()
        for st in times
        if st.departure is not None and st.departure >= 86400
    ]
    check(len(late) > 0, "fixture contains departures past 24:00:00")
    print(f"  stop_times past 24:00:00: {len(late):,}")
    latest = max((st.departure or 0) for times in feed.stop_times.values() for st in times)
    print(f"  latest time in fixture   : {latest // 3600:02d}:{latest % 3600 // 60:02d}")

    quays = sorted(payload["quays"])
    for quay in quays:
        n = len(feed.departures_by_stop.get(quay, []))
        check(n > 0, f"{quay} should have departures in the fixture")
        print(f"  {quay:18s} {n:6,d} departures")


def oracle_replay(feed: Feed, payload: dict) -> tuple[int, int]:
    print("=== replaying Entur's answers ===")
    instants = 0
    cases = 0
    for case in payload["cases"]:
        quay = case["quay"]
        probe = dt.datetime.fromisoformat(case["at"])
        expected = sorted(
            dt.datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
            for t in case["expect_utc"]
        )
        if not expected:
            continue
        cases += 1
        horizon = max(expected) - probe.astimezone(UTC)
        mine = next_departures(feed, [quay], probe, limit=500, horizon=horizon)
        got = sorted({d.when for d in mine})
        instants += len(expected)
        if got != expected:
            missing = [t for t in expected if t not in set(got)]
            extra = [t for t in got if t not in set(expected)]
            FAILURES.append(
                f"{quay} at {case['at']}: {len(missing)} missing, {len(extra)} extra "
                f"(first missing {missing[:1]}, first extra {extra[:1]})"
            )
        global ASSERTIONS
        ASSERTIONS += 1
    print(f"  {cases} cases, {instants} departure instants")
    return cases, instants


def oracle_disagreements(feed: Feed, payload: dict) -> int:
    """How many oracle cases the engine currently fails. Used by mutations."""
    bad = 0
    for case in payload["cases"]:
        expected = sorted(
            dt.datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
            for t in case["expect_utc"]
        )
        if not expected:
            continue
        probe = dt.datetime.fromisoformat(case["at"])
        horizon = max(expected) - probe.astimezone(UTC)
        mine = next_departures(feed, [case["quay"]], probe, limit=500, horizon=horizon)
        if sorted({d.when for d in mine}) != expected:
            bad += 1
    return bad


# ---------------------------------------------------------------------------
# 4. Properties
# ---------------------------------------------------------------------------


def properties(feed: Feed, payload: dict) -> None:
    print("=== properties ===")
    quays = sorted(payload["quays"])
    probes = sorted({dt.datetime.fromisoformat(c["at"]) for c in payload["cases"]})

    for quay in quays:
        for probe in probes:
            deps = next_departures(feed, [quay], probe, limit=12, horizon=dt.timedelta(hours=6))
            times = [d.when for d in deps]
            check(times == sorted(times), f"{quay} at {probe}: board is sorted")
            check(
                all(t >= probe.astimezone(UTC) for t in times),
                f"{quay} at {probe}: no departure lies in the past",
            )
            keys = [(d.trip_id, d.stop_id, d.stop_sequence) for d in deps]
            equal(len(keys), len(set(keys)), f"{quay} at {probe}: no train listed twice")
            check(len(deps) <= 12, f"{quay} at {probe}: limit respected")

    print("  limit is a prefix of the unlimited answer")
    quay, probe = quays[0], probes[0]
    full = next_departures(feed, [quay], probe, limit=50, horizon=dt.timedelta(hours=6))
    for n in (1, 3, 7):
        short = next_departures(feed, [quay], probe, limit=n, horizon=dt.timedelta(hours=6))
        equal([d.when for d in short], [d.when for d in full[:n]], f"limit {n} is a prefix")

    print("  a shorter horizon only removes late departures")
    wide = next_departures(feed, [quay], probe, limit=500, horizon=dt.timedelta(hours=6))
    narrow = next_departures(feed, [quay], probe, limit=500, horizon=dt.timedelta(hours=1))
    cutoff = probe.astimezone(UTC) + dt.timedelta(hours=1)
    equal(
        [d.when for d in narrow],
        [d.when for d in wide if d.when <= cutoff],
        "narrow horizon is the wide answer truncated",
    )

    print("  a station aggregates its quays")
    # H10. Riders ask about the station; the timetable is on the platforms.
    parents = {feed.stops[q].parent_station for q in quays if feed.stops[q].parent_station}
    for parent in sorted(parents):
        children = [c for c in feed.children.get(parent, []) if c in feed.departures_by_stop]
        if len(children) < 2:
            continue
        station = next_departures(feed, [parent], probe, limit=500, horizon=dt.timedelta(hours=2))
        union: set[dt.datetime] = set()
        for child in children:
            union |= {
                d.when
                for d in next_departures(feed, [child], probe, limit=500, horizon=dt.timedelta(hours=2))
            }
        equal(
            sorted({d.when for d in station}),
            sorted(union),
            f"{parent}: station board is the union of its quays",
        )

    print("  asking about nothing returns nothing")
    equal(next_departures(feed, [], probes[0], limit=5), [], "no stops means no departures")
    equal(
        next_departures(feed, ["NSR:Quay:does-not-exist"], probes[0], limit=5),
        [],
        "unknown stop means no departures",
    )

    print("  a naive datetime is refused rather than guessed")
    try:
        next_departures(feed, quays[:1], dt.datetime(2026, 9, 5, 8, 0), limit=1)
        check(False, "a naive `now` should be refused")
    except ValueError:
        check(True, "a naive `now` is refused")


# ---------------------------------------------------------------------------
# 5. Mutations
# ---------------------------------------------------------------------------


@contextmanager
def patched(obj: object, name: str, value: object):
    missing = object()
    old = getattr(obj, name, missing)
    setattr(obj, name, value)
    try:
        yield
    finally:
        if old is missing:
            delattr(obj, name)
        else:
            setattr(obj, name, old)


def rebuild_departures(
    feed: Feed,
    wanted: set[str],
    *,
    honour_pickup: bool = True,
    honour_last_stop: bool = True,
) -> None:
    feed.departures_by_stop = {}
    for times in feed.stop_times.values():
        if not times:
            continue
        last = times[-1].stop_sequence
        for st in times:
            if st.stop_id not in wanted:
                continue
            if honour_pickup and st.pickup_type == 1:
                continue
            if honour_last_stop and st.stop_sequence == last:
                continue
            if st.departure is None:
                continue
            feed.departures_by_stop.setdefault(st.stop_id, []).append(st)
    for times in feed.departures_by_stop.values():
        times.sort(key=lambda st: (st.departure or 0, st.trip_id))


def mutations(payload: dict, quays: set[str]) -> None:
    print("=== mutations: each hazard put back on purpose ===")
    print("    (a mutation that changes no answer would mean the oracle cannot see it)")
    total_cases = sum(1 for c in payload["cases"] if c["expect_utc"])

    def report(label: str, caught: int, note: str = "") -> None:
        check(
            caught > 0,
            f"mutation '{label}' broke nothing the oracle could see, so that hazard is unverified",
        )
        pct = 100.0 * caught / total_cases if total_cases else 0.0
        print(f"  {label:44s} {caught:3d}/{total_cases} cases fail  ({pct:5.1f}%) {note}")

    # H1: service days start at midnight instead of noon minus twelve hours.
    feed = load_feed(SLICE, stop_filter=quays)
    with patched(
        Feed,
        "service_day_origin",
        lambda self, day: dt.datetime(day.year, day.month, day.day, tzinfo=self.timezone).astimezone(UTC),
    ):
        report("H1 midnight instead of noon-minus-12h", oracle_disagreements(feed, payload), "DST days only")

    # H2: hours wrapped onto a 24-hour clock.
    def mod24(value: str) -> int | None:
        text = value.strip()
        if not text:
            return None
        h, m, s = (int(p) for p in text.split(":"))
        return (h % 24) * 3600 + m * 60 + s

    with patched(gtfs_engine, "parse_gtfs_time", mod24):
        broken = load_feed(SLICE, stop_filter=quays)
    report("H2 departure hours wrapped modulo 24", oracle_disagreements(broken, payload))

    # H3: calendar_dates ignored. For Ruter that removes all service.
    feed = load_feed(SLICE, stop_filter=quays)
    saved = feed.exceptions
    feed.exceptions = {}
    report("H3 calendar_dates.txt ignored", oracle_disagreements(feed, payload))
    feed.exceptions = saved

    # H5: passengers boarded where boarding is not allowed.
    feed = load_feed(SLICE, stop_filter=quays)
    expanded = set(feed.expand_stops(quays))
    rebuild_departures(feed, expanded, honour_pickup=False)
    report("H5 pickup_type=1 treated as boardable", oracle_disagreements(feed, payload))

    # H6: the last stop of a trip offered as a departure. On this feed the
    # mutation is inert, and the reason is worth stating rather than papering
    # over: Ruter marks every terminal arrival pickup_type=1, so H5 already
    # excludes those rows and H6 never gets to decide anything by itself.
    # Measured, not assumed -- the count below is computed, and if a future
    # fixture does separate the two rules this stops printing "inert".
    feed = load_feed(SLICE, stop_filter=quays)
    rebuild_departures(feed, expanded, honour_last_stop=False)
    inert = oracle_disagreements(feed, payload)
    terminal_rows = [
        times[-1]
        for times in feed.stop_times.values()
        if times and times[-1].stop_id in expanded
    ]
    boardable_terminals = [st for st in terminal_rows if st.pickup_type != 1]
    if inert == 0:
        print(
            f"  {'H6 terminal arrival offered as a departure':44s}   inert on this feed: "
            f"{len(terminal_rows):,} terminal rows at the chosen quays, "
            f"{len(boardable_terminals)} of them boardable"
        )
        check(
            not boardable_terminals,
            f"H6 mutation was inert yet {len(boardable_terminals)} terminal rows allow boarding, "
            "so the rule is genuinely unchecked rather than merely redundant",
        )
        print("      -> pinned by the hand-built feeds above instead")
    else:
        report("H6 terminal arrival offered as a departure", inert)

    # H7: only today's service day considered.
    feed = load_feed(SLICE, stop_filter=quays)
    with patched(gtfs_engine, "MAX_SERVICE_DAY_LOOKBACK", 0):
        report("H7 yesterday's service day not considered", oracle_disagreements(feed, payload))

    # H4: end_date treated as exclusive. Ruter has no calendar.txt, so this
    # cannot bite here; say so rather than implying it was checked.
    feed = load_feed(SLICE, stop_filter=quays)
    if feed.calendars:
        with patched(
            ServiceWindow,
            "covers",
            lambda self, day: self.start <= day < self.end and self.days[day.weekday()],
        ):
            report("H4 end_date treated as exclusive", oracle_disagreements(feed, payload))
    else:
        print(
            "  H4 end_date exclusivity                      not exercised: this feed "
            "has no calendar.txt (covered by the unit checks above)"
        )

    # Sanity: with nothing mutated, nothing may fail.
    feed = load_feed(SLICE, stop_filter=quays)
    equal(oracle_disagreements(feed, payload), 0, "unmutated engine disagrees with the oracle")


# ---------------------------------------------------------------------------


def main() -> int:
    if not SLICE.exists() or not EXPECTED.exists():
        print(f"RESULT: FAIL  (missing fixtures under {FIXTURES})")
        return 1

    spec_units()
    synthetic_units()
    payload = load_expected()
    quays = set(payload["quays"])

    feed = load_feed(SLICE, stop_filter=quays)
    fixture_shape(feed, payload)
    cases, instants = oracle_replay(feed, payload)
    properties(feed, payload)
    mutations(payload, quays)

    print()
    print(f"oracle captured : {payload['captured']}")
    print(f"oracle source   : {payload['source']}")
    print(f"cases replayed  : {cases} ({instants} departure instants)")

    if FAILURES:
        print(f"RESULT: FAIL  ({len(FAILURES)} of {ASSERTIONS} assertions)")
        for failure in FAILURES[:25]:
            print(f"  - {failure}")
        return 1
    print(f"RESULT: PASS  ({ASSERTIONS} assertions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
