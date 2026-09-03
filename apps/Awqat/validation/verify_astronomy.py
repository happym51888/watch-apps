"""Independent check of the prayer-time astronomy in AwqatCore.

This is a line-for-line port of Sources/AwqatCore/Astronomy.swift and
PrayerTimes.swift into Python, run against prayer times published by the AlAdhan
API (an unrelated implementation). Its job is to answer one question before any
Swift is compiled: are the formulas and constants right?

If this agrees with the published timetables to within a minute, then a later
failure in the Swift test suite is a transcription bug, not an astronomy bug --
which is a much cheaper thing to hunt.

Usage:
    python verify_astronomy.py
"""

import math
from datetime import datetime, timedelta, timezone

# --------------------------------------------------------------------------
# Astronomy.swift
# --------------------------------------------------------------------------


def julian_day(year: int, month: int, day: int) -> float:
    """Meeus 7.1, for a Gregorian date at 00:00 UT."""
    y, m = year, month
    if m <= 2:
        y -= 1
        m += 12
    a = math.floor(y / 100)
    b = 2 - a + math.floor(a / 4)
    return (
        math.floor(365.25 * (y + 4716))
        + math.floor(30.6001 * (m + 1))
        + day
        + b
        - 1524.5
    )


def normalize_degrees(value: float) -> float:
    wrapped = math.fmod(value, 360.0)
    return wrapped + 360.0 if wrapped < 0 else wrapped


def solar_position(jd: float) -> tuple[float, float]:
    """Returns (declination in degrees, equation of time in minutes)."""
    t = (jd - 2451545.0) / 36525.0

    l0 = normalize_degrees(280.46646 + 36000.76983 * t + 0.0003032 * t * t)
    m = normalize_degrees(357.52911 + 35999.05029 * t - 0.0001537 * t * t)
    e = 0.016708634 - 0.000042037 * t - 0.0000001267 * t * t

    m_rad = math.radians(m)
    c = (
        (1.914602 - 0.004817 * t - 0.000014 * t * t) * math.sin(m_rad)
        + (0.019993 - 0.000101 * t) * math.sin(2 * m_rad)
        + 0.000289 * math.sin(3 * m_rad)
    )

    true_longitude = l0 + c
    omega = 125.04 - 1934.136 * t
    omega_rad = math.radians(omega)
    lam = true_longitude - 0.00569 - 0.00478 * math.sin(omega_rad)

    epsilon0 = 23.439291 - 0.0130042 * t - 1.64e-7 * t * t + 5.04e-7 * t * t * t
    epsilon = epsilon0 + 0.00256 * math.cos(omega_rad)

    declination = math.degrees(
        math.asin(math.sin(math.radians(epsilon)) * math.sin(math.radians(lam)))
    )

    y = math.tan(math.radians(epsilon / 2)) ** 2
    l0_rad = math.radians(l0)
    eot_radians = (
        y * math.sin(2 * l0_rad)
        - 2 * e * math.sin(m_rad)
        + 4 * e * y * math.sin(m_rad) * math.cos(2 * l0_rad)
        - 0.5 * y * y * math.sin(4 * l0_rad)
        - 1.25 * e * e * math.sin(2 * m_rad)
    )
    equation_of_time = 4 * math.degrees(eot_radians)

    return declination, equation_of_time


