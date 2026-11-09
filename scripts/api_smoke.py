#!/usr/bin/env python3
"""Real PostgREST checks against a disposable LOOPBACK Supabase stack only.

Input is a private file from `supabase status --output json`. Never print it.
Only newly generated fixture IDs are inserted and removed. No hosted writes.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    status = json.loads(Path(sys.argv[1]).read_text())
    api = status.get("API_URL", status.get("api_url", ""))
    key = status.get("ANON_KEY", status.get("anon_key", ""))
    database = status.get("DB_URL", status.get("db_url", ""))
    api_uri = urllib.parse.urlparse(api)
    db_uri = urllib.parse.urlparse(database)
    for uri in (api_uri, db_uri):
        if uri.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("Refusing non-loopback test target")
    if api_uri.scheme != "http" or db_uri.scheme not in ("postgres", "postgresql") or not key:
        raise ValueError("Unexpected local stack configuration")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    env = dict(os.environ)
    env.update({
        "PGHOST": db_uri.hostname,
        "PGPORT": str(db_uri.port or 5432),
        "PGUSER": urllib.parse.unquote(db_uri.username or "postgres"),
        "PGPASSWORD": urllib.parse.unquote(db_uri.password or ""),
        "PGDATABASE": db_uri.path.lstrip("/"),
    })

    def sql(text):
        result = subprocess.run(
            ["psql", "--no-psqlrc", "--quiet", "--set", "ON_ERROR_STOP=1"],
            input=text, text=True, capture_output=True, env=env, check=False,
        )
        if result.returncode:
            raise RuntimeError("Synthetic fixture SQL failed; no credentials logged")

    def api_call(table, query=(), method="GET", body=None):
        request = urllib.request.Request(
            api.rstrip("/") + "/rest/v1/" + table + "?" + urllib.parse.urlencode(query),
            data=None if body is None else json.dumps(body).encode(),
            headers={"apikey": key, "Content-Type": "application/json"}, method=method,
        )
        try:
            with opener.open(request, timeout=15) as response:
                payload = response.read()
                return response.status, json.loads(payload) if payload else None
        except urllib.error.HTTPError as error:
            return error.code, None

    passed = 0

    def expect(condition, label):
        nonlocal passed
        if not condition:
            raise AssertionError(label)
        passed += 1
        print(f"ok {passed} - {label}")

    owner = str(uuid.uuid4())
    ids = sorted([str(uuid.uuid4()) for _ in range(5)], reverse=True)
    timestamp = "2026-01-02T03:04:05+00:00"
    needle = 'alpha "quote", (group) \\path 50%_match'
    titles = [needle, "alpha second", "beta third",
              needle.replace("50%_match", "50XYZXmatch"), "alpha fifth"]
    scope = ("id", "in.(" + ",".join(ids) + ")")
    fixture_created = False
    try:
        inserts = [
            "begin;",
            f"insert into auth.users(id) values({literal(owner)});",
            "insert into public.profiles(id,display_name,accepted_terms_at) values("
            f"{literal(owner)},'Synthetic API fixture',now());",
        ]
        for identifier, title in zip(ids, titles):
            inserts.append(
                "insert into public.listings(id,owner_id,kind,title,description,quantity,created_at) values("
                f"{literal(identifier)},{literal(owner)},'request',{literal(title)},"
                f"'Synthetic fixture only',1,{literal(timestamp)});"
            )
        inserts.append("commit;")
        sql("\n".join(inserts))
        fixture_created = True
        common = [("select", "id,title,created_at"), scope,
                  ("order", "created_at.desc,id.desc"), ("limit", "2")]
        code, rows = api_call("listings", common)
        expect(code == 200 and [r["id"] for r in rows] == ids[:2],
               "timestamp ties are ordered deterministically")
        cursor = f"(created_at.lt.{timestamp},and(created_at.eq.{timestamp},id.lt.{ids[1]}))"
        code, rows = api_call("listings", common + [("or", cursor)])
        expect(code == 200 and [r["id"] for r in rows] == ids[2:4],
               "keyset second page has no repeat at timestamp ties")
        final_cursor = f"(created_at.lt.{timestamp},and(created_at.eq.{timestamp},id.lt.{ids[3]}))"
        code, rows = api_call("listings", common + [("or", final_cursor)])
        expect(code == 200 and [r["id"] for r in rows] == ids[4:],
               "keyset final page does not omit timestamp-tied rows")
        code, rows = api_call("listings", common + [
            ("or", '(title.ilike."%alpha%",description.ilike."%alpha%")'),
            ("or", cursor),
        ])
        expect(code == 200 and [r["id"] for r in rows] == ids[3:5],
               "search OR and cursor OR combine as AND")

        # Must match the two escaping layers in app/lib/domain.dart.
        like = needle.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        quoted = like.replace("\\", "\\\\").replace('"', '\\"')
        pattern = '"%' + quoted + '%"'
        code, rows = api_call("listings", [("select", "id"), scope,
            ("or", f"(title.ilike.{pattern},description.ilike.{pattern})")])
        expect(code == 200 and [r["id"] for r in rows] == [ids[0]],
               "quotes, commas, parentheses, slashes and wildcards remain literal")

        for removed in ("posts", "replies", "topics"):
            code, _ = api_call(removed, [("select", "*"), ("limit", "1")])
            expect(code == 404, f"removed {removed} endpoint is absent")
        code, _ = api_call("rpc/reserve_upload", method="POST", body={
            "p_post": None, "p_listing": ids[0], "p_bytes": 100, "p_mime": "image/jpeg",
        })
        expect(code == 404, "removed four-argument upload RPC is absent")
        for table in ("profile_contacts", "reports", "moderator_roles", "upload_intents"):
            code, _ = api_call(table, [("select", "*"), ("limit", "1")])
            expect(code in (401, 403), f"anonymous access to {table} is denied")
        code, _ = api_call("listings", method="POST", body={
            "kind": "request", "title": "Anonymous negative fixture", "description": "Denied", "quantity": 1,
        })
        expect(code in (401, 403), "anonymous posting is denied at the actual API")
        print(f"PASS {passed} live local PostgREST checks")
    finally:
        if fixture_created:
            sql(f"delete from auth.users where id={literal(owner)};")


if __name__ == "__main__":
    main()
