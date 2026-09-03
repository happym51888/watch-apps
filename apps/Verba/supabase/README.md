# Setting up the database

Verba stores recordings in one Supabase project that you own. Users get an
account in it; they do not bring their own database. That decision is worth
stating because it drives everything below: it means **you** are responsible
for the isolation between accounts, and that isolation is enforced by Row
Level Security rather than by application code.

Free tier covers this comfortably — 500 MB of Postgres and 1 GB of storage is
a few thousand voice memos at 16 kHz mono AAC.

## 1. Create the project

At [supabase.com/dashboard](https://supabase.com/dashboard): new project, pick
a region near your users, save the database password somewhere. Provisioning
takes a couple of minutes.

## 2. Apply the schema

SQL Editor → paste all of [`schema.sql`](schema.sql) → Run. It is idempotent
(`create ... if not exists`, `drop policy if exists`), so re-running it after
an edit is safe.

Or with the CLI:

```sh
supabase link --project-ref YOUR-PROJECT-REF
supabase db push
```

This creates the `memos` table, both search indexes, the `updated_at` trigger,
the RLS policies, the `memo-audio` bucket with its own policies, and the
`upsert_memo` function.

Confirm it took:

```sql
select count(*) from pg_policies where tablename = 'memos';   -- 4
select relrowsecurity from pg_class where oid = 'public.memos'::regclass;  -- t
select id, public from storage.buckets where id = 'memo-audio'; -- memo-audio, f
```

If `relrowsecurity` is false, stop. An anon key against a table without RLS is
a world-readable, world-writable database.

## 3. Create a user

Authentication → Users → Add user. Email and password; the iPhone app and the
web client both sign in with these.

For real users, turn off open sign-ups (Authentication → Providers → Email →
disable "Enable sign ups") unless you actually want anyone to be able to
register. Nothing in the schema limits who can create an account.

## 4. Point the clients at it

Both need the project URL and the **anon** key, from Settings → API.

```sh
# iPhone app
cp PhoneApp/Supabase.example.plist PhoneApp/Supabase.plist

# Web client
cp web/config.example.js web/config.js
```

Fill in `url` and `anonKey` in each. Both files are gitignored.

The anon key is meant to be public — it identifies the project, not the user.
Every request carries the signed-in user's own token and RLS is what enforces
ownership. **Never put the `service_role` key in either file**; it bypasses RLS
entirely, and in a browser it is visible to anyone who opens the network tab.

## 5. Verify it end to end

```sh
python supabase/test/smoke_test.py \
    --url https://YOUR-PROJECT-REF.supabase.co \
    --anon-key "YOUR-ANON-KEY" \
    --email you@example.com \
    --password "..."
```

Standard library only, plain REST, the same calls
`PhoneApp/SupabaseStore.swift` makes — so a pass means the app's actual code
path works. It signs in, writes a memo, redelivers it to prove the transcript
is not blanked, uploads audio, mints a signed URL, checks the unsigned public
URL is refused, tries to write into someone else's folder, searches for a
Chinese substring, then deletes everything it created.

Add a second account to check isolation between two live users, which is the
one thing worth testing with real accounts rather than in a model:

```sh
    --other-email second@example.com --other-password "..."
```

Without it, that group is reported as skipped rather than passed.

## What is already verified without your project

[`test/verify_schema.py`](test/verify_schema.py) applies this exact
`schema.sql` to a real PostgreSQL server and runs 54 checks against it — RLS
isolation, forged inserts, row reassignment, upsert convergence, Chinese and
Japanese search, the trigram index, storage path policies. It runs in CI on
every push against a `postgres:16` container.

So the SQL is known good before it reaches your project. The smoke test above
covers the part that verification cannot: that *your* project actually has it
applied, with the bucket created and the keys wired up.

## Storage layout

```
memo-audio/
  <user_id>/
    <memo_id>.m4a
```

The first path segment is the owner, which is what the storage policies compare
against `auth.uid()`. Changing this layout means changing those four policies.

## Notes

- **`upsert_memo` rather than a plain insert.** The recording id is minted on
  the watch, so redelivery is a primary-key conflict rather than a duplicate
  row, and the function's `coalesce(new, old)` rules mean a later write can fill
  in a missing field but never blanks one that is already populated. The audio
  row and the transcript legitimately arrive in either order.
- **Audio lives in Storage, not in a `bytea` column.** Postgres will happily
  store a 15 MB blob and then make every `select *` miserable.
- **Both search indexes exist on purpose.** The `tsvector` one for languages
  with word boundaries; the `pg_trgm` one because full-text search over Chinese
  returns an empty result rather than an error. See the comments in
  `schema.sql` and the "Two decisions" section of `../web/README.md`.
