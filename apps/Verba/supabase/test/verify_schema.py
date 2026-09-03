"""
Run Verba's real `schema.sql` against a real PostgreSQL server and check the
parts that fail silently.

`validation/verify_upsert.py` models the upsert in SQLite. That catches logic
errors in the coalesce rules but it cannot catch anything about Postgres
itself, and the riskiest code in the schema is precisely the Postgres-specific
part:

  * A wrong Row Level Security policy does not raise. It returns other
    people's recordings. There is no error to notice.
  * `ilike '%...%'` keeps working when the trigram index is missing or unused.
    It just reads every row, so the failure shows up as a slow app months
    later, not as a bug.
  * Full-text search over Chinese returns zero rows rather than an error,
    which is the reason the trigram index exists at all. If that ever stops
    being true, the comment in schema.sql becomes wrong and nothing complains.

So this applies `shim.sql` (everything Supabase would provide) followed by the
unmodified `schema.sql`, then impersonates real users the way Supabase does —
`set role authenticated` plus a `request.jwt.claims` GUC — and asserts.

Running as superuser would make every policy assertion pass whether or not the
policies are right, because RLS is bypassed for superusers and table owners.
That trap is checked explicitly in `test_rls_is_actually_enforced`.

Usage:
    python verify_schema.py --dsn "postgresql://postgres@127.0.0.1:54329/postgres"
"""

from __future__ import annotations

import argparse
import contextlib
import pathlib
import random
import sys
import uuid

import psycopg

HERE = pathlib.Path(__file__).resolve().parent
SHIM = HERE / "shim.sql"
SCHEMA = HERE.parent / "schema.sql"

checks = 0
failures: list[str] = []


def check(condition: bool, label: str, detail: str = "") -> None:
    global checks
    checks += 1
    if condition:
        print(f"  ok    {label}")
    else:
        print(f"  FAIL  {label}{(' — ' + detail) if detail else ''}")
        failures.append(f"{label}{(' — ' + detail) if detail else ''}")


def section(title: str) -> None:
    print(f"\n{title}")
    print("-" * len(title))


@contextlib.contextmanager
def as_user(conn: psycopg.Connection, user_id: str | None):
    """Impersonate a Supabase client the way the PostgREST layer does.

    `set_config(..., is_local => true)` rather than `SET LOCAL` because `SET`
    takes no parameters. Both are transaction-scoped, so the role and claims
    unwind on exit and cannot leak into the next assertion.
    """
    with conn.transaction():
        with conn.cursor() as cur:
            claims = f'{{"sub":"{user_id}","role":"authenticated"}}' if user_id else "{}"
            cur.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
            cur.execute("set local role authenticated")
            yield cur


