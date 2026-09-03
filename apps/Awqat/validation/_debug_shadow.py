"""Which implementation actually satisfies the Asr shadow definition?

Asr is defined by shadow length: the shadow has grown by `factor` object-heights
beyond its noon length. So take each published Asr time, compute the sun's
altitude there, and back out the shadow factor it implies. Whoever lands on a
clean 1.0 / 2.0 is honouring the definition.
"""

import math
import verify_astronomy as v


def altitude_at(solar, ut_hours):
    """Sun altitude in degrees at a given UT hour."""
    declination, _ = v.solar_position(solar.jd_midnight + ut_hours / 24.0)
    lat = math.radians(solar.latitude)
    dec = math.radians(declination)
    # Hour angle from solar transit.
    h = math.radians((ut_hours - solar.transit) * 15.0)
    sin_alt = math.sin(lat) * math.sin(dec) + math.cos(lat) * math.cos(dec) * math.cos(h)
    return math.degrees(math.asin(sin_alt)), declination


def implied_factor(solar, ut_hours):
    altitude, declination = altitude_at(solar, ut_hours)
    noon_zenith = abs(solar.latitude - declination)
    shadow_ratio = 1.0 / math.tan(math.radians(altitude))
    return shadow_ratio - math.tan(math.radians(noon_zenith))


print("implied Asr shadow factor at each implementation's time\n")
print("case".ljust(32) + "declared".rjust(9) + "aladhan".rjust(10) + "awqat".rjust(9))
print("-" * 60)

for c in v.CASES:
    solar = v.SolarDay(c["date"][0], c["date"][1], c["date"][2], c["lat"], c["lng"])

    hh, mm = (int(p) for p in c["expected"]["asr"].split(":"))
    aladhan_ut = hh + mm / 60.0 - c["utc_offset"]
    awqat_ut = solar.asr_time(c["shadow"])

    print(
        c["name"][:30].ljust(32)
        + "{:9.1f}".format(c["shadow"])
        + "{:10.4f}".format(implied_factor(solar, aladhan_ut))
        + "{:9.4f}".format(implied_factor(solar, awqat_ut))
    )

print()
print("Note: AlAdhan publishes whole minutes, so its implied factor carries up to")
print("30 s of quantisation. A consistent offset in one direction is not that.")