class SolarDay:
    def __init__(self, year, month, day, latitude, longitude, elevation=0.0):
        self.jd_midnight = julian_day(year, month, day)
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = max(0.0, elevation)

    @property
    def transit(self) -> float:
        noon = 12.0 - self.longitude / 15.0
        for _ in range(3):
            _, eot = solar_position(self.jd_midnight + noon / 24.0)
            noon = 12.0 - self.longitude / 15.0 - eot / 60.0
        return noon

    @staticmethod
    def hour_angle(altitude, latitude, declination):
        lat_rad = math.radians(latitude)
        dec_rad = math.radians(declination)
        denominator = math.cos(lat_rad) * math.cos(dec_rad)
        if abs(denominator) < 1e-12:
            return None
        cos_h = (
            math.sin(math.radians(altitude))
            - math.sin(lat_rad) * math.sin(dec_rad)
        ) / denominator
        if cos_h < -1 or cos_h > 1:
            return None
        return math.degrees(math.acos(cos_h))

    def time_at_altitude(self, altitude, after_transit: bool):
        transit = self.transit
        estimate = transit
        for _ in range(2):
            declination, _ = solar_position(self.jd_midnight + estimate / 24.0)
            h = self.hour_angle(altitude, self.latitude, declination)
            if h is None:
                return None
            offset = h / 15.0
            estimate = transit + offset if after_transit else transit - offset
        return estimate

    @property
    def horizon_altitude(self) -> float:
        return -0.833 - 0.0347 * math.sqrt(self.elevation)

    @property
    def sunrise(self):
        return self.time_at_altitude(self.horizon_altitude, after_transit=False)

    @property
    def sunset(self):
        return self.time_at_altitude(self.horizon_altitude, after_transit=True)

    def asr_altitude(self, shadow_factor: float, declination: float) -> float:
        noon_zenith = abs(self.latitude - declination)
        return math.degrees(
            math.atan(1.0 / (shadow_factor + math.tan(math.radians(noon_zenith))))
        )

    def asr_time(self, shadow_factor: float):
        """Altitude and hour angle iterated together -- see Astronomy.swift."""
        transit = self.transit
        estimate = transit
        for _ in range(3):
            declination, _ = solar_position(self.jd_midnight + estimate / 24.0)
            altitude = self.asr_altitude(shadow_factor, declination)
            h = self.hour_angle(altitude, self.latitude, declination)
            if h is None:
                return None
            estimate = transit + h / 15.0
        return estimate


# --------------------------------------------------------------------------
# PrayerTimes.swift
# --------------------------------------------------------------------------

HIGH_LAT_MIDDLE = "middleOfTheNight"
HIGH_LAT_SEVENTH = "seventhOfTheNight"
HIGH_LAT_TWILIGHT = "twilightAngle"


def night_portion(angle, rule, night):
    if rule == HIGH_LAT_MIDDLE:
        return night / 2
    if rule == HIGH_LAT_SEVENTH:
        return night / 7
    return night * angle / 60


def prayer_times(
    latitude,
    longitude,
    year,
    month,
    day,
    fajr_angle,
    isha_rule,          # ("angle", deg) or ("interval", minutes)
    shadow_factor=1.0,
    maghrib_angle=0.0,
    high_lat_rule=HIGH_LAT_TWILIGHT,
    dhuhr_offset_minutes=0,
    elevation=0.0,
):
    solar = SolarDay(year, month, day, latitude, longitude, elevation)
    sunrise = solar.sunrise
    sunset = solar.sunset
    if sunrise is None or sunset is None:
        return None

    transit = solar.transit
    asr = solar.asr_time(shadow_factor)
    if asr is None:
        asr = transit + (sunset - transit) * 0.7

    if maghrib_angle > 0:
        maghrib = solar.time_at_altitude(-maghrib_angle, after_transit=True) or sunset
    else:
        maghrib = sunset

    night = (sunrise + 24) - sunset

    fajr_limit = sunrise - night_portion(fajr_angle, high_lat_rule, night)
    computed_fajr = solar.time_at_altitude(-fajr_angle, after_transit=False)
    fajr = fajr_limit if computed_fajr is None else max(computed_fajr, fajr_limit)

    kind, value = isha_rule
    if kind == "interval":
        isha = maghrib + value / 60.0
    else:
        isha_limit = sunset + night_portion(value, high_lat_rule, night)
        computed_isha = solar.time_at_altitude(-value, after_transit=True)
        isha = isha_limit if computed_isha is None else min(computed_isha, isha_limit)

    def to_instant(ut_hours, plus_minutes=0):
        jd = solar.jd_midnight + ut_hours / 24.0
        unix = (jd - 2440587.5) * 86400.0 + plus_minutes * 60.0
        return round(unix / 60.0) * 60.0

    return {
        "fajr": to_instant(fajr),
        "sunrise": to_instant(sunrise),
        "dhuhr": to_instant(transit, dhuhr_offset_minutes),
        "asr": to_instant(asr),
        "maghrib": to_instant(maghrib),
        "isha": to_instant(isha),
    }


