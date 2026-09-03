import verify_astronomy as v

for c in v.CASES:
    s = v.SolarDay(c["date"][0], c["date"][1], c["date"][2], c["lat"], c["lng"])
    raw = s.asr_time(c["shadow"])
    jd = s.jd_midnight + raw / 24.0
    unix = (jd - 2440587.5) * 86400.0
    want = v.expected_instant(c["expected"]["asr"], c["date"], c["utc_offset"])
    secs_into_minute = unix % 60
    print(
        "{:<30} shadow={}  raw_delta={:+7.1f}s  seconds_into_minute={:4.1f}".format(
            c["name"][:30], c["shadow"], unix - want, secs_into_minute
        )
    )
