"""Reference implementation of Proxima's departure engine, in Python.

Proxima answers one question offline: given a GTFS timetable cached on the
watch, a set of stops, and an instant, what leaves next?

This file exists because that question has more wrong answers than right ones,
and every wrong answer looks plausible. It parses and computes exactly what
`Sources/ProximaCore` does, so the Swift port can be held against the same
vectors that this file is held against by `verify_gtfs.py`.

The hazards, each of which produces a believable but wrong departure board and
none of which raises:

  H1  Service days start at "noon minus 12h", not at midnight. The two differ
      by an hour on the two days a year the UTC offset changes, so a train the
      printed timetable calls 08:14 gets shown as 09:14. Verified against IANA
      tzdata, not against intuition.
  H2  stop_times may hold hours >= 24, meaning "after midnight, still the
      previous service day". The real BART feed has 2,005 such rows. Parsing
      the hour into a 0-23 clock silently drops the entire late-night service.
  H3  calendar_dates.txt overrides calendar.txt: exception_type 1 adds service
      on a date, 2 removes it. Applying calendar.txt alone runs holiday
      timetables on ordinary days.
  H4  calendar.txt start_date and end_date are inclusive on both ends.
  H5  pickup_type == 1 means nobody may board. It is not a departure.
  H6  The last stop of a trip is arrival-only. Showing it strands riders.
  H7  To find what leaves now you must consider yesterday's service day too,
      because of H2. Considering only today loses every post-midnight train.
  H8  departure_time may be blank at non-timepoint stops, and the spec asks
      for linear interpolation between the surrounding timepoints.
  H9  A feed has a validity window. Past its end the honest answer is "this
      timetable expired", not an empty board that looks like "no more trains".
  H10 A station is a parent of platforms. Riders ask about the station.

Times are handled as UTC instants internally. Local time appears only when
converting a service day to its origin, which is the one place the zone rules
may be consulted.
"""

from __future__ import annotations

import csv
import datetime as dt
import io
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Iterator, Sequence
from zoneinfo import ZoneInfo

UTC = dt.timezone.utc

# GTFS permits times past 24:00:00 to express "after midnight, same service
# day". Feeds in the wild reach into the 20s; 48:00:00 would be two days. The
# engine looks back this many service days when answering "what leaves now",
# and the loader asserts the feed does not exceed it.
MAX_SERVICE_DAY_LOOKBACK = 2


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------


class FeedError(Exception):
    """The feed is missing something the engine cannot work without."""


def parse_gtfs_time(value: str) -> int | None:
    """'25:30:00' -> 91800 seconds after the start of the service day.

    Returns None for a blank time, which GTFS allows at non-timepoint stops
    and which the caller must interpolate (H8). Rejects anything else, because
    a departure board that silently drops malformed rows is a departure board
    that silently loses trains.
    """
    text = value.strip()
    if not text:
        return None
    parts = text.split(":")
    if len(parts) != 3:
        raise FeedError(f"not a GTFS time: {value!r}")
    try:
        hours, minutes, seconds = (int(p) for p in parts)
    except ValueError as exc:
        raise FeedError(f"not a GTFS time: {value!r}") from exc
    if minutes < 0 or minutes > 59 or seconds < 0 or seconds > 59 or hours < 0:
        raise FeedError(f"out of range GTFS time: {value!r}")
    return hours * 3600 + minutes * 60 + seconds


def parse_gtfs_date(value: str) -> dt.date:
    text = value.strip()
    if len(text) != 8 or not text.isdigit():
        raise FeedError(f"not a GTFS date: {value!r}")
    return dt.date(int(text[:4]), int(text[4:6]), int(text[6:8]))


@dataclass(frozen=True)
class Stop:
    stop_id: str
    name: str
    parent_station: str
    location_type: int

    @property
    def is_station(self) -> bool:
        return self.location_type == 1