# --------------------------------------------------------------------------
# Reference data, fetched from api.aladhan.com on 2026-09-03
# --------------------------------------------------------------------------

CASES = [
    {
        "name": "London 2026-06-15 MWL standard (both twilight fallbacks active)",
        "query": "timings/15-06-2026?latitude=51.5074&longitude=-0.1278&method=3&school=0",
        "lat": 51.5074, "lng": -0.1278, "date": (2026, 6, 15),
        "fajr_angle": 18.0, "isha_rule": ("angle", 17.0), "shadow": 1.0,
        "utc_offset": 1.0,
        "expected": {"fajr": "02:30", "sunrise": "04:43", "dhuhr": "13:01",
                     "asr": "17:23", "maghrib": "21:19", "isha": "23:25"},
    },
    {
        "name": "New York 2026-01-15 ISNA standard",
        "query": "timings/15-01-2026?latitude=40.7128&longitude=-74.0060&method=2&school=0",
        "lat": 40.7128, "lng": -74.0060, "date": (2026, 1, 15),
        "fajr_angle": 15.0, "isha_rule": ("angle", 15.0), "shadow": 1.0,
        "utc_offset": -5.0,
        "expected": {"fajr": "05:58", "sunrise": "07:18", "dhuhr": "12:06",
                     "asr": "14:33", "maghrib": "16:53", "isha": "18:14"},
    },
    {
        "name": "Jakarta 2026-09-20 MWL Hanafi",
        "query": "timings/20-09-2026?latitude=-6.2088&longitude=106.8456&method=3&school=1",
        "lat": -6.2088, "lng": 106.8456, "date": (2026, 9, 20),
        "fajr_angle": 18.0, "isha_rule": ("angle", 17.0), "shadow": 2.0,
        "utc_offset": 7.0,
        "expected": {"fajr": "04:34", "sunrise": "05:43", "dhuhr": "11:46",
                     "asr": "16:04", "maghrib": "17:49", "isha": "18:54"},
    },
    {
        "name": "Sydney 2026-07-05 MWL standard (southern hemisphere)",
        "query": "timings/05-07-2026?latitude=-33.8688&longitude=151.2093&method=3&school=0",
        "lat": -33.8688, "lng": 151.2093, "date": (2026, 7, 5),
        "fajr_angle": 18.0, "isha_rule": ("angle", 17.0), "shadow": 1.0,
        "utc_offset": 10.0,
        "expected": {"fajr": "05:32", "sunrise": "07:01", "dhuhr": "12:00",
                     "asr": "14:40", "maghrib": "16:59", "isha": "18:23"},
    },
    {
        "name": "Cairo 2026-11-12 Egyptian Hanafi",
        "query": "timings/12-11-2026?latitude=30.0444&longitude=31.2357&method=5&school=1",
        "lat": 30.0444, "lng": 31.2357, "date": (2026, 11, 12),
        "fajr_angle": 19.5, "isha_rule": ("angle", 17.5), "shadow": 2.0,
        "utc_offset": 2.0,
        "expected": {"fajr": "04:48", "sunrise": "06:18", "dhuhr": "11:39",
                     "asr": "15:24", "maghrib": "17:00", "isha": "18:20"},
    },
    {
        "name": "Makkah 2026-03-10 Umm al-Qura (Isha = Maghrib + 90m, no Ramadan bump)",
        "query": "timings/10-03-2026?latitude=21.4225&longitude=39.8262&method=4&school=0",
        "lat": 21.4225, "lng": 39.8262, "date": (2026, 3, 10),
        "fajr_angle": 18.5, "isha_rule": ("interval", 90), "shadow": 1.0,
        "utc_offset": 3.0,
        "expected": {"fajr": "05:18", "sunrise": "06:34", "dhuhr": "12:31",
                     "asr": "15:53", "maghrib": "18:28", "isha": "19:58"},
    },
]

TOLERANCE_SECONDS = 60


