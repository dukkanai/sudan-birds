#!/usr/bin/env python3
"""Real caller-JWT/PostgREST checks against disposable LOOPBACK Supabase only.

Input is a private file from `supabase status --output json`. Never print it.
SQL creates synthetic Auth identities and deterministic fixtures; application
mutations use short-lived, locally signed authenticated JWTs, never service_role.
This covers the gateway/PostgREST/RLS, NOT GoTrue login/refresh/revocation or Edge.
No credentials, JWTs, contact values, URLs, SQL errors or response bodies are logged.
"""
import base64
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class HarnessFailure(Exception):
    """A deliberately static, credential-free failure description."""


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def local_configuration(status):
    if not isinstance(status, dict):
        raise HarnessFailure("Invalid local stack configuration")
    values = [status.get(name, status.get(name.lower(), ""))
              for name in ("API_URL", "ANON_KEY", "DB_URL", "JWT_SECRET")]
    api, key, database, secret = values
    if not all(isinstance(value, str) and value for value in values):
        raise HarnessFailure("Local API, database, anonymous key and JWT secret required")
    try:
        api_uri, db_uri = map(urllib.parse.urlsplit, (api, database))
        for uri in (api_uri, db_uri):
            # No DNS, redirects, proxy, query-based PG service/host override or URI
            # userinfo at the API. A hosted status file is rejected before any I/O.
            if (uri.hostname not in ("127.0.0.1", "::1") or not uri.port or
                    uri.query or uri.fragment):
                raise ValueError()
        if (api_uri.scheme != "http" or api_uri.username or api_uri.password or
                api_uri.path not in ("", "/") or
                db_uri.scheme not in ("postgres", "postgresql") or
                not re.fullmatch(r"/[A-Za-z0-9_]+", db_uri.path)):
            raise ValueError()
    except (ValueError, TypeError):
        raise HarnessFailure("Refusing unexpected or non-literal-loopback target") from None
    # Do not inherit libpq service, hostaddr, options, password-file or shell debug
    # settings. The connection password is an env value, never a process argument.
    env = {name: value for name, value in os.environ.items() if not name.startswith("PG")}
    env.update({
        "PGHOST": db_uri.hostname, "PGHOSTADDR": db_uri.hostname,
        "PGPORT": str(db_uri.port),
        "PGUSER": urllib.parse.unquote(db_uri.username or "postgres"),
        "PGPASSWORD": urllib.parse.unquote(db_uri.password or ""),
        "PGDATABASE": db_uri.path.lstrip("/"), "PGCONNECT_TIMEOUT": "5",
        "PGOPTIONS": "-c statement_timeout=15000 -c lock_timeout=5000",
        "PGPASSFILE": os.devnull, "PGSERVICEFILE": os.devnull,
    })
    return api.rstrip("/"), key, secret, env


def encode_segment(value):
    raw = json.dumps(value, separators=(",", ":"), allow_nan=False).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def caller_token(secret, subject, issuer, *, now=None, claims=None):
    now = int(time.time()) if now is None else now
    payload = {"aud": "authenticated", "role": "authenticated", "sub": subject,
               "iss": issuer + "/auth/v1", "iat": now, "exp": now + 900}
    payload.update(claims or {})
    if payload["role"] != "authenticated":
        raise HarnessFailure("Test signer only permits authenticated caller role")
    message = encode_segment({"alg": "HS256", "typ": "JWT"}) + "." + encode_segment(payload)
    signature = hmac.new(secret.encode(), message.encode(), hashlib.sha256).digest()
    return message + "." + base64.urlsafe_b64encode(signature).rstrip(b"=").decode()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise HarnessFailure("HTTP redirect refused")