@dataclass(frozen=True)
class Route:
    route_id: str
    short_name: str
    long_name: str
    route_type: int
    color: str
    text_color: str

    @property
    def label(self) -> str:
        """What to print on a 41 mm screen: short name if there is one."""
        return self.short_name.strip() or self.long_name.strip() or self.route_id


@dataclass(frozen=True)
class Trip:
    trip_id: str
    route_id: str
    service_id: str
    headsign: str
    direction_id: int


@dataclass(frozen=True)
class StopTime:
    trip_id: str
    stop_id: str
    stop_sequence: int
    departure: int | None
    arrival: int | None
    pickup_type: int
    timepoint: bool


@dataclass(frozen=True)
class ServiceWindow:
    service_id: str
    days: tuple[bool, ...]  # Monday..Sunday, GTFS column order
    start: dt.date
    end: dt.date

    def covers(self, day: dt.date) -> bool:
        # H4: both ends inclusive.
        if day < self.start or day > self.end:
            return False
        return self.days[day.weekday()]


ADDED, REMOVED = 1, 2


@dataclass
class Feed:
    timezone: ZoneInfo
    agency_name: str
    stops: dict[str, Stop]
    routes: dict[str, Route]
    trips: dict[str, Trip]
    stop_times: dict[str, list[StopTime]] = field(default_factory=dict)  # by trip
    departures_by_stop: dict[str, list[StopTime]] = field(default_factory=dict)
    calendars: dict[str, ServiceWindow] = field(default_factory=dict)
    exceptions: dict[tuple[str, dt.date], int] = field(default_factory=dict)
    feed_start: dt.date | None = None
    feed_end: dt.date | None = None
    children: dict[str, list[str]] = field(default_factory=dict)

    # ---- service days -------------------------------------------------

    def service_day_origin(self, day: dt.date) -> dt.datetime:
        """H1. Noon on the service day, minus twelve *elapsed* hours.

        Arithmetic runs in UTC on purpose. Subtracting a timedelta from an
        aware local datetime is wall-clock arithmetic in Python and would
        collapse this back to midnight, hiding the very bug it guards.
        """
        noon_local = dt.datetime(day.year, day.month, day.day, 12, 0, 0, tzinfo=self.timezone)
        return noon_local.astimezone(UTC) - dt.timedelta(hours=12)

    def runs_on(self, service_id: str, day: dt.date) -> bool:
        """H3. calendar_dates overrides calendar, in that order."""
        override = self.exceptions.get((service_id, day))
        if override == ADDED:
            return True
        if override == REMOVED:
            return False
        window = self.calendars.get(service_id)
        return bool(window and window.covers(day))

    def active_services(self, day: dt.date) -> set[str]:
        ids = {sid for sid, window in self.calendars.items() if window.covers(day)}
        for (sid, date), kind in self.exceptions.items():
            if date != day:
                continue
            if kind == ADDED:
                ids.add(sid)
            elif kind == REMOVED:
                ids.discard(sid)
        return ids

    # ---- stop expansion ------------------------------------------------

    def expand_stops(self, stop_ids: Iterable[str]) -> list[str]:
        """H10. Asking about a station means asking about its platforms."""
        out: list[str] = []
        seen: set[str] = set()
        for sid in stop_ids:
            for candidate in [sid, *self.children.get(sid, ())]:
                if candidate not in seen and candidate in self.stops:
                    seen.add(candidate)
                    out.append(candidate)
        return out

    # ---- validity ------------------------------------------------------

    def coverage(self) -> tuple[dt.date, dt.date] | None:
        """The span the calendars actually describe, ignoring feed_info.

        The real BART feed states feed_start_date 2026-01-12 and
        feed_end_date 2026-08-30 while its calendar.txt runs 2026-08-10 to
        2027-01-10. Believing feed_info there would blank the board for four
        months of perfectly good timetable. Believing nothing at all would
        blank it silently once the timetable really does run out. So the
        calendars decide, and feed_info is treated as a claim to check.
        """
        dates: list[dt.date] = []
        for window in self.calendars.values():
            if any(window.days):
                dates.extend((window.start, window.end))
        dates.extend(day for (_, day), kind in self.exceptions.items() if kind == ADDED)
        if not dates:
            return None
        return min(dates), max(dates)

    def validity(self, day: dt.date) -> str:
        """H9. 'current', 'expired' or 'future'. Never silently empty."""
        span = self.coverage()
        if span is None:
            return "expired"
        start, end = span
        if day > end:
            return "expired"
        if day < start:
            return "future"
        return "current"

    def feed_info_disagrees(self) -> bool:
        """True when feed_info.txt contradicts the calendars it ships with."""
        span = self.coverage()
        if span is None:
            return bool(self.feed_start or self.feed_end)
        start, end = span
        if self.feed_start and self.feed_start > start:
            return True
        if self.feed_end and self.feed_end < end:
            return True
        return False