def reset_database(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("drop schema if exists public cascade")
        cur.execute("drop schema if exists auth cascade")
        cur.execute("drop schema if exists storage cascade")
        cur.execute("create schema public")
    conn.commit()


def apply_sql(conn: psycopg.Connection, path: pathlib.Path) -> None:
    with conn.cursor() as cur:
        cur.execute(path.read_text(encoding="utf-8"))
    conn.commit()


def grant_client_access(conn: psycopg.Connection) -> None:
    """Grants Supabase applies to public tables after they exist."""
    with conn.cursor() as cur:
        cur.execute("grant select, insert, update, delete on public.memos to authenticated")
        cur.execute("grant execute on function public.upsert_memo to authenticated")
    conn.commit()


def make_user(conn: psycopg.Connection, email: str) -> str:
    with conn.cursor() as cur:
        cur.execute(
            "insert into auth.users (id, email) values (gen_random_uuid(), %s) returning id",
            (email,),
        )
        user_id = str(cur.fetchone()[0])
    conn.commit()
    return user_id


def insert_memo(cur, memo_id: str, started_at: str, **kwargs) -> None:
    cur.execute(
        """
        select public.upsert_memo(
            p_id => %(id)s,
            p_started_at => %(started_at)s,
            p_duration_seconds => %(duration)s,
            p_byte_count => %(bytes)s,
            p_source_device => %(device)s,
            p_audio_path => %(audio_path)s,
            p_transcript => %(transcript)s,
            p_transcript_locale => %(locale)s,
            p_transcript_engine => %(engine)s,
            p_transcript_confidence => %(confidence)s,
            p_title => %(title)s
        )
        """,
        {
            "id": memo_id,
            "started_at": started_at,
            "duration": kwargs.get("duration", 10.0),
            "bytes": kwargs.get("bytes", 1024),
            "device": kwargs.get("device", "watch"),
            "audio_path": kwargs.get("audio_path"),
            "transcript": kwargs.get("transcript"),
            "locale": kwargs.get("locale"),
            "engine": kwargs.get("engine"),
            "confidence": kwargs.get("confidence"),
            "title": kwargs.get("title"),
        },
    )


# ---------------------------------------------------------------------------
# Row Level Security
# ---------------------------------------------------------------------------


def test_rls_is_actually_enforced(conn, alice, bob):
    section("Row Level Security")

    # The trap this whole file is guarding against: if the assertions below ran
    # as superuser or as the table owner, RLS would be bypassed and they would
    # all pass no matter what the policies said.
    with conn.cursor() as cur:
        cur.execute("select relrowsecurity from pg_class where oid = 'public.memos'::regclass")
        check(cur.fetchone()[0] is True, "RLS is enabled on public.memos")

        cur.execute("select current_user")
        owner_is_superuser = cur.fetchone()[0]
        cur.execute("select usesuper from pg_user where usename = current_user")
        check(
            cur.fetchone()[0] is True,
            "harness connects as a superuser",
            "so 'set role authenticated' below is what makes policies apply",
        )
    conn.rollback()

    with as_user(conn, alice) as cur:
        cur.execute("select current_user")
        check(cur.fetchone()[0] == "authenticated", "impersonation switches role")
        cur.execute("select auth.uid()::text")
        check(cur.fetchone()[0] == alice, "auth.uid() reads the injected claim")

    # Alice writes two memos, Bob writes one.
    with as_user(conn, alice) as cur:
        insert_memo(cur, "a-1", "2026-01-01T08:00:00Z", transcript="alice first")
        insert_memo(cur, "a-2", "2026-01-02T08:00:00Z", transcript="alice second")
    with as_user(conn, bob) as cur:
        insert_memo(cur, "b-1", "2026-01-03T08:00:00Z", transcript="bob only")

    with as_user(conn, alice) as cur:
        cur.execute("select id from public.memos order by id")
        rows = [r[0] for r in cur.fetchall()]
        check(rows == ["a-1", "a-2"], "select returns only own rows", f"got {rows}")

    with as_user(conn, bob) as cur:
        cur.execute("select id from public.memos order by id")
        rows = [r[0] for r in cur.fetchall()]
        check(rows == ["b-1"], "the other user sees only their own", f"got {rows}")

    with as_user(conn, None) as cur:
        cur.execute("select count(*) from public.memos")
        check(cur.fetchone()[0] == 0, "unauthenticated request sees nothing")

    # user_id is assigned from auth.uid() inside upsert_memo, so a client
    # cannot claim someone else's id through the function. A raw insert is the
    # path that has to be blocked by policy.
    forged = False
    try:
        with as_user(conn, alice) as cur:
            cur.execute(
                """
                insert into public.memos (id, user_id, started_at, source_device)
                values ('forged', %s, now(), 'watch')
                """,
                (bob,),
            )
        forged = True
    except psycopg.errors.InsufficientPrivilege:
        pass
    check(not forged, "cannot insert a row owned by another user")

    stolen = False
    try:
        with as_user(conn, alice) as cur:
            cur.execute("update public.memos set user_id = %s where id = 'a-1'", (bob,))
        stolen = True
    except psycopg.errors.InsufficientPrivilege:
        pass
    check(not stolen, "cannot reassign own row to another user", "the with-check clause")

    with as_user(conn, bob) as cur:
        cur.execute("update public.memos set transcript = 'hijacked' where id = 'a-1'")
        check(cur.rowcount == 0, "cannot update another user's row")
        cur.execute("delete from public.memos where id = 'a-1'")
        check(cur.rowcount == 0, "cannot delete another user's row")

    with as_user(conn, alice) as cur:
        cur.execute("select transcript from public.memos where id = 'a-1'")
        check(cur.fetchone()[0] == "alice first", "the untouched row is intact")


# ---------------------------------------------------------------------------
# upsert_memo
# ---------------------------------------------------------------------------


def test_upsert_semantics(conn, alice):
    section("upsert_memo")

    with as_user(conn, alice) as cur:
        insert_memo(cur, "u-1", "2026-02-01T08:00:00Z", duration=30.0, bytes=5000)
        insert_memo(cur, "u-1", "2026-02-01T08:00:00Z", duration=30.0, bytes=5000)
        cur.execute("select count(*) from public.memos where id = 'u-1'")
        check(cur.fetchone()[0] == 1, "redelivery is idempotent, not a duplicate row")

    # The failure mode that matters: transcription lands, then the audio row is
    # redelivered with no transcript. A plain `do update set transcript =
    # excluded.transcript` would blank it and the user would see an empty memo.
    with as_user(conn, alice) as cur:
        insert_memo(cur, "u-2", "2026-02-02T08:00:00Z", transcript="the real words", title="T")
        insert_memo(cur, "u-2", "2026-02-02T08:00:00Z", audio_path="alice/u-2.m4a")
        cur.execute("select transcript, title, audio_path from public.memos where id = 'u-2'")
        transcript, title, audio = cur.fetchone()
        check(transcript == "the real words", "a later write never blanks the transcript")
        check(title == "T", "a later write never blanks the title")
        check(audio == "alice/u-2.m4a", "the later write still fills in the missing field")

    with as_user(conn, alice) as cur:
        insert_memo(cur, "u-3", "2026-02-03T08:00:00Z", duration=12.0, bytes=100)
        insert_memo(cur, "u-3", "2026-02-03T08:00:00Z", duration=95.5, bytes=90000)
        insert_memo(cur, "u-3", "2026-02-03T08:00:00Z", duration=40.0, bytes=500)
        cur.execute("select duration_seconds, byte_count from public.memos where id = 'u-3'")
        duration, byte_count = cur.fetchone()
        check(duration == 95.5, "duration converges upward", f"got {duration}")
        check(byte_count == 90000, "byte count converges upward", f"got {byte_count}")

    # Three partial writes can arrive in any order. All six orderings must
    # produce the same row, or the result depends on network timing.
    parts = [
        {"audio_path": "alice/x.m4a"},
        {"transcript": "hello there", "locale": "en-US", "engine": "appleOnDevice", "confidence": 0.9},
        {"title": "Hello there"},
    ]
    finals = set()
    for order in [(0, 1, 2), (0, 2, 1), (1, 0, 2), (1, 2, 0), (2, 0, 1), (2, 1, 0)]:
        memo_id = f"order-{''.join(str(i) for i in order)}"
        with as_user(conn, alice) as cur:
            for index in order:
                insert_memo(cur, memo_id, "2026-02-04T08:00:00Z", **parts[index])
            cur.execute(
                """
                select audio_path, transcript, transcript_locale, transcript_engine,
                       transcript_confidence, title
                from public.memos where id = %s
                """,
                (memo_id,),
            )
            finals.add(cur.fetchone())
    check(len(finals) == 1, "all six arrival orderings converge to one row", f"{len(finals)} distinct")
    check(
        finals and next(iter(finals))[1] == "hello there",
        "and it is the fully populated row",
    )

    with as_user(conn, alice) as cur:
        cur.execute("select updated_at from public.memos where id = 'u-2'")
        before = cur.fetchone()[0]
        cur.execute("update public.memos set transcript = 'edited' where id = 'u-2'")
        cur.execute("select updated_at from public.memos where id = 'u-2'")
        check(cur.fetchone()[0] > before, "the updated_at trigger fires on update")


# ---------------------------------------------------------------------------
# Constraints
# ---------------------------------------------------------------------------


def test_constraints(conn, alice):
    section("Constraints")

    cases = [
        ("negative duration", {"duration": -1.0}),
        ("negative byte count", {"bytes": -5}),
        ("unknown transcript engine", {"engine": "whisper-v3"}),
        ("confidence above 1", {"confidence": 1.5}),
        ("confidence below 0", {"confidence": -0.2}),
    ]
    for label, kwargs in cases:
        rejected = False
        try:
            with as_user(conn, alice) as cur:
                insert_memo(cur, f"bad-{label}", "2026-03-01T08:00:00Z", **kwargs)
        except (psycopg.errors.CheckViolation, psycopg.errors.InvalidTextRepresentation):
            rejected = True
        check(rejected, f"rejects {label}")

    for label, kwargs in [
        ("appleOnDevice", {"engine": "appleOnDevice"}),
        ("appleLegacy", {"engine": "appleLegacy"}),
        ("cloud", {"engine": "cloud"}),
        ("manual", {"engine": "manual"}),
    ]:
        accepted = True
        try:
            with as_user(conn, alice) as cur:
                insert_memo(cur, f"ok-{label}", "2026-03-02T08:00:00Z", **kwargs)
        except psycopg.errors.CheckViolation:
            accepted = False
        check(accepted, f"accepts the {label} engine label")

    # The web client writes 'manual' when a transcript is edited by hand, so
    # that label has to be permitted or editing fails at the database.
    with conn.cursor() as cur:
        cur.execute("select count(*) from auth.users")
        users_before = cur.fetchone()[0]
    conn.rollback()

    with conn.cursor() as cur:
        cur.execute("insert into auth.users (email) values ('doomed@example.com') returning id")
        doomed = str(cur.fetchone()[0])
    conn.commit()

    with as_user(conn, doomed) as cur:
        insert_memo(cur, "doomed-1", "2026-03-03T08:00:00Z", transcript="goes away")

    with conn.cursor() as cur:
        cur.execute("delete from auth.users where id = %s", (doomed,))
        cur.execute("select count(*) from public.memos where id = 'doomed-1'")
        check(cur.fetchone()[0] == 0, "deleting the user cascades to their memos")
    conn.commit()


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------


def test_search(conn, alice):
    section("Search")

    chinese = "明天下午三点开会，记得带笔记本电脑"
    japanese = "会議は明日の午後三時からです"
    english = "meeting tomorrow at three, bring the laptop"

    with as_user(conn, alice) as cur:
        insert_memo(cur, "s-cn", "2026-04-01T08:00:00Z", transcript=chinese, locale="zh-CN")
        insert_memo(cur, "s-jp", "2026-04-02T08:00:00Z", transcript=japanese, locale="ja-JP")
        insert_memo(cur, "s-en", "2026-04-03T08:00:00Z", transcript=english, locale="en-US")

    # This is the query the web client actually runs.
    with as_user(conn, alice) as cur:
        for label, needle, expected in [
            ("Chinese substring", "开会", "s-cn"),
            ("Chinese mid-string", "笔记本", "s-cn"),
            ("Japanese substring", "会議", "s-jp"),
            ("English substring", "laptop", "s-en"),
        ]:
            cur.execute(
                "select id from public.memos where transcript ilike %s", (f"%{needle}%",)
            )
            found = [r[0] for r in cur.fetchall()]
            check(found == [expected], f"ilike finds the {label} '{needle}'", f"got {found}")

    # The documented limitation, asserted so it cannot quietly stop being true.
    # Postgres has no Chinese segmenter, so to_tsvector('simple', ...) makes the
    # whole clause one token and a word query matches nothing — an empty result,
    # not an error. This is the entire reason the trigram index exists.
    with as_user(conn, alice) as cur:
        cur.execute(
            """
            select count(*) from public.memos
            where transcript_search @@ to_tsquery('simple', '开会')
            """
        )
        check(
            cur.fetchone()[0] == 0,
            "full-text search still cannot match inside Chinese",
            "if this ever fails, the schema comment needs updating",
        )

        cur.execute(
            """
            select id from public.memos
            where transcript_search @@ to_tsquery('simple', 'laptop')
            """
        )
        found = [r[0] for r in cur.fetchall()]
        check(found == ["s-en"], "full-text search does work for English", f"got {found}")

        # Why the above happens, asserted in a way that does not depend on the
        # server's locale. An earlier version required exactly one token; that
        # held on a --locale=C cluster and failed on the postgres:16 image,
        # which splits the sentence at the ideographic comma into two. The
        # locale-independent property is that Postgres does not segment Chinese
        # into *words*: it produces a couple of clause-sized tokens for sixteen
        # characters, and none of them is a word you would search for.
        cur.execute("select transcript_search::text from public.memos where id = 's-cn'")
        vector = cur.fetchone()[0]
        tokens = [part.split("'")[1] for part in vector.split() if "'" in part]
        check(
            len(tokens) <= 3,
            "the Chinese sentence is not segmented into words",
            f"{len(tokens)} tokens from {len(chinese)} characters: {tokens}",
        )
        check(
            all(len(token) > 3 for token in tokens),
            "every token is a whole clause, not a word",
            f"got {tokens}",
        )
        check(
            "开会" not in tokens,
            "and a searchable word is not among them",
            f"got {tokens}",
        )

    # The generated column must track edits, or search silently returns stale
    # results after a transcript is corrected in the web client.
    with as_user(conn, alice) as cur:
        cur.execute(
            "update public.memos set transcript = %s where id = 's-en'",
            ("completely different words now",),
        )
        cur.execute(
            """
            select count(*) from public.memos
            where id = 's-en' and transcript_search @@ to_tsquery('simple', 'different')
            """
        )
        check(cur.fetchone()[0] == 1, "the search vector follows an edited transcript")
        cur.execute(
            """
            select count(*) from public.memos
            where id = 's-en' and transcript_search @@ to_tsquery('simple', 'laptop')
            """
        )
        check(cur.fetchone()[0] == 0, "and stops matching the old text")


def test_trigram_index_is_used(conn, alice):
    section("Trigram index actually gets used")

    # Without the trigram index an `ilike '%...%'` still returns correct rows,
    # it just reads the whole table. That is invisible until the corpus is big,
    # so the plan is asserted rather than the result.
    random.seed(20260903)
    words = ["会议", "笔记", "项目", "计划", "客户", "预算", "报告", "面试", "训练", "复盘"]
    with as_user(conn, alice) as cur:
        for index in range(4000):
            text = "".join(random.choice(words) for _ in range(random.randint(3, 12)))
            insert_memo(
                cur,
                f"bulk-{index}",
                "2026-05-01T08:00:00Z",
                transcript=text,
                locale="zh-CN",
            )
        cur.execute("insert into public.memos (id, user_id, started_at, source_device, transcript) "
                    "values ('needle', auth.uid(), now(), 'watch', %s) on conflict do nothing",
                    ("这是一个非常独特的句子用来测试索引",))

    with conn.cursor() as cur:
        cur.execute("analyze public.memos")

        cur.execute(
            """
            select indexdef from pg_indexes
            where schemaname = 'public' and indexname = 'memos_transcript_trgm_idx'
            """
        )
        row = cur.fetchone()
        check(row is not None, "the trigram index exists")
        if row:
            check("gin_trgm_ops" in row[0], "with the gin_trgm_ops opclass", row[0])
    conn.commit()

    # What matters is that the index *can* serve the query the web client runs.
    # Whether the planner picks it at this size is a cost decision, and at a few
    # thousand short rows a sequential scan is legitimately cheaper — asserting
    # the plan unconditionally would be testing the cost model, not the schema.
    # Disabling seqscan asks the question that actually matters: is this index
    # applicable to `transcript ilike '%...%'` at all? It stops being applicable
    # if the extension is missing, the opclass is wrong, or someone rewrites the
    # query into a shape trigrams cannot serve.
    # Explained without RLS in play. Under RLS the policy adds `user_id =
    # auth.uid()`, and the planner then prefers memos_user_started_idx — a
    # perfectly good plan, but it answers a different question. Isolating the
    # ilike predicate is what tests the trigram index.
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("set local enable_seqscan = off")
            cur.execute(
                "explain (format text) select id from public.memos where transcript ilike %s",
                ("%非常独特%",),
            )
            plan = "\n".join(row[0] for row in cur.fetchall())
    check(
        "memos_transcript_trgm_idx" in plan,
        "and the ilike query can be served by it",
        " / ".join(line.strip() for line in plan.splitlines()[:3]),
    )

    with as_user(conn, alice) as cur:
        cur.execute("set local enable_seqscan = off")
        cur.execute("select id from public.memos where transcript ilike %s", ("%非常独特%",))
        via_index = [r[0] for r in cur.fetchall()]

    # Same query, forced down the other path. Identical results is the check
    # that the index does not change semantics — a wrong opclass or a
    # case-folding mismatch with ILIKE would show up here as a disagreement.
    with as_user(conn, alice) as cur:
        cur.execute("set local enable_bitmapscan = off")
        cur.execute("set local enable_indexscan = off")
        cur.execute("select id from public.memos where transcript ilike %s", ("%非常独特%",))
        via_scan = [r[0] for r in cur.fetchall()]

    check(via_index == ["needle"], "the indexed search finds the right row", f"got {via_index}")
    check(via_index == via_scan, "index and sequential scan agree exactly", f"{via_index} vs {via_scan}")

    with as_user(conn, alice) as cur:
        cur.execute("select count(*) from public.memos")
        total = cur.fetchone()[0]
        check(total > 4000, "over a corpus large enough to be meaningful", f"{total} rows")


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------


def test_storage(conn, alice, bob):
    section("Storage bucket and policies")

    with conn.cursor() as cur:
        cur.execute("select public, file_size_limit from storage.buckets where id = 'memo-audio'")
        row = cur.fetchone()
        check(row is not None, "the memo-audio bucket exists")
        if row:
            check(row[0] is False, "the bucket is private", "public audio would leak recordings")
            check(row[1] == 104857600, "the size limit is 100 MB", f"got {row[1]}")

        cur.execute("select storage.foldername('abc-123/memo-9.m4a')")
        check(cur.fetchone()[0] == ["abc-123"], "foldername strips the filename")
    conn.rollback()

    with as_user(conn, alice) as cur:
        cur.execute(
            "insert into storage.objects (bucket_id, name, owner) values ('memo-audio', %s, %s)",
            (f"{alice}/m1.m4a", alice),
        )
        check(cur.rowcount == 1, "own audio is writable")

    denied = False
    try:
        with as_user(conn, alice) as cur:
            cur.execute(
                "insert into storage.objects (bucket_id, name, owner) values ('memo-audio', %s, %s)",
                (f"{bob}/stolen.m4a", alice),
            )
    except psycopg.errors.InsufficientPrivilege:
        denied = True
    check(denied, "cannot write into another user's folder")

    with as_user(conn, bob) as cur:
        cur.execute("select count(*) from storage.objects where bucket_id = 'memo-audio'")
        check(cur.fetchone()[0] == 0, "cannot list another user's audio")

    with as_user(conn, alice) as cur:
        cur.execute("select name from storage.objects where bucket_id = 'memo-audio'")
        names = [r[0] for r in cur.fetchall()]
        check(names == [f"{alice}/m1.m4a"], "own audio is readable", f"got {names}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dsn",
        default="postgresql://postgres@127.0.0.1:54329/postgres",
        help="connection string for a PostgreSQL server to test against",
    )
    args = parser.parse_args()

    print("=" * 72)
    print("Verba schema verification against real PostgreSQL")
    print("=" * 72)

    with psycopg.connect(args.dsn, autocommit=False) as conn:
        with conn.cursor() as cur:
            cur.execute("select version()")
            print(f"\nserver: {cur.fetchone()[0].split(',')[0]}")
        conn.rollback()

        reset_database(conn)
        apply_sql(conn, SHIM)
        apply_sql(conn, SCHEMA)
        grant_client_access(conn)
        print(f"applied: {SHIM.name} then {SCHEMA.name} (unmodified)")

        alice = make_user(conn, "alice@example.com")
        bob = make_user(conn, "bob@example.com")

        test_rls_is_actually_enforced(conn, alice, bob)
        test_upsert_semantics(conn, alice)
        test_constraints(conn, alice)
        test_search(conn, alice)
        test_trigram_index_is_used(conn, alice)
        test_storage(conn, alice, bob)

    print()
    print("=" * 72)
    if failures:
        print(f"RESULT: FAIL  ({len(failures)} of {checks} checks failed)")
        for failure in failures:
            print(f"  - {failure}")
        print("=" * 72)
        return 1
    print(f"RESULT: PASS  ({checks} checks)")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
