import verify_astronomy as v


def raw_times(c):
    s = v.SolarDay(c["date"][0], c["date"][1], c["date"][2], c["lat"], c["lng"])
    sunrise, sunset, transit = s.sunrise, s.sunset, s.transit
    night = (sunrise + 24) - sunset

    kind, val = c["isha_rule"]
    fajr_limit = sunrise - v.night_portion(c["fajr_angle"], v.HIGH_LAT_TWILIGHT, night)
    cf = s.time_at_altitude(-c["fajr_angle"], after_transit=False)
    fajr = fajr_limit if cf is None else max(cf, fajr_limit)

    if kind == "interval":
        isha = sunset + val / 60.0
    else:
        lim = sunset + v.night_portion(val, v.HIGH_LAT_TWILIGHT, night)
        ci = s.time_at_altitude(-val, after_transit=True)
        isha = lim if ci is None else min(ci, lim)

    return {
        "fajr": fajr,
        "sunrise": sunrise,
        "dhuhr": transit,
        "asr": s.asr_time(c["shadow"]),
        "maghrib": sunset,
        "isha": isha,
    }, s.jd_midnight


print("raw (unrounded) delta vs AlAdhan published time, seconds\n")
header = "case".ljust(32) + "".join(p.rjust(10) for p in
                                    ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"])
print(header)
print("-" * len(header))

for c in v.CASES:
    times, jd_midnight = raw_times(c)
    row = c["name"][:30].ljust(32)
    for p in ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"]:
        jd = jd_midnight + times[p] / 24.0
        unix = (jd - 2440587.5) * 86400.0
        want = v.expected_instant(c["expected"][p], c["date"], c["utc_offset"])
        row += "{:+10.1f}".format(unix - want)
    print(row)