def _rows(zf: zipfile.ZipFile, name: str) -> Iterator[dict[str, str]]:
    with zf.open(name) as fh:
        # utf-8-sig: GTFS files in the wild carry a BOM often enough that
        # reading them as plain utf-8 puts "\ufeffagency_id" in the header and
        # every lookup of "agency_id" then misses.
        yield from csv.DictReader(io.TextIOWrapper(fh, encoding="utf-8-sig", newline=""))


def _int(value: str | None, default: int = 0) -> int:
    text = (value or "").strip()
    if not text:
        return default
    return int(text)


def load_feed(source: Path | zipfile.ZipFile, *, stop_filter: set[str] | None = None) -> Feed:
    """Read the subset of a GTFS feed that a departure board needs.

    `stop_filter` keeps only stop_times at the given stops (after expanding
    stations to platforms), which is what makes a 53 MB national feed fit in a
    watch app. Trips are kept only if they call at one of them.
    """
    zf = source if isinstance(source, zipfile.ZipFile) else zipfile.ZipFile(source)
    names = set(zf.namelist())
    for required in ("agency.txt", "stops.txt", "routes.txt", "trips.txt", "stop_times.txt"):
        if required not in names:
            raise FeedError(f"feed is missing {required}")

    agency_rows = list(_rows(zf, "agency.txt"))
    if not agency_rows:
        raise FeedError("agency.txt is empty")
    tz_name = (agency_rows[0].get("agency_timezone") or "").strip()
    if not tz_name:
        raise FeedError("agency.txt has no agency_timezone")
    feed = Feed(
        timezone=ZoneInfo(tz_name),
        agency_name=(agency_rows[0].get("agency_name") or "").strip(),
        stops={},
        routes={},
        trips={},
    )

    for row in _rows(zf, "stops.txt"):
        stop = Stop(
            stop_id=row["stop_id"].strip(),
            name=(row.get("stop_name") or "").strip(),
            parent_station=(row.get("parent_station") or "").strip(),
            location_type=_int(row.get("location_type")),
        )
        feed.stops[stop.stop_id] = stop
        if stop.parent_station:
            feed.children.setdefault(stop.parent_station, []).append(stop.stop_id)

    for row in _rows(zf, "routes.txt"):
        feed.routes[row["route_id"].strip()] = Route(
            route_id=row["route_id"].strip(),
            short_name=(row.get("route_short_name") or "").strip(),
            long_name=(row.get("route_long_name") or "").strip(),
            route_type=_int(row.get("route_type")),
            color=(row.get("route_color") or "").strip(),
            text_color=(row.get("route_text_color") or "").strip(),
        )

    for row in _rows(zf, "trips.txt"):
        feed.trips[row["trip_id"].strip()] = Trip(
            trip_id=row["trip_id"].strip(),
            route_id=(row.get("route_id") or "").strip(),
            service_id=(row.get("service_id") or "").strip(),
            headsign=(row.get("trip_headsign") or "").strip(),
            direction_id=_int(row.get("direction_id")),
        )

    if "calendar.txt" in names:
        order = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
        for row in _rows(zf, "calendar.txt"):
            sid = row["service_id"].strip()
            feed.calendars[sid] = ServiceWindow(
                service_id=sid,
                days=tuple(_int(row.get(d)) == 1 for d in order),
                start=parse_gtfs_date(row["start_date"]),
                end=parse_gtfs_date(row["end_date"]),
            )

    if "calendar_dates.txt" in names:
        for row in _rows(zf, "calendar_dates.txt"):
            key = (row["service_id"].strip(), parse_gtfs_date(row["date"]))
            feed.exceptions[key] = _int(row.get("exception_type"))

    if "feed_info.txt" in names:
        info = list(_rows(zf, "feed_info.txt"))
        if info:
            start, end = info[0].get("feed_start_date"), info[0].get("feed_end_date")
            feed.feed_start = parse_gtfs_date(start) if (start or "").strip() else None
            feed.feed_end = parse_gtfs_date(end) if (end or "").strip() else None

    wanted = set(feed.expand_stops(stop_filter)) if stop_filter else None

    # Ruter's national feed holds 2.1 million stop_times rows in a 200 MB file.
    # Materialising all of them costs gigabytes, so when the caller names the
    # stops it cares about, find the trips that call there first and keep only
    # those. Both passes are needed even so: the last stop of a trip is
    # arrival-only (H6) and blank times interpolate from neighbours (H8), so a
    # kept trip must be kept whole, not just at the stop that matched.
    trips_of_interest: set[str] | None = None
    if wanted is not None:
        trips_of_interest = {
            row["trip_id"].strip()
            for row in _rows(zf, "stop_times.txt")
            if row["stop_id"].strip() in wanted
        }

    by_trip: dict[str, list[StopTime]] = {}
    max_seconds = 0
    for row in _rows(zf, "stop_times.txt"):
        trip_id = row["trip_id"].strip()
        if trips_of_interest is not None and trip_id not in trips_of_interest:
            continue
        stop_id = row["stop_id"].strip()
        departure = parse_gtfs_time(row.get("departure_time", ""))
        arrival = parse_gtfs_time(row.get("arrival_time", ""))
        if departure is not None:
            max_seconds = max(max_seconds, departure)
        st = StopTime(
            trip_id=trip_id,
            stop_id=stop_id,
            stop_sequence=_int(row.get("stop_sequence")),
            departure=departure,
            arrival=arrival,
            pickup_type=_int(row.get("pickup_type")),
            # GTFS default for a missing timepoint column is "exact".
            timepoint=_int(row.get("timepoint"), 1) == 1,
        )
        by_trip.setdefault(trip_id, []).append(st)

    if max_seconds >= (MAX_SERVICE_DAY_LOOKBACK + 1) * 86400:
        raise FeedError(
            f"feed has a departure at {max_seconds // 3600}:xx, beyond the "
            f"{MAX_SERVICE_DAY_LOOKBACK}-service-day lookback the engine uses"
        )

    for trip_id, times in by_trip.items():
        times.sort(key=lambda st: st.stop_sequence)
        times = _interpolate(times)  # H8
        feed.stop_times[trip_id] = times
        last_sequence = times[-1].stop_sequence if times else -1
        for st in times:
            if wanted is not None and st.stop_id not in wanted:
                continue
            if st.pickup_type == 1:  # H5
                continue
            if st.stop_sequence == last_sequence:  # H6
                continue
            if st.departure is None:
                continue
            feed.departures_by_stop.setdefault(st.stop_id, []).append(st)

    for times in feed.departures_by_stop.values():
        times.sort(key=lambda st: (st.departure or 0, st.trip_id))

    return feed


