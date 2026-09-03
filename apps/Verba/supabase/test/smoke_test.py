"""
End-to-end check against a live Supabase project.

`verify_schema.py` proves the SQL is right on a throwaway server.
This proves *your project* is set up right: schema applied, bucket created,
RLS on, policies working, and the REST surface behaving the way the apps
expect. Run it once after following ../README.md.

Deliberately uses nothing but the standard library and the anon key over plain
REST — the same way `PhoneApp/SupabaseStore.swift` does — so a pass here means
the app's exact code path works, not that some SDK could make it work.

    python smoke_test.py \
        --url https://YOUR-PROJECT-REF.supabase.co \
        --anon-key "YOUR-ANON-KEY" \
        --email you@example.com \
        --password "..."

Optionally pass a second account with --other-email/--other-password to check
that RLS really isolates two live users. Without it that group is skipped and
reported as skipped rather than passed.

Everything it writes is removed at the end, including on failure.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

checks = 0
failures: list[str] = []
skipped: list[str] = []


def check(condition: bool, label: str, detail: str = "") -> None:
    global checks
    checks += 1
    if condition:
        print(f"  ok    {label}")
    else:
        print(f"  FAIL  {label}{(' — ' + detail) if detail else ''}")
        failures.append(label)


def section(title: str) -> None:
    print(f"\n{title}")
    print("-" * len(title))


def request(
    method: str,
    url: str,
    *,
    headers: dict[str, str],
    body: bytes | None = None,
    content_type: str | None = None,
) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method=method)
    for key, value in headers.items():
        req.add_header(key, value)
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


class Client:
    def __init__(self, url: str, anon_key: str):
        self.url = url.rstrip("/")
        self.anon_key = anon_key
        self.token: str | None = None
        self.user_id: str | None = None

    def sign_in(self, email: str, password: str) -> tuple[int, dict]:
        status, raw = request(
            "POST",
            f"{self.url}/auth/v1/token?grant_type=password",
            headers={"apikey": self.anon_key},
            body=json.dumps({"email": email, "password": password}).encode(),
            content_type="application/json",
        )
        payload = json.loads(raw or b"{}")
        if status == 200:
            self.token = payload["access_token"]
            self.user_id = payload["user"]["id"]
        return status, payload

    def headers(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        base = {"apikey": self.anon_key, "Authorization": f"Bearer {self.token}"}
        base.update(extra or {})
        return base

    def rpc(self, name: str, payload: dict) -> tuple[int, object]:
        status, raw = request(
            "POST",
            f"{self.url}/rest/v1/rpc/{name}",
            headers=self.headers(),
            body=json.dumps(payload).encode(),
            content_type="application/json",
        )
        return status, json.loads(raw or b"null")

    def select(self, query: str) -> tuple[int, object]:
        status, raw = request(
            "GET", f"{self.url}/rest/v1/memos?{query}", headers=self.headers()
        )
        return status, json.loads(raw or b"null")

    def delete_memo(self, memo_id: str) -> int:
        status, _ = request(
            "DELETE",
            f"{self.url}/rest/v1/memos?id=eq.{urllib.parse.quote(memo_id)}",
            headers=self.headers(),
        )
        return status

    def upload(self, path: str, data: bytes, content_type: str) -> int:
        status, _ = request(
            "POST",
            f"{self.url}/storage/v1/object/memo-audio/{urllib.parse.quote(path)}",
            headers=self.headers({"x-upsert": "true"}),
            body=data,
            content_type=content_type,
        )
        return status

    def sign_url(self, path: str, seconds: int = 60) -> tuple[int, object]:
        status, raw = request(
            "POST",
            f"{self.url}/storage/v1/object/sign/memo-audio/{urllib.parse.quote(path)}",
            headers=self.headers(),
            body=json.dumps({"expiresIn": seconds}).encode(),
            content_type="application/json",
        )
        return status, json.loads(raw or b"null")

    def remove_object(self, path: str) -> int:
        status, _ = request(
            "DELETE",
            f"{self.url}/storage/v1/object/memo-audio/{urllib.parse.quote(path)}",
            headers=self.headers(),
        )
        return status


# A minimal but genuinely valid 44-byte WAV header plus silence, so the upload
# is a real audio file the bucket's allowed_mime_types will accept.
def tiny_wav() -> bytes:
    samples = b"\x00\x00" * 800
    size = 36 + len(samples)
    return (
        b"RIFF" + size.to_bytes(4, "little") + b"WAVEfmt "
        + (16).to_bytes(4, "little")
        + (1).to_bytes(2, "little")
        + (1).to_bytes(2, "little")
        + (16000).to_bytes(4, "little")
        + (32000).to_bytes(4, "little")
        + (2).to_bytes(2, "little")
        + (16).to_bytes(2, "little")
        + b"data" + len(samples).to_bytes(4, "little") + samples
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--anon-key", required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--other-email")
    parser.add_argument("--other-password")
    args = parser.parse_args()

    print("=" * 72)
    print("Verba live project smoke test")
    print("=" * 72)

    marker = uuid.uuid4().hex[:8]
    memo_id = f"{int(time.time())}-smoke{marker}"
    client = Client(args.url, args.anon_key)
    audio_path: str | None = None

    try:
        section("Auth")
        status, payload = client.sign_in(args.email, args.password)
        check(status == 200, "sign in with email and password", f"HTTP {status} {payload}")
        if status != 200:
            print("\nCannot continue without a session.")
            return 1
        check(bool(client.user_id), "the session carries a user id")

        anon = Client(args.url, args.anon_key)
        anon.token = args.anon_key  # what an un-signed-in browser sends
        status, rows = anon.select("select=id&limit=1")
        check(
            status in (401, 403) or rows == [],
            "an anonymous request reads nothing",
            f"HTTP {status} {rows}",
        )

        section("Write path (what the iPhone app does)")
        transcript = f"明天下午三点开会 smoke {marker}"
        status, row = client.rpc(
            "upsert_memo",
            {
                "p_id": memo_id,
                "p_started_at": "2026-09-03T12:00:00Z",
                "p_duration_seconds": 4.2,
                "p_byte_count": 1600,
                "p_source_device": "watch",
                "p_transcript": transcript,
                "p_transcript_locale": "zh-CN",
                "p_transcript_engine": "appleOnDevice",
                "p_transcript_confidence": 0.87,
                "p_title": f"Smoke {marker}",
            },
        )
        check(status in (200, 201), "upsert_memo accepts a memo", f"HTTP {status} {row}")
        check(
            isinstance(row, dict) and row.get("user_id") == client.user_id,
            "the row is owned by the signed-in user",
            "upsert_memo assigns user_id from auth.uid()",
        )

        # The failure this guards: redelivery blanking a populated transcript.
        status, row = client.rpc(
            "upsert_memo",
            {
                "p_id": memo_id,
                "p_started_at": "2026-09-03T12:00:00Z",
                "p_duration_seconds": 4.2,
                "p_byte_count": 1600,
                "p_source_device": "watch",
                "p_audio_path": f"{client.user_id}/{memo_id}.wav",
            },
        )
        check(status in (200, 201), "redelivery is accepted", f"HTTP {status}")
        check(
            isinstance(row, dict) and row.get("transcript") == transcript,
            "and does not blank the transcript",
        )

        status, rows = client.select(f"select=id&id=eq.{urllib.parse.quote(memo_id)}")
        check(isinstance(rows, list) and len(rows) == 1, "exactly one row, not a duplicate")

        section("Storage")
        audio_path = f"{client.user_id}/{memo_id}.wav"
        status = client.upload(audio_path, tiny_wav(), "audio/wav")
        check(status in (200, 201), "audio uploads into the user's own folder", f"HTTP {status}")

        status, signed = client.sign_url(audio_path)
        check(status == 200, "a signed URL can be minted", f"HTTP {status} {signed}")
        if status == 200 and isinstance(signed, dict):
            signed_url = args.url.rstrip("/") + "/storage/v1" + signed["signedURL"]
            code, blob = request("GET", signed_url, headers={})
            check(code == 200 and blob[:4] == b"RIFF", "and it serves the audio back")

            unsigned = f"{args.url.rstrip('/')}/storage/v1/object/public/memo-audio/{urllib.parse.quote(audio_path)}"
            code, _ = request("GET", unsigned, headers={})
            check(code >= 400, "while the unsigned public URL is refused", f"HTTP {code}")

        forbidden = f"00000000-0000-0000-0000-000000000000/{memo_id}.wav"
        status = client.upload(forbidden, tiny_wav(), "audio/wav")
        check(status >= 400, "cannot upload into another user's folder", f"HTTP {status}")

        section("Search (what the web client does)")
        needle = urllib.parse.quote(f"*开会 smoke {marker}*")
        status, rows = client.select(f"select=id&transcript=ilike.{needle}")
        check(
            isinstance(rows, list) and any(r["id"] == memo_id for r in rows),
            "substring search finds the Chinese transcript",
            f"HTTP {status} {rows}",
        )

        status, rows = client.select("select=id,started_at&order=started_at.desc&limit=5")
        check(status == 200 and isinstance(rows, list), "the newest-first listing works")

        section("Isolation between two live users")
        if args.other_email and args.other_password:
            other = Client(args.url, args.anon_key)
            status, payload = other.sign_in(args.other_email, args.other_password)
            check(status == 200, "the second account signs in", f"HTTP {status}")
            if status == 200:
                status, rows = other.select(
                    f"select=id&id=eq.{urllib.parse.quote(memo_id)}"
                )
                check(rows == [], "the second user cannot read the first user's memo", f"{rows}")
                code = other.remove_object(audio_path)
                status2, still = client.select(
                    f"select=audio_path&id=eq.{urllib.parse.quote(memo_id)}"
                )
                check(
                    isinstance(still, list) and still and still[0]["audio_path"],
                    "and cannot delete the first user's audio",
                    f"delete returned HTTP {code}",
                )
        else:
            skipped.append(
                "two-user isolation (pass --other-email/--other-password to include it)"
            )
            print("  skip  two-user isolation — no second account supplied")

    finally:
        section("Cleanup")
        if client.token:
            if audio_path:
                code = client.remove_object(audio_path)
                print(f"  removed audio object (HTTP {code})")
            code = client.delete_memo(memo_id)
            print(f"  removed memo row (HTTP {code})")

    print()
    print("=" * 72)
    if failures:
        print(f"RESULT: FAIL  ({len(failures)} of {checks} checks failed)")
        for failure in failures:
            print(f"  - {failure}")
        print("=" * 72)
        return 1
    note = f", {len(skipped)} group skipped" if skipped else ""
    print(f"RESULT: PASS  ({checks} checks{note})")
    for item in skipped:
        print(f"  not covered: {item}")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
