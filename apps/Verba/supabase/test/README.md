# Schema tests

`verify_schema.py` applies Verba's real `../schema.sql` to a real PostgreSQL
server and checks the parts that fail without raising.

## Why this exists separately from `validation/verify_upsert.py`

That one models the upsert in SQLite. It proves the coalesce rules are right,
and it proves nothing about Postgres. The riskiest code in the schema is the
Postgres-specific part, and it is dangerous for the same reason the haptic rate
limit and the Asr calculation were: **wrong answers, no error.**

| What could break | What you would see |
|---|---|
| An RLS policy compares the wrong column | Every user reads every other user's recordings. No error. |
| The `with check` clause is dropped from the update policy | A client can reassign someone else's row to itself. No error. |
| `pg_trgm` is missing, or the opclass is wrong | `ilike '%...%'` still returns correct rows — by reading the whole table. Shows up as a slow app in six months. |
| Postgres gains a Chinese segmenter | The comment in `schema.sql` explaining why the trigram index exists becomes wrong, and nothing complains. |
| The storage path policy indexes the wrong segment | Audio is readable across accounts. No error. |

54 checks, all of them run as a client rather than as the database owner —
which is the whole point, since **RLS is bypassed for superusers and table
owners**. Running the suite as `postgres` would make every policy assertion
pass regardless of whether the policies were correct. `verify_schema.py`
asserts that it is connected as a superuser and then `set role authenticated`,
so the trap is visible rather than silent.

## Running it

Any PostgreSQL 14+ with the contrib modules works. In CI it is a
`postgres:16` service container; see the `postgres-schema` job in
`.github/workflows/build.yml`.

```sh
pip install "psycopg[binary]"
python verify_schema.py --dsn "postgresql://postgres@127.0.0.1:54329/postgres"
```

The script drops and recreates the `public`, `auth` and `storage` schemas on
every run, so point it at a scratch database — **never at your Supabase
project**.

### On a machine with no Docker and no admin rights

The portable Windows build needs neither. This is how the suite was first run:

```powershell
$tools = "C:/Register/code/workspace/dialogues/20260903-1825-watch-app-research/.tools"

# 323 MB, no installer, no admin rights
Invoke-WebRequest -UseBasicParsing `
  -Uri "https://get.enterprisedb.com/postgresql/postgresql-16.4-1-windows-x64-binaries.zip" `
  -OutFile "$tools/pg.zip"
Expand-Archive "$tools/pg.zip" -DestinationPath $tools

& "$tools/pgsql/bin/initdb.exe" -D "$tools/pgdata" -E UTF8 --locale=C -U postgres --auth=trust
& "$tools/pgsql/bin/pg_ctl.exe" -D "$tools/pgdata" -o "-p 54329 -c listen_addresses=127.0.0.1" start
```

`-E UTF8` matters: the Chinese and Japanese search assertions are meaningless
on a SQL_ASCII cluster. `.tools/` is gitignored.

To stop it:

```powershell
& "$tools/pgsql/bin/pg_ctl.exe" -D "$tools/pgdata" stop
```

## `shim.sql`

Everything Supabase provides that plain Postgres does not: the `auth` and
`storage` schemas, `auth.uid()` reading the request's JWT claims out of a
session GUC, `storage.foldername()`, and the `anon` / `authenticated` /
`service_role` roles.

Definitions follow Supabase's own. Two details are load-bearing:

- **`auth.uid()` returns null when unauthenticated.** Every policy compares
  `auth.uid() = user_id`, and null equals nothing, so an unauthenticated
  request sees zero rows rather than all of them. There is a check for this.
- **`storage.foldername()` drops the last path segment**, so for
  `<user_id>/<memo_id>.m4a` the first element is the owner. Returning all
  segments would still make `[1]` the owner and would still pass a naive test,
  which is why the function is asserted directly.

`schema.sql` is never modified to accommodate the shim. The file that ships is
the file that gets tested.