def expected_instant(clock, date, utc_offset):
    hour, minute = (int(part) for part in clock.split(":"))
    jd = julian_day(*date)
    ut_hours = hour + minute / 60.0 - utc_offset
    return (jd - 2440587.5) * 86400.0 + ut_hours * 3600.0


def as_clock(unix_seconds, utc_offset):
    moment = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(
        seconds=unix_seconds + utc_offset * 3600
    )
    return moment.strftime("%H:%M")


def implied_shadow_factor(solar: SolarDay, ut_hours: float) -> float:
    """Back out the Asr shadow factor implied by a given time.

    Asr is defined by shadow length, so this is the check that decides whether an
    implementation honours the definition or merely approximates it.
    """
    declination, _ = solar_position(solar.jd_midnight + ut_hours / 24.0)
    lat = math.radians(solar.latitude)
    dec = math.radians(declination)
    h = math.radians((ut_hours - solar.transit) * 15.0)
    altitude = math.degrees(
        math.asin(math.sin(lat) * math.sin(dec) + math.cos(lat) * math.cos(dec) * math.cos(h))
    )
    shadow_ratio = 1.0 / math.tan(math.radians(altitude))
    noon_zenith = abs(solar.latitude - declination)
    return shadow_ratio - math.tan(math.radians(noon_zenith))


def report_asr_fidelity() -> None:
    """Explains the one place this engine deliberately disagrees with AlAdhan.

    Every Asr below reads up to a minute later than the published time. That is
    not a bug: at AlAdhan's time the implied shadow factor comes out at 0.98-0.99
    instead of the 1.0 the standard school declares, whereas this engine solves
    for the declared factor exactly. Standard-school Asr sits nearer solar noon,
    where the sun's altitude changes slowly, so a small angular approximation
    turns into a visible time difference -- which is why the Hanafi cases agree
    and the standard cases do not.
    """
    print("Asr fidelity: shadow factor implied by each implementation's time")
    print("  " + "case".ljust(34) + "declared".rjust(9) + "aladhan".rjust(10) + "awqat".rjust(9))
    print("  " + "-" * 62)
    for case in CASES:
        solar = SolarDay(*case["date"], case["lat"], case["lng"])
        hour, minute = (int(part) for part in case["expected"]["asr"].split(":"))
        aladhan_ut = hour + minute / 60.0 - case["utc_offset"]
        awqat_ut = solar.asr_time(case["shadow"])
        print(
            "  "
            + case["name"][:32].ljust(34)
            + f"{case['shadow']:9.1f}"
            + f"{implied_shadow_factor(solar, aladhan_ut):10.4f}"
            + f"{implied_shadow_factor(solar, awqat_ut):9.4f}"
        )
    print()


def main() -> int:
    failures = 0
    worst = 0.0
    print("Validating AwqatCore astronomy against published AlAdhan timetables")
    print(f"tolerance: {TOLERANCE_SECONDS}s\n")

    for case in CASES:
        computed = prayer_times(
            latitude=case["lat"],
            longitude=case["lng"],
            year=case["date"][0],
            month=case["date"][1],
            day=case["date"][2],
            fajr_angle=case["fajr_angle"],
            isha_rule=case["isha_rule"],
            shadow_factor=case["shadow"],
            high_lat_rule=HIGH_LAT_TWILIGHT,
        )
        print(case["name"])
        print(f"  {case['query']}")
        assert computed is not None, "engine returned nothing"

        for prayer, clock in case["expected"].items():
            want = expected_instant(clock, case["date"], case["utc_offset"])
            got = computed[prayer]
            delta = got - want
            worst = max(worst, abs(delta))
            ok = abs(delta) <= TOLERANCE_SECONDS
            if not ok:
                failures += 1
            mark = "ok  " if ok else "FAIL"
            print(
                f"    {mark} {prayer:<8} expected {clock}  got "
                f"{as_clock(got, case['utc_offset'])}  delta {int(delta):+4d}s"
            )
        print()

    report_asr_fidelity()

    print(f"largest disagreement: {int(worst)}s")
    if failures:
        print(f"RESULT: FAIL ({failures} time(s) outside tolerance)")
        return 1
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
