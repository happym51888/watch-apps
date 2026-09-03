# Verba on the web

Search, play and edit everything the watch recorded, from a laptop.

No build step, no backend. Three static files plus the Supabase JS client from
a CDN. The "backend" is the same Postgres the iPhone app writes to, reached
through Supabase's REST API with the user's own access token.

## Running it

```sh
cp config.example.js config.js
# fill in url + anonKey from your Supabase project settings
```

Then serve the directory over HTTP. Any static server will do:

```sh
python -m http.server 8000
# then open http://localhost:8000
```

`file://` will not work — ES module imports and the auth session both need a
real origin.

To host it, upload these four files anywhere static: GitHub Pages, Cloudflare
Pages, Netlify, an S3 bucket. There is nothing to compile and nothing to keep
running.

## What it does

- **Sign in** with the same email and password the iPhone app uses.
- **Search** transcripts as you type, debounced.
- **Play** the original audio, streamed from the private bucket via a
  short-lived signed URL minted on demand.
- **Edit** any transcript in place. Click into the text, change it, click away.
  A human correction sets `transcript_engine = 'manual'`, which is how the rest
  of the system knows never to overwrite it with a machine result.
- **Copy** the text to the clipboard.

## Two decisions worth knowing about

**Search uses `ilike`, not full-text search.** The schema has a `tsvector`
column and a GIN index on it, and it is the wrong tool here. Postgres has no
Chinese segmenter, so `to_tsvector('simple', '明天下午三点开会')` produces a
single token — full-text search over Chinese transcripts matches nothing unless
you happen to type the whole sentence, and it returns an *empty result* rather
than an error, so it looks like you have no matching recordings. Substring
search works in every language. The `pg_trgm` GIN index in `schema.sql` is what
stops `ilike '%…%'` from being a full table scan.

**Paging is keyset, not `OFFSET`.** Rows arrive from the watch while you are
scrolling. With `OFFSET`, a memo syncing mid-scroll shifts everything down and
the next page silently skips or repeats a row. Paging on `started_at < cursor`
cannot do that.

## Security

The anon key sits in `config.js` in plain sight, which is the intended design —
it identifies the project, not the user. Every request carries the signed-in
user's own token, and **Row Level Security is what actually enforces ownership**.
Apply `../supabase/schema.sql` before pointing a real key at this. With RLS off,
an anon key in a public web page is a world-readable, world-writable database.

Never put the `service_role` key here. It bypasses RLS entirely and in a
browser it is visible to anyone who opens the network tab.

## Not built

- **Recording from the browser.** `MediaRecorder` would work, but transcription
  would then need a cloud model and a paid API key, and this app's whole premise
  is that transcription is free and on-device. Record on the watch or the phone.
- **Realtime updates.** Supabase can push changes over a websocket; this
  reloads on search or on a manual "Load older". Adding realtime is a few lines
  if the list going stale ever becomes annoying.
- **Delete.** The RLS policy allows it and the API is one call, but a delete
  button next to an in-place text editor on a corpus of things you said is a
  bad idea without an undo, and undo is a bigger change than it looks.
