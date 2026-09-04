#!/usr/bin/env python3
"""
Re-derive the expected values written into ProximaCoreTests.

The Swift in this repo cannot be compiled on the machine it was written on, so
its unit tests are written blind and every literal in them is a guess until a
runner says otherwise. That is a bad place to be: when CI eventually goes red,
there is no way to tell a broken implementation from a mistyped expectation,
and the tempting fix is to change the assertion until it passes.

So the feeds in `Tests/ProximaCoreTests/DepartureBoardTests.swift` are rebuilt
here, verbatim, and resolved by `gtfs_engine.py` — the reference implementation
that `verify_gtfs.py` already holds against 1,191 departure instants from
Entur's journey planner. If a number below disagrees with the Swift test, the
Swift test is wrong before the Swift code is.

This proves the *expectations*, not the port. Whether ProximaCore computes the
same answers is what `swift test` is for.

  python validation/verify_swift_vectors.py
"""

from __future__ import annotations

import datetime as dt
import io
import pathlib
import sys
import zipfile
from zoneinfo import ZoneInfo

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from gtfs_engine import FeedError, load_feed, next_departures  # noqa: E402

LA = ZoneInfo("America/Los_Angeles")

FAILURES: list[str] = []
CHECKS = 0


def check(condition: bool, label: str, detail: str = "") -> None:
    global CHECKS
    CHECKS += 1
    if condition:
        print(f"  ok    {label}")
    else:
        print(f"  FAIL  {label}{('  — ' + detail) if detail else ''}")
        FAILURES.append(label)


AGENCY = "agency_name,agency_timezone\nTest Transit,America/Los_Angeles\n"
ROUTES = "route_id,route_short_name,route_long_name,route_type\nr1,7,Seventh Avenue Line,3\n"
TRIPS = "trip_id,route_id,service_id,trip_headsign\nt1,r1,weekday,Downtown\n"
STOPS = "stop_id,stop_name,parent_station,location_type\ns1,First Street,,0\ns2,Second Street,,0\n"
WEEKDAY = (
    "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
    "weekday,1,1,1,1,1,0,0,20260101,20261231\n"
)


def feed(
    stop_times: str,
    *,
    calendar: str = WEEKDAY,
    calendar_dates: str = "",
    trips: str = TRIPS,
    stops: str = STOPS,
    feed_info: str = "",
    select: list[str] | None = None,
):
    """The same helper the Swift test file defines, in Python."""
    files = {
        "agency.txt": AGENCY,
        "stops.txt": stops,
        "routes.txt": ROUTES,
        "trips.txt": trips,
        "stop_times.txt": stop_times,
    }
    if calendar:
        files["calendar.txt"] = calendar
    if calendar_dates:
        files["calendar_dates.txt"] = calendar_dates
    if feed_info:
        files["feed_info.txt"] = feed_info

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, text in files.items():
            zf.writestr(name, text)
    buf.seek(0)
    return load_feed(zipfile.ZipFile(buf), stop_filter=set(select or ["s1"]))


def at(year, month, day, hour, minute, second=0) -> dt.datetime:
    return dt.datetime(year, month, day, hour, minute, second, tzinfo=LA)


def board(f, stops, now, **kwargs):
    return next_departures(f, stops, now, **kwargs)


def elapsed_after_midnight(year, month, day, hours) -> dt.datetime:
    """Local midnight plus that many *elapsed* hours.

    This is the wrong rule, written out so a test can show what it costs. Note
    the conversion: adding a timedelta to an aware datetime in Python is
    wall-clock arithmetic, which would quietly re-introduce the right answer.
    """
    midnight = at(year, month, day, 0, 0).astimezone(dt.timezone.utc)
    return midnight + dt.timedelta(hours=hours)


SIMPLE = (
    "trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type\n"
    "t1,s1,1,08:00:00,08:00:00,0\n"
    "t1,s2,2,08:10:00,08:10:00,0\n"
)