def _interpolate(times: list[StopTime]) -> list[StopTime]:
    """H8. Fill blank departure times linearly between known ones.

    GTFS lets a feed omit times at non-timepoint stops. The spec's reading is
    that they fall evenly between the surrounding timepoints. Leaving them
    blank makes those stops vanish from the board; guessing them as zero puts
    trains at midnight.
    """
    known = [i for i, st in enumerate(times) if st.departure is not None or st.arrival is not None]
    if len(known) == len(times) or not known:
        return times

    filled = list(times)
    for position, index in enumerate(known[:-1]):
        left, right = index, known[position + 1]
        gap = right - left
        if gap <= 1:
            continue
        left_time = filled[left].departure if filled[left].departure is not None else filled[left].arrival
        right_time = filled[right].arrival if filled[right].arrival is not None else filled[right].departure
        if left_time is None or right_time is None:
            continue
        step = (right_time - left_time) / gap
        for offset in range(1, gap):
            st = filled[left + offset]
            value = int(round(left_time + step * offset))
            filled[left + offset] = StopTime(
                trip_id=st.trip_id,
                stop_id=st.stop_id,
                stop_sequence=st.stop_sequence,
                departure=value,
                arrival=value,
                pickup_type=st.pickup_type,
                timepoint=False,
            )
    return filled


