# Proxima — the next departure, with the network switched off

iPhone app to build the timetable, watch app to read it. No account, no
subscription, no request at the moment you need the answer.

## Why this app

Unlike the other five in this repo, **this one is not backed by user quotes.**
The research report has no transit candidate in it, and inventing a Reddit
thread to justify a decision already made would be worse than admitting the
gap. The argument here is about the platform, and it can be checked:

A timetable is static. "When does the next 31 leave?" is arithmetic over a file
the agency published weeks ago — the answer does not depend on anything that
happens between now and the moment you ask. Yet the usual way to get it on a
watch is a request, over the least reliable link the device has, at the exact
moment you are underground and about to miss the thing.

So the design is: do the arithmetic on the wrist, from a file that is already
there. That makes the app worth building only if the arithmetic is right, and
**getting it wrong does not throw** — a departure board that is confidently an
hour off looks exactly like one that is correct. That property is what made it
a good candidate for a machine with no Mac: it can be checked against somebody
else's published answers.

## The one rule the whole app rests on

GTFS times are not clock times. They are seconds elapsed since the service day
began, and the service day begins at **noon minus twelve hours**, not midnight.

On 363 days a year those are the same instant, which is why the wrong version
survives testing. On the other two:

| | 8 March 2026, Los Angeles | |
|---|---|---|
| service day starts | 23:00 PST on the 7th | noon PDT − 12h |
| a trip listed `08:00:00` | departs **08:00** PDT | the time the agency printed |
| anchored at midnight instead | departs 09:00 PDT | an hour after the bus left |

The rule exists to make the published time survive the clock change. Anchor at
midnight and every departure on a DST day is announced an hour wrong, in the
direction that makes you miss it.

Four more that fail the same silent way, all pinned by tests:

- **Times run past `24:00:00`.** A trip listed `25:30:00` on Saturday leaves at
  01:30 Sunday morning and is still Saturday's service. Take the hours modulo
  24 and it vanishes from the board at exactly the hour people need it.
- **`calendar_dates.txt` overrides `calendar.txt`.** Ignore it and the app runs
  a normal Thursday timetable on Christmas Day. In the Oslo fixture this breaks
  **89 of 89** cases, because that feed uses exceptions for everything.
- **`pickup_type=1` means the vehicle passes without boarding.** It is a stop
  in the file and not a departure on a board.
- **The last stop of a trip is an arrival.** Offer it and you send somebody to
  a platform to catch a bus that terminates there.

The engine looks back two service days and **refuses a feed** with anything at
or past `72:00:00` rather than silently resolving it against the wrong day.

## What is verified

The engine was replayed against **Entur's journey planner** — the Norwegian
national authority, answering for the same Oslo stops from the same published
Ruter feed — over **89 cases and 1,191 departure instants, with no
disagreement**.

Then every hazard was put back on purpose, because a check that nothing can
fail is not a check:

| mutation | cases broken |
|---|---|
| service day anchored at midnight | 13 / 89, all on DST days |
| departure hours taken modulo 24 | 15 / 89 |
| `calendar_dates.txt` ignored | 89 / 89 |
| `pickup_type=1` treated as boardable | 16 / 89 |
| yesterday's service day not considered | 25 / 89 |

Two hazards are inert on real data — Ruter publishes no `calendar.txt`, and
none of its terminal arrivals are boardable — so those are pinned by hand-built
feeds instead, and the validator says so rather than implying coverage it does
not have.

```sh
python validation/verify_gtfs.py           # PASS (670 assertions)
python validation/verify_swift_vectors.py  # PASS (49 expectations)
```

The second one matters more than it looks. A passing XCTest only proves Swift
agrees with whatever the assertion says, and **two of these assertions were
wrong when written**. `verify_swift_vectors.py` rebuilds the same hand-made
feeds and re-derives every expected value with the engine the Entur replay
validated, so a Swift test can only be green for the right reason. It caught
both: a lookback constant that disagreed with the reference implementation, and
a DST assertion that had the departure moving when the entire point of the rule
is that it does not.

Neither validator touches the network. The Oslo instants were fetched once and
committed, so CI replays them.

### A second reader, and the one thing it drops

`_partridge_crosscheck.py` reads the same fixture with
[partridge](https://github.com/remix/partridge), an unrelated GTFS library, and
compares. Trips, routes, `stop_times` rows, `calendar_dates` rows and every
field of a sampled trip agree exactly.

`stops.txt` does not, and the difference is the interesting part. The file has
**74 rows: 42 quays and 32 stations.** partridge prunes to the 42, because a
station never appears in `stop_times` — a bus calls at a platform, not at a
building. That is a reasonable thing for a analysis library to do and a fatal
thing for this app to do: those 32 rows are the whole basis of "asking about a
station asks about its platforms", which is the shape of stop a person actually
names out loud. Load the pruned view and the app cannot answer for any station
at all.

Not in CI — partridge pulls in pandas, numpy and networkx, which is a lot of
runner for a check the Entur replay mostly subsumes. Run it by hand:

```sh
.venv/Scripts/python.exe validation/_partridge_crosscheck.py
```

## How it works

The phone does the heavy lifting once; the watch does arithmetic forever.

```
GTFS .zip  →  ZipReader  →  SliceCompiler  →  slice.json  →  watch
  (phone, once)                                (WatchConnectivity)
```

`SliceCompiler` keeps only what a board needs: the stops you picked, every trip
that calls at them kept whole, and the calendars those trips reference. It
drops rows that can never be a departure — terminal arrivals, `pickup_type=1` —
so the watch never has to know those rules. Blank times are interpolated
between the timepoints that bracket them rather than dropped or zeroed.

`ZipReader` is about 240 lines and reads the central directory rather than
trusting local headers, verifying CRC-32 on the way out. A partial download
that would otherwise decompress into a plausible-looking truncated feed is
caught here instead of becoming a board that is quietly missing its last
routes.

The watch stores the slice, refreshes the countdown every ten seconds, and says
so when the slice has expired or has not started yet — derived from the
calendars actually present, not from whatever `feed_info.txt` claims. Feeds do
disagree with themselves about this, and the fixture is flagged as one.

## Layout

```
Package.swift                SwiftPM library, so the logic is testable anywhere
Sources/ProximaCore/         Pure logic. No WatchKit, no SwiftUI.
  ServiceDate.swift          Civil-date arithmetic, no Calendar, 1887–2134
  Timetable.swift            Calendars, exceptions, service day origin
  Departures.swift           "What leaves here next"
  SliceCompiler.swift        GTFS text → the smallest thing a watch needs
  CSV.swift                  RFC 4180, including the CRLF that Swift hides
Tests/ProximaCoreTests/      The hazards above, one test each
validation/                  Entur replay, mutations, Swift vector re-derivation
PhoneApp/                    Feed download, zip, stop picker, send
WatchApp/                    The board
```

## Not done in v1

- **No complication.** The board is one tap from the face; a complication that
  needs its own refresh budget is a second thing to get wrong.
- **No live delays.** The app is honest about this on screen: these are
  scheduled times. Adding GTFS-Realtime means adding a network dependency,
  which is the thing it exists to avoid.
- **No route planning.** It answers "what leaves from here", not "how do I get
  there".
- **Manual refresh of the feed.** Agencies republish; the watch shows how old
  its slice is and the phone rebuilds on demand.