def main() -> int:
    print("=" * 72)
    print("Expectations written into ProximaCoreTests, re-derived")
    print("=" * 72)

    # --- testDeparturesComeBackInOrderAndBoundedByTheLimit -----------------
    print("\ntestDeparturesComeBackInOrderAndBoundedByTheLimit")
    f = feed(SIMPLE)
    now = at(2026, 6, 15, 7, 0)
    got = board(f, ["s1"], now)
    check(len(got) == 1, "one departure", f"{len(got)}")
    if got:
        check(got[0].route_label == "7", "route label is the short name", got[0].route_label)
        check(got[0].headsign == "Downtown", "headsign", got[0].headsign)
        check(
            int((got[0].when - now).total_seconds() // 60) == 60,
            "60 minutes away",
            str((got[0].when - now)),
        )

    # --- testMinutesAwayRoundsDown ----------------------------------------
    print("\ntestMinutesAwayRoundsDown")
    now = at(2026, 6, 15, 7, 58, 31)
    got = board(f, ["s1"], now)
    seconds = (got[0].when - now).total_seconds()
    check(seconds == 89, "89 seconds to go", str(seconds))
    check(int(seconds // 60) == 1, "reads as 1 min, not 2")

    # --- testAServiceThatDoesNotRunTodayIsNotOnTheBoard --------------------
    print("\ntestAServiceThatDoesNotRunTodayIsNotOnTheBoard")
    check(dt.date(2026, 6, 13).weekday() == 5, "2026-06-13 is a Saturday")
    check(board(f, ["s1"], at(2026, 6, 13, 7, 0)) == [], "empty on a Saturday")

    # --- testALateNightTripBelongsToTheDayItStartedOn ----------------------
    print("\ntestALateNightTripBelongsToTheDayItStartedOn")
    late = feed(
        "trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type\n"
        "t1,s1,1,25:30:00,25:30:00,0\n"
        "t1,s2,2,25:40:00,25:40:00,0\n"
    )
    now = at(2026, 6, 16, 1, 0)
    got = board(late, ["s1"], now)
    check(len(got) == 1, "one departure at 01:00 on Tuesday", f"{len(got)}")
    if got:
        check(got[0].service_day == dt.date(2026, 6, 15), "it belongs to Monday's service day",
              str(got[0].service_day))
        check(int((got[0].when - now).total_seconds() // 60) == 30, "30 minutes away")

    # --- testATripBeyondTheLookbackIsRefused ------------------------------
    print("\ntestATripBeyondTheLookbackIsRefusedAtCompileTimeRatherThanMisplaced")
    try:
        feed(
            "trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type\n"
            "t1,s1,1,49:00:00,49:00:00,0\n"
            "t1,s2,2,49:10:00,49:10:00,0\n"
        )
        check(True, "49:00:00 is inside a two-service-day lookback")
    except FeedError as error:
        check(False, "49:00:00 is inside a two-service-day lookback", str(error))
    try:
        feed(
            "trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type\n"
            "t1,s1,1,73:00:00,73:00:00,0\n"
            "t1,s2,2,73:10:00,73:10:00,0\n"
        )
        check(False, "73:00:00 is refused at load time")
    except FeedError:
        check(True, "73:00:00 is refused at load time")

    # --- testAPublishedTimeStillMeansThatTimeOnADayTheClocksChange --------
    print("\ntestAPublishedTimeStillMeansThatTimeOnADayTheClocksChange")
    everyday = feed(
        SIMPLE,
        calendar=(
            "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,"
            "start_date,end_date\neveryday,1,1,1,1,1,1,1,20260101,20261231\n"
        ),
        trips="trip_id,route_id,service_id,trip_headsign\nt1,r1,everyday,Downtown\n",
    )
    got = board(everyday, ["s1"], at(2026, 3, 8, 5, 0))
    check(len(got) == 1, "one departure on the spring-forward Sunday", f"{len(got)}")
    if got:
        local = got[0].local(LA)
        check(
            (local.hour, local.minute) == (8, 0),
            "a 08:00:00 trip still departs at 08:00 local on a 23-hour day",
            local.strftime("%H:%M %Z"),
        )
        # The whole reason the rule exists: anchoring at midnight instead moves
        # the same trip an hour later than the agency published it.
        naive = elapsed_after_midnight(2026, 3, 8, 8)
        check(
            naive.astimezone(LA).hour == 9,
            "the midnight rule would announce it an hour after it left",
            naive.astimezone(LA).strftime("%H:%M %Z"),
        )
        check(
            (naive - got[0].when).total_seconds() == 3600,
            "and the gap between the two rules is exactly the hour that vanished",
        )
    ordinary = board(everyday, ["s1"], at(2026, 3, 9, 5, 0))
    check(ordinary[0].local(LA).hour == 8, "and on an ordinary day both rules agree")
    check(
        (elapsed_after_midnight(2026, 3, 9, 8) - ordinary[0].when).total_seconds() == 0,
        "which is exactly why the wrong rule survives testing",
    )

    # --- testAnExceptionCancels / testAnExceptionAdds ----------------------
    print("\ntestAnExceptionCancelsAServiceTheCalendarSaysIsRunning")
    cancelled = feed(SIMPLE, calendar_dates="service_id,date,exception_type\nweekday,20260703,2\n")
    check(dt.date(2026, 7, 3).weekday() == 4, "2026-07-03 is a Friday")
    check(board(cancelled, ["s1"], at(2026, 7, 3, 6, 0)) == [], "cancelled day is empty")
    check(board(cancelled, ["s1"], at(2026, 7, 2, 6, 0)) != [], "the day before still runs")

    print("\ntestAnExceptionAddsAServiceOnADayTheCalendarExcludes")
    added = feed(SIMPLE, calendar_dates="service_id,date,exception_type\nweekday,20260704,1\n")
    check(dt.date(2026, 7, 4).weekday() == 5, "2026-07-04 is a Saturday")
    check(len(board(added, ["s1"], at(2026, 7, 4, 6, 0))) == 1, "the added Saturday runs")

    # --- testBothEndsOfACalendarWindowAreIncluded -------------------------
    print("\ntestBothEndsOfACalendarWindowAreIncluded")
    june = feed(
        SIMPLE,
        calendar=(
            "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,"
            "start_date,end_date\nweekday,1,1,1,1,1,1,1,20260601,20260630\n"
        ),
    )
    check(board(june, ["s1"], at(2026, 6, 1, 6, 0)) != [], "the first day is included")
    check(board(june, ["s1"], at(2026, 6, 30, 6, 0)) != [], "the last day is included")
    check(board(june, ["s1"], at(2026, 7, 1, 6, 0)) == [], "the day after is not")

    # --- testAStopTheVehiclePassesWithoutBoardingIsNotADeparture ----------
    print("\ntestAStopTheVehiclePassesWithoutBoardingIsNotADeparture")
    nopickup = feed(
        "trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type\n"
        "t1,s1,1,08:00:00,08:00:00,1\n"
        "t1,s2,2,08:10:00,08:10:00,0\n"
    )
    check(board(nopickup, ["s1"], at(2026, 6, 15, 6, 0)) == [], "pickup_type=1 is not a departure")

    # --- testTheLastStopOfATripIsAnArrivalAndNotADeparture ----------------
    print("\ntestTheLastStopOfATripIsAnArrivalAndNotADeparture")
    terminus = feed(
        "trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type\n"
        "t1,s2,1,07:50:00,07:50:00,0\n"
        "t1,s1,2,08:00:00,08:00:00,0\n"
    )
    check(board(terminus, ["s1"], at(2026, 6, 15, 6, 0)) == [], "a terminus is not a departure")

    # --- testBlankTimesAreInterpolated ------------------------------------
    print("\ntestBlankTimesAreInterpolatedRatherThanDroppedOrZeroed")
    blank = feed(
        "trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type\n"
        "t1,s2,1,08:00:00,08:00:00,0\n"
        "t1,s1,2,,,0\n"
        "t1,s3,3,08:40:00,08:40:00,0\n",
        stops=(
            "stop_id,stop_name,parent_station,location_type\n"
            "s1,First Street,,0\ns2,Second Street,,0\ns3,Third Street,,0\n"
        ),
    )
    got = board(blank, ["s1"], at(2026, 6, 15, 6, 0))
    check(len(got) == 1, "a blank time does not take the stop off the board", f"{len(got)}")
    if got:
        local = got[0].local(LA)
        check(
            (local.hour, local.minute) == (8, 20),
            "it lands halfway between 08:00 and 08:40",
            local.strftime("%H:%M"),
        )

    # --- testValidityIsDerivedFromTheCalendarsAndNotFromFeedInfo -----------
    print("\ntestValidityIsDerivedFromTheCalendarsAndNotFromFeedInfo")
    claimed = feed(
        SIMPLE,
        feed_info="feed_publisher_name,feed_start_date,feed_end_date\nTest Transit,20260101,20260630\n",
    )
    check(claimed.validity(dt.date(2026, 9, 4)) == "current", "current in September")
    check(claimed.validity(dt.date(2027, 1, 4)) == "expired", "expired the following January")
    check(claimed.validity(dt.date(2025, 1, 4)) == "future", "future the year before")
    check(claimed.feed_info_disagrees(), "the publisher's claim is flagged as disagreeing")

    # --- testAskingAboutAStationAsksAboutItsPlatforms ---------------------
    print("\ntestAskingAboutAStationAsksAboutItsPlatforms")
    station = feed(
        "trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type\n"
        "t1,q1,1,08:00:00,08:00:00,0\n"
        "t1,q2,2,08:10:00,08:10:00,0\n",
        stops=(
            "stop_id,stop_name,parent_station,location_type\n"
            "big,Big Station,,1\nq1,Big Station platform 1,big,0\nq2,Big Station platform 2,big,0\n"
        ),
        select=["big"],
    )
    check(sorted(station.expand_stops(["big"])) == ["big", "q1", "q2"], "the station expands")
    check(len(board(station, ["big"], at(2026, 6, 15, 6, 0))) == 1, "and the board finds the quay")

    # --- testTheBoardIsSortedDeduplicatedAndInsideTheHorizon --------------
    print("\ntestTheBoardIsSortedDeduplicatedAndInsideTheHorizon")
    rows = ["trip_id,stop_id,stop_sequence,arrival_time,departure_time,pickup_type"]
    trips = ["trip_id,route_id,service_id,trip_headsign"]
    for hour in range(5, 23):
        rows.append(f"t{hour},s1,1,{hour:02d}:15:00,{hour:02d}:15:00,0")
        rows.append(f"t{hour},s2,2,{hour:02d}:25:00,{hour:02d}:25:00,0")
        trips.append(f"t{hour},r1,weekday,Downtown")
    many = feed("\n".join(rows) + "\n", trips="\n".join(trips) + "\n")
    now = at(2026, 6, 15, 6, 0)
    got = board(many, ["s1"], now, limit=6, horizon=dt.timedelta(hours=4))
    check(len(got) == 4, "the horizon bounds the answer before the limit does", f"{len(got)}")
    check(got == sorted(got, key=lambda d: d.when), "sorted by time")
    check(len({(d.trip_id, d.stop_id, d.stop_sequence) for d in got}) == len(got), "deduplicated")
    check(
        all(now <= d.when <= now + dt.timedelta(hours=4) for d in got),
        "every instant is inside the horizon",
    )
    check(len(board(many, ["s1"], now, limit=3)) == 3, "the limit applies when the horizon does not")

    # --- testAnUnknownStopReturnsNothingRatherThanEverything --------------
    print("\ntestAnUnknownStopReturnsNothingRatherThanEverything")
    check(board(f, ["nope"], at(2026, 6, 15, 6, 0)) == [], "an unknown stop is empty")
    check(board(f, [], at(2026, 6, 15, 6, 0)) == [], "no stops is empty")

    print()
    print("=" * 72)
    if FAILURES:
        print(f"RESULT: FAIL  ({len(FAILURES)} of {CHECKS} expectations)")
        for failure in FAILURES:
            print(f"  - {failure}")
        print("=" * 72)
        return 1
    print(f"RESULT: PASS  ({CHECKS} expectations re-derived by the validated engine)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