# --------------------------------------------------------------------------
# Departures
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Departure:
    when: dt.datetime  # aware, UTC
    trip_id: str
    stop_id: str
    stop_sequence: int
    route_label: str
    headsign: str
    service_day: dt.date

    def local(self, tz: ZoneInfo) -> dt.datetime:
        return self.when.astimezone(tz)


def next_departures(
    feed: Feed,
    stop_ids: Sequence[str],
    now: dt.datetime,
    *,
    limit: int = 8,
    horizon: dt.timedelta = dt.timedelta(hours=12),
) -> list[Departure]:
    """What leaves `stop_ids` at or after `now`, soonest first.

    `now` must be timezone aware. The horizon bounds the search so a board
    asked at 2 a.m. on a Sunday does not scan a whole week.
    """
    if now.tzinfo is None:
        raise ValueError("now must be timezone aware")
    now_utc = now.astimezone(UTC)
    deadline = now_utc + horizon

    stops = feed.expand_stops(stop_ids)
    if not stops:
        return []

    local_today = now_utc.astimezone(feed.timezone).date()
    # H7: yesterday's service day can still be running (hours >= 24), and
    # tomorrow's can start before the horizon closes.
    span = range(-MAX_SERVICE_DAY_LOOKBACK, 2)
    found: list[Departure] = []

    for offset in span:
        day = local_today + dt.timedelta(days=offset)
        origin = feed.service_day_origin(day)
        if origin > deadline:
            continue
        active = feed.active_services(day)
        if not active:
            continue
        for stop_id in stops:
            for st in feed.departures_by_stop.get(stop_id, ()):
                assert st.departure is not None
                when = origin + dt.timedelta(seconds=st.departure)
                if when < now_utc or when > deadline:
                    continue
                trip = feed.trips.get(st.trip_id)
                if trip is None or trip.service_id not in active:
                    continue
                route = feed.routes.get(trip.route_id)
                found.append(
                    Departure(
                        when=when,
                        trip_id=st.trip_id,
                        stop_id=st.stop_id,
                        stop_sequence=st.stop_sequence,
                        route_label=route.label if route else trip.route_id,
                        headsign=trip.headsign,
                        service_day=day,
                    )
                )

    # A trip can be reachable through two service days only if the feed is
    # malformed, but dedupe anyway: showing the same train twice is a bug the
    # rider can see.
    unique: dict[tuple[str, str, int], Departure] = {}
    for dep in found:
        key = (dep.trip_id, dep.stop_id, dep.stop_sequence)
        if key not in unique or dep.when < unique[key].when:
            unique[key] = dep

    ordered = sorted(unique.values(), key=lambda d: (d.when, d.trip_id, d.stop_sequence))
    return ordered[:limit]
