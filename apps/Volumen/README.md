# Volumen — audiobooks on the watch, with chapters, that keep your place

iPhone app to load the files, watch app to play them. Nothing streams, nothing
phones home, nothing expires.

## Why this app

The research report already looked at this and threw it out:

> | 离线 Spotify / Audible / Libby | 长期抱怨 | DRM 墙，不是代码问题 |

That judgement is correct and it stands. Audible, Spotify and Libby cannot be
reimplemented, and no amount of code changes that.

But the DRM wall does not cover the whole shelf. **LibriVox is public domain,
DRM-free purchases exist, and people record their own audio.** Those files are
untouched by the thing that made the category impossible — and they are exactly
the files nobody built a decent watch player for, because the interesting part
of the market was behind the wall.

So this is not an argument against the report's conclusion. It is picking up
what the conclusion left on the floor.

## What actually goes wrong in an audiobook player

None of it crashes. That is the point.

**The boundary belongs to the file that follows it.** A position exactly at the
end of chapter 3 is the start of chapter 4. Attribute it to the earlier file
and every session that ends on a chapter break either replays a whole file or
skips one. In the reference corpus this misplaces a position in **120 of 120**
books.

**A book is as long as its files, not as long as it says it is.** Of 234 real
LibriVox books, **103 disagree with their own declared total.** The worst is
*The Count of Monte Cristo*: it declares 49.72 hours and its files add to 54.95.
Trust the declaration and "time remaining" is wrong at every position in the
book — up to **313 minutes** wrong — while looking perfectly plausible.

**A bookmark must survive the library changing.** Store it as an offset from
the start of the book and inserting a missing chapter 2 silently moves every
saved position in every book. Volumen anchors to file identity, derived from a
content hash of the first 64 KB plus the exact byte count, so re-downloading or
re-encoding a file keeps the place and inserting a new one does not disturb it.
If a file disappears entirely, the mark falls back to its absolute position
against the previous contents rather than resetting to zero.

**Milliseconds do not fit in a Float.** Past 2^24 ms — 4h39m, which **72 of 234
books** exceed — consecutive Float values are more than a millisecond apart.
The trap is that file boundaries usually survive, because they tend to be round
numbers; the loss only shows where a listener actually pauses. Positions are
`Int64` milliseconds throughout, and the test pauses mid-sentence rather than
on a boundary, because a boundary-only test is how this bug reaches somebody's
ears.

**Chapters are not files.** Sometimes a chapter is a file; sometimes one file
holds twelve chapters as ID3 `CHAP` frames; sometimes a chapter spans a
boundary. All three are handled, and audio before the first mark is kept rather
than dropped.

## The ID3 detail that eats chapter support

ID3v2.3 writes frame sizes as plain 32-bit integers. ID3v2.4 writes them
**syncsafe**, seven bits per byte. Of the first 4,096 sizes, **128 read the same
either way and 3,968 do not** — so any frame past 128 bytes lands on the wrong
offset if the version byte is misread, and a chapter title is comfortably past
128 bytes.

The parser refuses a version mismatch outright instead of guessing:

- v2.3 bytes read as v2.4: rejected
- v2.4 bytes read as v2.3: rejected

Text encoding is read from the marker byte rather than assumed. `Chapter 1`
written as UTF-16 and read as Latin-1 gives `ÿþC` — three characters, not
nine — which is the kind of thing that ships.

## What is verified

```sh
python validation/verify_book.py  # PASS (50,595 assertions)
python validation/verify_id3.py   # PASS (115 assertions)
```

`verify_book.py` runs the position model over **234 real LibriVox books, 5,288
files, 1,254 hours**, fetched once from `librivox.org/api/feed/audiobooks` and
committed as a fixture. 19,140 positions round-trip; positions never move
backwards; every hazard above is then reintroduced on purpose and has to show
up in the numbers, or the check is not measuring anything.

`verify_id3.py` cross-parses with **mutagen** — bytes written here read by
mutagen, bytes written by mutagen read here. The value of that check is that
mutagen is somebody else's code, so it refuses to pass when mutagen is missing
rather than skipping quietly. CI installs it for exactly that reason.

What this does not cover: no real audio is decoded anywhere in the validation.
Everything above is metadata and arithmetic. Whether `AVAudioPlayer` on an
actual watch resumes at the millisecond it was told is a device question, and
CI cannot answer it.

## Layout

```
Package.swift                SwiftPM library, so the logic is testable anywhere
Sources/VolumenCore/         Pure logic. No AVFoundation, no SwiftUI.
  Book.swift                 Files, positions, bookmarks, chapters
  ID3Chapters.swift          CHAP / CTOC, v2.3 and v2.4
  PlaybackState.swift        Transport and sleep timer as a state machine
  TrackIdentity.swift        Content hash + byte count
Tests/VolumenCoreTests/      The hazards above, one test each
validation/                  LibriVox corpus, mutations, mutagen cross-parse
PhoneApp/                    Pick files, sort them properly, send
WatchApp/                    Library, now playing, chapter list
```

`PlaybackState` returns actions rather than performing them — `load`, `play`,
`persist`, `reportJump` — which is why the sleep timer can be tested without an
audio session. It counts *playing* time, not wall-clock: a timer set for thirty
minutes and then paused for an hour still has thirty minutes left.

## Not done in v1

- **No streaming and no DRM.** Local, unencrypted files only. This is the
  premise, not a limitation to fix later.
- **No sync back to a phone library.** The watch keeps its own place.
- **No variable speed.** It changes what "time remaining" means and interacts
  with the sleep timer; worth doing properly rather than quickly.
- **No complication.**

## Before submitting

Nothing here needs a background mode argument the way Tactus does — an audio
player using the `audio` background mode is the case that mode exists for.

The privacy manifest declares `FileTimestamp` (reason `3B52.1`) because
deriving track identity reads file attributes. It collects nothing and tracks
nothing.