class LocalStack:
    def __init__(self, status):
        self.api, self.key, self.secret, self.env = local_configuration(status)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def sql(self, statement):
        result = subprocess.run(
            ["psql", "--no-psqlrc", "--quiet", "--set", "ON_ERROR_STOP=1"],
            input=statement, text=True, capture_output=True, env=self.env,
            check=False, timeout=30,
        )
        if result.returncode:
            raise HarnessFailure("Synthetic fixture SQL failed; details suppressed")

    def token(self, subject, **kwargs):
        return caller_token(self.secret, subject, self.api, **kwargs)

    def call(self, table, query=(), *, token=None, method="GET", body=None):
        if not re.fullmatch(r"(?:rpc/)?[a-z_]+", table):
            raise HarnessFailure("Invalid test API path")
        headers = {"apikey": self.key, "Content-Type": "application/json",
                   "Prefer": "return=representation"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(
            self.api + "/rest/v1/" + table + "?" + urllib.parse.urlencode(query),
            data=None if body is None else json.dumps(body, allow_nan=False).encode(),
            headers=headers, method=method,
        )
        try:
            response = self.opener.open(request, timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            payload = response.read(1_048_577)
            if len(payload) > 1_048_576:
                raise HarnessFailure("Test response exceeded bounded size")
            try:
                return response.code, json.loads(payload) if payload else None
            except (ValueError, UnicodeError):
                raise HarnessFailure("Non-JSON response from local API") from None


class Checks:
    def __init__(self, stack):
        self.stack = stack
        self.passed = 0

    def expect(self, condition, label):
        if not condition:
            raise HarnessFailure(label)
        self.passed += 1
        print(f"ok {self.passed} - {label}")

    @staticmethod
    def diagnostic(status, payload):
        state = payload.get("code") if isinstance(payload, dict) else None
        safe = state if isinstance(state, str) and re.fullmatch(r"(?:[0-9A-Z]{5}|PGRST[0-9]{3})", state) else "none"
        status = status if type(status) is int and 100 <= status <= 599 else "unknown"
        return f" [HTTP {status}; SQLSTATE/API code {safe}]"

    def rows(self, label, table, *, expected=None, status=200, **kwargs):
        code, rows = self.stack.call(table, **kwargs)
        condition = code == status and isinstance(rows, list) and (expected is None or rows == expected)
        self.expect(condition, label if condition else label + self.diagnostic(code, rows))
        return rows

    def denied(self, label, table, *, codes=("42501",), statuses=(403,), **kwargs):
        code, error = self.stack.call(table, **kwargs)
        condition = code in statuses and isinstance(error, dict) and error.get("code") in codes
        self.expect(condition, label if condition else label + self.diagnostic(code, error))

    def rpc(self, label, name, token, body):
        code, value = self.stack.call("rpc/" + name, token=token, method="POST", body=body)
        condition = code in (200, 204) and value is None
        self.expect(condition, label if condition else label + self.diagnostic(code, value))


def eq(identifier):
    return [("id", "eq." + identifier)]


def listing(title="Synthetic request", **values):
    return {"kind": "request", "title": title, "description": "Synthetic fixture only",
            "quantity": 1, **values}


def marketplace_checks(stack, check, owner, other, moderator):
    a, b, m = [stack.token(identifier) for identifier in (owner, other, moderator)]
    current = datetime.now(timezone.utc).isoformat()
    # Auth identity records alone do not bypass profile ownership or terms gating.
    check.denied("caller cannot create another user's profile", "profiles", token=a,
                 method="POST", body={"id": other, "display_name": "Spoofed profile"})
    for identifier, token, label in ((owner, a, "owner"), (other, b, "other"), (moderator, m, "moderator")):
        rows = check.rows(f"{label} creates own profile through caller JWT", "profiles", token=token,
                          method="POST", status=201, body={"id": identifier, "display_name": "Synthetic " + label})
        check.expect(len(rows) == 1 and rows[0]["id"] == identifier and rows[0]["accepted_terms_at"] is None,
                     f"{label} profile has no implicit terms acceptance")
    check.denied("publishing before terms acceptance is forbidden", "listings", token=a,
                 method="POST", body=listing())
    check.rows("caller cannot accept terms for another profile", "profiles", query=eq(other),
               token=a, method="PATCH", body={"accepted_terms_at": current}, expected=[])
    for identifier, token in ((owner, a), (other, b), (moderator, m)):
        rows = check.rows("caller accepts terms on own profile", "profiles", query=eq(identifier), token=token,
                          method="PATCH", body={"accepted_terms_at": current})
        check.expect(len(rows) == 1 and rows[0]["accepted_terms_at"] is not None,
                     "own terms acceptance persists")
    request = check.rows("owner publishes request without budget", "listings", token=a,
                         method="POST", status=201, body=listing())[0]
    request_id = request["id"]
    check.expect(request["owner_id"] == owner and request["price"] is None and
                 request["moderation_state"] == "visible" and request["status"] == "active",
                 "database assigns owner and safe initial listing state from JWT")
    delta = datetime.fromisoformat(request["expires_at"]) - datetime.fromisoformat(request["created_at"])
    check.expect(delta.total_seconds() == 30 * 86400, "new listing receives server-controlled 30-day expiry")
    offer = check.rows("owner publishes a zero-price offer", "listings", token=a,
                       method="POST", status=201, body=listing("Synthetic offer", kind="offer", price=0))[0]
    other_listing = check.rows("second caller publishes own listing", "listings", token=b,
                               method="POST", status=201, body=listing("Second caller request"))[0]
    # Status alone is insufficient: expected constraint SQLSTATE verifies the real
    # database rejection rather than an unrelated proxy/JSON failure.
    for suffix, values, codes in (
        ("missing offer price", {"kind": "offer"}, ("23514",)),
        ("negative price", {"price": -1}, ("23514",)),
        ("NaN price", {"price": "NaN"}, ("23514",)),
        ("infinite price", {"price": "Infinity"}, ("22003", "23514")),
        ("price overflow", {"price": 1_000_000_000_000}, ("22003",)),
        ("invalid currency", {"price": 20, "currency": "usd"}, ("23514",)),
    ):
        check.denied(suffix + " is rejected through API", "listings", token=a,
                     method="POST", body=listing(**values), statuses=(400,), codes=codes)
    check.denied("caller cannot set listing owner on insert", "listings", token=a,
                 method="POST", body=listing(owner_id=other))
    check.rows("another user can browse visible listing", "listings", token=b,
               query=eq(request_id) + [("select", "id")], expected=[{"id": request_id}])
    check.rows("cross-user update returns zero rows", "listings", token=b,
               query=eq(request_id), method="PATCH", body={"title": "Forbidden update"}, expected=[])
    check.rows("cross-user delete returns zero rows", "listings", token=b,
               query=eq(request_id), method="DELETE", expected=[])
    rows = check.rows("failed cross-user writes leave owner's content unchanged", "listings", token=a,
                      query=eq(request_id), expected=[request])
    for field, value in (("owner_id", other), ("id", str(uuid.uuid4())),
                         ("created_at", current), ("expires_at", current),
                         ("moderation_state", "hidden"), ("kind", "offer")):
        check.denied("owner cannot rewrite protected " + field, "listings", token=a,
                     query=eq(request_id), method="PATCH", body={field: value})
    rows = check.rows("owner can update permitted listing fields", "listings", token=a,
                      query=eq(request_id), method="PATCH", body={"title": "Updated request", "price": 25})
    check.expect(len(rows) == 1 and rows[0]["title"] == "Updated request" and rows[0]["price"] == 25,
                 "permitted listing update persists")
    check.denied("request cannot transition to reserved", "listings", token=a, query=eq(request_id),
                 method="PATCH", body={"status": "reserved"}, statuses=(400,), codes=("23514",))
    rows = check.rows("offer can transition to reserved", "listings", token=a, query=eq(offer["id"]),
                      method="PATCH", body={"status": "reserved"})
    check.expect(len(rows) == 1 and rows[0]["status"] == "reserved", "offer reserved state persists")

    contact_checks(stack, check, a, b, owner, other, request_id, other_listing["id"], current)
    report_checks(stack, check, a, b, m, owner, other, moderator, request_id)
    search_checks(stack, check, a, owner)
    session_checks(stack, check, a, owner, request_id)

    rows = check.rows("owner deletes own offer", "listings", token=a, query=eq(offer["id"]), method="DELETE")
    check.expect(len(rows) == 1 and rows[0]["id"] == offer["id"], "delete affects exactly owner's requested row")
    check.rows("deleted listing is absent for owner", "listings", token=a, query=eq(offer["id"]), expected=[])
    check.rows("deleted listing is absent for public readers", "listings", query=eq(offer["id"]), expected=[])
    check.rows("repeated listing delete is idempotent", "listings", token=a,
               query=eq(offer["id"]), method="DELETE", expected=[])
    # Revoking terms blocks new publication; it is not an Auth-session revocation.
    rows = check.rows("owner may withdraw own terms acceptance", "profiles", token=a, query=eq(owner),
                      method="PATCH", body={"accepted_terms_at": None})
    check.expect(len(rows) == 1 and rows[0]["accepted_terms_at"] is None, "terms withdrawal persists")
    check.denied("new publication is denied after terms withdrawal", "listings", token=a,
                 method="POST", body=listing("Denied after terms withdrawal"))


def contact_checks(stack, check, a, b, owner, other, target, reverse_target, current):
    value = "synthetic-contact@example.invalid"
    rows = check.rows("owner creates private contact with opt-in disabled", "profile_contacts", token=a,
                      method="POST", status=201,
                      body={"owner_id": owner, "contact_kind": "email", "contact_value": value})
    check.expect(len(rows) == 1 and rows[0]["reveal_consent"] is False, "contact has no implicit owner consent")
    query = [("owner_id", "eq." + owner)]
    check.rows("other caller cannot directly read private contact", "profile_contacts", token=b, query=query, expected=[])
    check.rows("other caller cannot edit private contact", "profile_contacts", token=b, query=query,
               method="PATCH", body={"contact_value": "forbidden@example.invalid"}, expected=[])
    check.rows("other caller cannot delete private contact", "profile_contacts", token=b, query=query,
               method="DELETE", expected=[])
    reveal = {"p_listing": target, "p_explicit_consent": True}
    check.rows("owner opt-out reveals no contact", "rpc/reveal_listing_contact", token=b,
               method="POST", body=reveal, expected=[])
    check.denied("contact opt-in requires timestamp", "profile_contacts", token=a, query=query,
                 method="PATCH", body={"reveal_consent": True}, statuses=(400,), codes=("23514",))
    rows = check.rows("owner opts in to contact disclosure", "profile_contacts", token=a, query=query,
                      method="PATCH", body={"reveal_consent": True, "consent_at": current})
    check.expect(len(rows) == 1 and rows[0]["reveal_consent"] is True, "owner contact opt-in persists")
    for consent in (False, None):
        check.denied("requester must explicitly consent to contact disclosure", "rpc/reveal_listing_contact",
                     token=b, method="POST", body={**reveal, "p_explicit_consent": consent})
    check.rows("both consents reveal exactly the chosen synthetic contact", "rpc/reveal_listing_contact", token=b,
               method="POST", body=reveal, expected=[{"contact_kind": "email", "contact_value": value}])
    # Repeat with each party initiating the block: same visibility/contact outcome.
    for blocker, blocked, token, label in ((other, owner, b, "requester"), (owner, other, a, "owner")):
        rows = check.rows(label + " creates own block", "user_blocks", token=token, method="POST", status=201,
                          body={"blocker_id": blocker, "blocked_id": blocked})
        check.expect(len(rows) == 1 and rows[0]["blocker_id"] == blocker and rows[0]["blocked_id"] == blocked,
                     label + " block is bound to caller")
        check.rows(label + " block hides owner's listing from requester", "listings", token=b,
                   query=eq(target), expected=[])
        check.rows(label + " block hides requester's listing from owner", "listings", token=a,
                   query=eq(reverse_target), expected=[])
        check.rows(label + " block hides owner profile from requester", "profiles", token=b,
                   query=eq(owner), expected=[])
        check.rows(label + " block hides requester profile from owner", "profiles", token=a,
                   query=eq(other), expected=[])
        check.denied(label + " block denies contact disclosure", "rpc/reveal_listing_contact", token=b,
                     method="POST", body=reveal)
        check.rows(label + " block does not pretend public listings are confidential", "listings",
                   query=eq(target) + [("select", "id")], expected=[{"id": target}])
        block_query = [("blocker_id", "eq." + blocker), ("blocked_id", "eq." + blocked)]
        check.rows("blocked caller cannot remove someone else's block", "user_blocks", token=a if token == b else b,
                   query=block_query, method="DELETE", expected=[])
        rows = check.rows(label + " removes own block", "user_blocks", token=token, query=block_query, method="DELETE")
        check.expect(len(rows) == 1, label + " unblocking removes exactly one row")
        check.rows(label + " unblocking restores consented contact access", "rpc/reveal_listing_contact", token=b,
                   method="POST", body=reveal, expected=[{"contact_kind": "email", "contact_value": value}])
    check.denied("caller cannot create a block on another user's behalf", "user_blocks", token=b, method="POST",
                 body={"blocker_id": owner, "blocked_id": other})
    check.rows("owner withdraws contact disclosure consent", "profile_contacts", token=a, query=query,
               method="PATCH", body={"reveal_consent": False})
    check.rows("withdrawing owner consent stops new contact disclosure", "rpc/reveal_listing_contact", token=b,
               method="POST", body=reveal, expected=[])


def report_checks(stack, check, a, b, m, owner, other, moderator, target):
    report = check.rows("caller creates listing report using caller JWT", "reports", token=b, method="POST", status=201,
                        body={"listing_id": target, "reason": "Synthetic report reason"})[0]
    report_id = report["id"]
    check.expect(report["reporter_id"] == other and report["state"] == "open", "report author and initial state are assigned by database")
    check.rows("reporter can read own report", "reports", token=b, query=eq(report_id), expected=[report])
    check.rows("reported listing owner cannot read private report", "reports", token=a, query=eq(report_id), expected=[])
    check.rows("unprivileged third caller cannot read private report", "reports", token=m, query=eq(report_id), expected=[])
    check.denied("reporter cannot set processing state", "reports", token=b, query=eq(report_id), method="PATCH", body={"state": "resolved"})
    check.denied("reporter cannot delete moderation evidence", "reports", token=b, query=eq(report_id), method="DELETE")
    check.denied("caller cannot spoof report author", "reports", token=a, method="POST",
                 body={"reporter_id": other, "listing_id": target, "reason": "Synthetic author spoof"})
    check.denied("report requires exactly one target", "reports", token=b, method="POST",
                 body={"listing_id": target, "account_id": owner, "reason": "Synthetic ambiguous target"},
                 statuses=(400,), codes=("23514",))
    check.denied("report cannot target a missing listing", "reports", token=b, method="POST",
                 body={"listing_id": str(uuid.uuid4()), "reason": "Synthetic missing target"},
                 statuses=(400,), codes=("23514",))
    rows = check.rows("account reports remain supported", "reports", token=b, method="POST", status=201,
                      body={"account_id": owner, "reason": "Synthetic account report"})
    check.expect(len(rows) == 1 and rows[0]["account_id"] == owner, "account report retains only intended target")
    spoofed = stack.token(other, claims={"user_metadata": {"role": "admin", "is_admin": True}})
    check.denied("JWT user metadata cannot grant moderator role", "moderator_roles", token=spoofed, method="POST",
                 body={"user_id": other, "role": "admin"})
    check.rows("user metadata does not expose other reporters' reports", "reports", token=stack.token(owner,
               claims={"user_metadata": {"role": "admin", "is_admin": True}}), query=eq(report_id), expected=[])
    moderate = {"p_kind": "listing", "p_id": target, "p_hidden": True, "p_reason": "Synthetic moderation reason"}
    resolution = {"p_report": report_id, "p_state": "reviewing", "p_reason": "Synthetic review reason"}
    check.denied("user metadata cannot authorize moderation RPC", "rpc/moderate_content", token=spoofed, method="POST", body=moderate)
    check.denied("user metadata cannot authorize report resolution RPC", "rpc/resolve_report", token=spoofed, method="POST", body=resolution)
    check.denied("user metadata cannot authorize report-target inspection", "rpc/moderator_report_target", token=spoofed,
                 method="POST", body={"p_report": report_id})
    # Trusted setup of a synthetic role is NOT performed with an elevated API key.
    stack.sql(f"insert into public.moderator_roles(user_id,role) values({literal(moderator)},'moderator');")
    check.rows("trusted moderator can read private report", "reports", token=m, query=eq(report_id), expected=[report])
    check.rows("moderator role does not permit direct access to private contact", "profile_contacts", token=m,
               query=[("owner_id", "eq." + owner)], expected=[])
    check.rpc("trusted moderator hides listing through audited RPC", "moderate_content", m, moderate)
    check.rows("hidden listing disappears from other authenticated callers", "listings", token=b, query=eq(target), expected=[])
    check.rows("hidden listing disappears from anonymous callers", "listings", query=eq(target), expected=[])
    rows = check.rows("owner still sees own hidden listing", "listings", token=a, query=eq(target))
    check.expect(len(rows) == 1 and rows[0]["moderation_state"] == "hidden", "owner sees real moderation state")
    check.denied("hidden listing cannot disclose contact", "rpc/reveal_listing_contact", token=b,
                 method="POST", body={"p_listing": target, "p_explicit_consent": True})
    rows = check.rows("moderator can inspect sanitized hidden report target", "rpc/moderator_report_target", token=m,
                      method="POST", body={"p_report": report_id})
    safe_keys = {"target_kind", "target_id", "title", "body", "display_name", "moderation_state", "missing"}
    check.expect(len(rows) == 1 and set(rows[0]) == safe_keys and rows[0]["target_id"] == target and
                 rows[0]["missing"] is False and rows[0]["moderation_state"] == "hidden",
                 "moderator target response exposes only documented sanitized fields")
    check.rpc("trusted moderator changes report state through audited RPC", "resolve_report", m, resolution)
    rows = check.rows("reporter can observe reviewed report state", "reports", token=b, query=eq(report_id))
    check.expect(len(rows) == 1 and rows[0]["state"] == "reviewing", "reviewed state persists for reporter")
    rows = check.rows("moderation and report resolution create audit entries", "moderation_actions", token=m,
                      query=[("actor_id", "eq." + moderator), ("order", "action.asc")])
    check.expect([(r["target_id"], r["action"]) for r in rows] == [(target, "hide"), (report_id, "report_reviewing")],
                 "audit records match both authorized operations exactly")
    check.rows("ordinary reporter cannot read moderation audit", "moderation_actions", token=b,
               query=[("actor_id", "eq." + moderator)], expected=[])
    check.rpc("trusted moderator restores listing", "moderate_content", m, {**moderate, "p_hidden": False})
    for removed in ("post", "reply"):
        check.denied("removed moderation target " + removed + " is rejected", "rpc/moderate_content", token=m,
                     method="POST", body={**moderate, "p_kind": removed}, statuses=(400,), codes=("22023",))
    # Keep target alive for session tests; use a separate API-created deletion target.
    doomed = check.rows("owner creates disposable report target", "listings", token=a,
                        method="POST", status=201, body=listing("Disposable report target"))[0]
    preserved = check.rows("reporter reports disposable target", "reports", token=b, method="POST", status=201,
                           body={"listing_id": doomed["id"], "reason": "Synthetic preservation report"})[0]
    check.rows("owner deletes reported target", "listings", token=a, query=eq(doomed["id"]), method="DELETE")
    check.rows("target deletion preserves reporter's moderation evidence", "reports", token=b,
               query=eq(preserved["id"]), expected=[preserved])
    rows = check.rows("moderator sees explicit missing report target", "rpc/moderator_report_target", token=m,
                      method="POST", body={"p_report": preserved["id"]})
    check.expect(rows == [{"target_kind": "listing", "target_id": doomed["id"], "title": None, "body": None,
                          "display_name": None, "moderation_state": None, "missing": True}],
                 "deleted report target does not retain a personal-content snapshot")


def search_checks(stack, check, token, owner):
    ids = sorted([str(uuid.uuid4()) for _ in range(7)], reverse=True)
    timestamp = "2026-01-02T03:04:05+00:00"
    current = datetime.now(timezone.utc).isoformat()
    needle = 'alpha "quote", (group) \\path 50%_match'
    titles = [needle, "alpha second", "beta third", needle.replace("50%_match", "50XYZXmatch"),
              "alpha fifth", "Expired synthetic listing", "Closed synthetic listing"]
    inserts = ["begin;"]
    for index, (identifier, title) in enumerate(zip(ids, titles)):
        expiry = "'2026-02-01T03:04:05+00:00'" if index == 5 else "now()+interval '1 day'"
        state = "closed" if index == 6 else "active"
        inserts.append(
            "insert into public.listings(id,owner_id,kind,title,description,quantity,created_at,expires_at,status) values("
            f"{literal(identifier)},{literal(owner)},'request',{literal(title)},'Synthetic fixture only',1,"
            f"{literal(timestamp)},{expiry},{literal(state)});")
    inserts.append("commit;")
    stack.sql("\n".join(inserts))
    scope = ("id", "in.(" + ",".join(ids[:5]) + ")")
    common = [("select", "id,title,created_at"), scope, ("order", "created_at.desc,id.desc"), ("limit", "2")]
    for who, jwt in (("anonymous", None), ("authenticated", token)):
        rows = check.rows(who + " first pagination page succeeds", "listings", token=jwt, query=common)
        check.expect([r["id"] for r in rows] == ids[:2], who + " timestamp ties are ordered deterministically")
        cursor = f"(created_at.lt.{timestamp},and(created_at.eq.{timestamp},id.lt.{ids[1]}))"
        rows = check.rows(who + " second pagination page succeeds", "listings", token=jwt, query=common + [("or", cursor)])
        check.expect([r["id"] for r in rows] == ids[2:4], who + " keyset second page has no repeat at timestamp ties")
        final_cursor = f"(created_at.lt.{timestamp},and(created_at.eq.{timestamp},id.lt.{ids[3]}))"
        rows = check.rows(who + " final pagination page succeeds", "listings", token=jwt, query=common + [("or", final_cursor)])
        check.expect([r["id"] for r in rows] == ids[4:5], who + " keyset final page does not omit timestamp-tied rows")
        rows = check.rows(who + " combined search and cursor request succeeds", "listings", token=jwt,
                          query=common + [("or", '(title.ilike."%alpha%",description.ilike."%alpha%")'), ("or", cursor)])
        check.expect([r["id"] for r in rows] == ids[3:5], who + " search OR and cursor OR combine as AND")
        # The two escaping layers match app/lib/domain.dart.
        like = needle.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        quoted = like.replace("\\", "\\\\").replace('"', '\\"')
        pattern = '"%' + quoted + '%"'
        check.rows(who + " literal punctuation and wildcard search matches only exact fixture", "listings", token=jwt,
                   query=[("select", "id"), scope, ("or", f"(title.ilike.{pattern},description.ilike.{pattern})")],
                   expected=[{"id": ids[0]}])
    rows = check.rows("default feed filters closed and expired listings", "listings", token=token,
                      query=[("select", "id"), ("id", "in.(" + ",".join(ids) + ")"), ("status", "eq.active"),
                             ("expires_at", "gt." + current), ("order", "created_at.desc,id.desc")])
    check.expect([r["id"] for r in rows] == ids[:5], "default feed contains all and only active unexpired fixtures")
    check.denied("expired listing cannot reveal contact", "rpc/reveal_listing_contact", token=token,
                 method="POST", body={"p_listing": ids[5], "p_explicit_consent": True})
    check.denied("closed listing cannot reveal contact", "rpc/reveal_listing_contact", token=token,
                 method="POST", body={"p_listing": ids[6], "p_explicit_consent": True})


def session_checks(stack, check, token, owner, target):
    invalid_tokens = (
        ("expired", stack.token(owner, claims={"iat": int(time.time()) - 7200, "exp": int(time.time()) - 3600})),
        ("future-not-before", stack.token(owner, claims={"nbf": int(time.time()) + 3600, "exp": int(time.time()) + 7200})),
        ("bad-signature", caller_token("synthetic-wrong-key-not-a-credential", owner, stack.api)),
        ("malformed", "synthetic.invalid.jwt"),
    )
    for label, invalid in invalid_tokens:
        for method, body in (("GET", None), ("PATCH", {"title": "Forbidden session mutation"})):
            code, _ = stack.call("listings", query=eq(target), token=invalid, method=method, body=body)
            check.expect(code == 401, label + " JWT is rejected for " + method + " without anonymous fallback")
    rows = check.rows("valid JWT still reads unchanged listing after failed session writes", "listings", token=token, query=eq(target))
    check.expect(len(rows) == 1 and rows[0]["title"] == "Updated request", "rejected session writes have no side effects")


def anonymous_and_removed_checks(stack, check):
    for removed in ("posts", "replies", "topics"):
        code, _ = stack.call(removed, [("select", "*"), ("limit", "1")])
        check.expect(code == 404, f"removed {removed} endpoint is absent")
    code, _ = stack.call("rpc/reserve_upload", method="POST", body={
        "p_post": None, "p_listing": str(uuid.uuid4()), "p_bytes": 100, "p_mime": "image/jpeg",
    })
    check.expect(code == 404, "removed four-argument upload RPC is absent")
    for table in ("profile_contacts", "reports", "moderator_roles", "upload_intents"):
        check.denied(f"anonymous access to {table} is denied", table,
                     query=[("select", "*"), ("limit", "1")], statuses=(401, 403))
    check.denied("anonymous posting is denied at actual API", "listings", method="POST", body=listing(), statuses=(401, 403))
    check.denied("anonymous contact RPC is denied at actual API", "rpc/reveal_listing_contact", method="POST",
                 body={"p_listing": str(uuid.uuid4()), "p_explicit_consent": True}, statuses=(401, 403))


def run(stack):
    check = Checks(stack)
    identifiers = [str(uuid.uuid4()) for _ in range(3)]
    created = False
    try:
        stack.sql("begin; insert into auth.users(id) values " +
                  ",".join("(" + literal(identifier) + ")" for identifier in identifiers) + "; commit;")
        created = True
        anonymous_and_removed_checks(stack, check)
        marketplace_checks(stack, check, *identifiers)
    finally:
        if created:
            ids = ",".join(literal(identifier) for identifier in identifiers)
            # Audit rows deliberately survive account deletion in production. Here
            # remove only synthetic actor rows, never broad table cleanup.
            stack.sql("begin; "
                      f"delete from public.moderation_actions where actor_id in ({ids}); "
                      f"delete from auth.users where id in ({ids}); commit;")
    print(f"PASS {check.passed} live local PostgREST checks (synthetic caller JWTs; no GoTrue lifecycle proof)")
    return check.passed


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        if len(argv) != 1:
            raise HarnessFailure("Expected one private local status-file path")
        status = json.loads(Path(argv[0]).read_text())
        run(LocalStack(status))
    except HarnessFailure as error:
        print("FAIL local API checks: " + str(error), file=sys.stderr)
        return 1
    except Exception:
        # Tracebacks can include credentials in URLs, requests or DB diagnostics.
        print("FAIL local API checks: infrastructure error; sensitive details suppressed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
