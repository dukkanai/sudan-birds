#!/usr/bin/env python3
"""Disposable loopback Auth lifecycle + real-session RLS, never hosted services.

Requires explicit --local-disposable and a private Supabase CLI status file.
No credentials, response bodies, user IDs, emails or arbitrary errors are logged.
See docs/local-auth-lifecycle.md for scope, expiry semantics and evidence limits.
"""
import base64
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import time
import tomllib
import uuid


ROOT = Path(__file__).resolve().parents[1]
MAX_BODY = 65536
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"


class HarnessFailure(Exception):
    """Only static, credential-free messages may be used."""


def require(condition, label):
    if not condition:
        raise HarnessFailure(label)


def local_origin(value):
    # Exact strings prevent DNS, userinfo, parser normalization, encoded hosts,
    # alternate ports, proxy destinations, query overrides and URL injection.
    allowed = {"http://127.0.0.1:54321": "127.0.0.1", "http://[::1]:54321": "::1"}
    require(isinstance(value, str), "Local API origin required")
    origin = value[:-1] if value.endswith("/") else value
    require(origin in allowed, "Refusing unexpected local API origin or port")
    return origin, allowed[origin]


def configuration(status):
    require(isinstance(status, dict), "Invalid local status configuration")
    values = [status.get(name, status.get(name.lower())) for name in
              ("API_URL", "ANON_KEY", "SERVICE_ROLE_KEY", "JWT_SECRET")]
    origin, host = local_origin(values[0])
    for value in values[1:]:
        require(isinstance(value, str) and 0 < len(value) <= 8192 and
                all(32 < ord(c) < 127 for c in value), "Invalid local test credential")
    require(values[1] != values[2], "Local public and admin keys must differ")
    return origin, host, *values[1:]


def read_status(path):
    # Do not follow symlinks or read a public/nonregular credential file.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
                not info.st_mode & 0o077, "Status file must be private and owner-controlled")
        data = source.read(MAX_BODY + 1)
    require(len(data) <= MAX_BODY, "Status file exceeds bounded size")
    return json.loads(data)


def segment(value):
    return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":"),
                                               allow_nan=False).encode()).rstrip(b"=").decode()


def signed_claims(secret, token):
    """Verify a local issued HS256 token before constructing the expiry fixture."""
    try:
        header, payload, signature = token.split(".")
        decode = lambda part: base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
        header_data = json.loads(decode(header))
        claims = json.loads(decode(payload))
        expected = hmac.new(secret.encode(), (header + "." + payload).encode(), hashlib.sha256).digest()
        valid = (header_data.get("alg") == "HS256" and isinstance(claims, dict) and
                 claims.get("role") == "authenticated" and
                 hmac.compare_digest(expected, decode(signature)))
    except Exception:
        raise HarnessFailure("Local issued token cannot be verified for expiry fixture") from None
    require(valid, "Local issued token is not the expected authenticated HS256 token")
    return claims


def expired_fixture(secret, access_token, *, now=None):
    claims = signed_claims(secret, access_token).copy()
    now = int(time.time()) if now is None else now
    claims.update(iat=now - 3600, exp=now - 120)
    claims.pop("nbf", None)
    message = segment({"alg": "HS256", "typ": "JWT"}) + "." + segment(claims)
    signature = hmac.new(secret.encode(), message.encode(), hashlib.sha256).digest()
    return message + "." + base64.urlsafe_b64encode(signature).rstrip(b"=").decode()


class LocalAuth:
    def __init__(self, status):
        self.origin, self.host, self.public_key, self.admin_key, self.secret = configuration(status)
        self.remaining = 80
        self.deadline = time.monotonic() + 120

    def start_cleanup(self):
        self.remaining = 8  # Two exact users: GET, DELETE, confirming GET each.
        self.deadline = time.monotonic() + 30

    def request(self, method, path, *, token=None, body=None, admin=False):
        # Revalidate immediately before every credential-bearing request, including cleanup.
        _, host = local_origin(self.origin)
        require(host == self.host, "Local API destination changed")
        allowed_admin = (method == "POST" and path == "/auth/v1/admin/users") or (
            method in ("GET", "DELETE") and re.fullmatch(r"/auth/v1/admin/users/" + UUID, path))
        allowed = allowed_admin or (method, path) in {
            ("POST", "/auth/v1/token?grant_type=password"),
            ("POST", "/auth/v1/token?grant_type=refresh_token"),
            ("GET", "/auth/v1/user"), ("POST", "/auth/v1/logout?scope=local"),
        } or (method in ("GET", "POST", "PATCH", "DELETE") and re.fullmatch(
            r"/rest/v1/(?:profiles|listings)(?:\?id=eq\." + UUID + r")?", path))
        require(allowed and (not admin or allowed_admin), "Unexpected test request path or privilege")
        require(token != self.admin_key, "Admin key cannot be a caller token")
        if token is not None:
            require(isinstance(token, str) and 0 < len(token) <= 8192 and
                    all(32 < ord(c) < 127 for c in token), "Invalid caller token shape")
        require(self.remaining > 0 and time.monotonic() < self.deadline,
                "Local request budget exhausted")
        data = None if body is None else json.dumps(body, allow_nan=False).encode()
        require(data is None or len(data) <= MAX_BODY, "Request body exceeds bounded size")
        headers = {"apikey": self.admin_key if admin else self.public_key,
                   "Content-Type": "application/json", "Prefer": "return=representation"}
        if admin or token is not None:
            headers["Authorization"] = "Bearer " + (self.admin_key if admin else token)
        self.remaining -= 1
        deadline = min(self.deadline, time.monotonic() + 10)
        # http.client does not consult proxy env vars or follow redirects.
        connection = http.client.HTTPConnection(host, 54321, timeout=5)
        try:
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            require(not 300 <= response.status < 400, "HTTP redirect refused")
            chunks = bytearray()
            while True:
                require(time.monotonic() < deadline, "Local response deadline exceeded")
                if connection.sock is not None:
                    connection.sock.settimeout(min(5, max(0.01, deadline - time.monotonic())))
                chunk = response.read1(min(4096, MAX_BODY + 1 - len(chunks)))
                if not chunk:
                    break
                chunks.extend(chunk)
                require(len(chunks) <= MAX_BODY, "Response exceeds bounded size")
            require(time.monotonic() < deadline, "Local response deadline exceeded")
            try:
                payload = json.loads(chunks) if chunks else None
            except (ValueError, UnicodeError):
                raise HarnessFailure("Invalid local JSON response") from None
            return response.status, payload
        finally:
            connection.close()

    def admin(self, method, identifier=None, body=None):
        path = "/auth/v1/admin/users" + ("/" + identifier if identifier else "")
        return self.request(method, path, body=body, admin=True)

    def rest(self, method, table, *, token, identifier=None, body=None):
        path = "/rest/v1/" + table + ("?id=eq." + identifier if identifier else "")
        return self.request(method, path, token=token, body=body)


@dataclass(repr=False)
class Fixture:
    identifier: str = field(default_factory=lambda: str(uuid.uuid4()))
    marker: str = field(default_factory=lambda: secrets.token_hex(24))
    password: str = field(default_factory=lambda: "Local-Aa1!" + secrets.token_urlsafe(24))

    @property
    def email(self):
        return "auth-fixture-" + self.identifier + "@sudan-birds.invalid"

    def matches(self, user):
        return (isinstance(user, dict) and user.get("id") == self.identifier and
                user.get("email") == self.email and isinstance(user.get("app_metadata"), dict) and
                user["app_metadata"].get("local_auth_fixture") == self.marker)


class Checks:
    def __init__(self):
        self.passed = 0

    def expect(self, condition, label):
        require(condition, label)
        self.passed += 1
        print(f"ok {self.passed} - {label}")

    def response(self, result, status, label):
        code, payload = result
        self.expect(code == status, label)
        return payload

    def denied(self, result, statuses, errors, label, *, field="error_code"):
        code, payload = result
        self.expect(code in statuses and isinstance(payload, dict) and
                    payload.get(field) in errors and "access_token" not in payload and
                    "refresh_token" not in payload, label)

    def rows(self, result, expected, label, *, status=200):
        code, payload = result
        self.expect(code == status and isinstance(payload, list) and
                    (payload == expected if expected is not None else len(payload) == 1), label)
        return payload


def missing(result):
    code, payload = result
    return code == 404 and isinstance(payload, dict) and payload.get("error_code") == "user_not_found"


def create_fixtures(stack, check, attempted):
    for _ in range(2):
        fixture = Fixture()
        check.expect(missing(stack.admin("GET", fixture.identifier)),
                     "fresh synthetic user ID is absent before creation")
        # Record BEFORE POST: its response can be lost after a successful write.
        attempted.append(fixture)
        user = check.response(stack.admin("POST", body={
            "id": fixture.identifier, "email": fixture.email, "password": fixture.password,
            "email_confirm": True, "app_metadata": {"local_auth_fixture": fixture.marker},
        }), 200, "local Admin creates an email-confirmed synthetic account without sending mail")
        check.expect(fixture.matches(user) and user.get("role") == "authenticated" and
                     bool(user.get("email_confirmed_at")), "created account matches this invocation")


def cleanup(stack, attempted):
    stack.start_cleanup()
    failed = False
    for fixture in reversed(attempted):
        try:
            result = stack.admin("GET", fixture.identifier)
            if missing(result):
                continue
            require(result[0] == 200 and fixture.matches(result[1]),
                    "Cleanup refuses an unverified synthetic identity")
            require(stack.admin("DELETE", fixture.identifier, body={"should_soft_delete": False})[0] == 200,
                    "Synthetic account deletion failed")
            require(missing(stack.admin("GET", fixture.identifier)), "Synthetic account deletion unconfirmed")
        except Exception:
            # Attempt the other exact fixture even if the first cleanup fails.
            # Never retry a write, enumerate accounts, or echo server errors.
            failed = True
    require(not failed, "Local synthetic cleanup incomplete; destroy disposable stack")


def session(stack, check, result, fixture, label):
    payload = check.response(result, 200, label)
    require(isinstance(payload, dict), "Invalid local session response")
    access, refresh = payload.get("access_token"), payload.get("refresh_token")
    require(isinstance(access, str) and isinstance(refresh, str) and access and refresh,
            "Local session tokens missing")
    claims = signed_claims(stack.secret, access)
    check.expect(payload.get("token_type") == "bearer" and fixture.matches(payload.get("user")) and
                 claims.get("sub") == fixture.identifier and claims.get("aud") == "authenticated" and
                 isinstance(claims.get("session_id"), str) and
                 re.fullmatch(UUID, claims["session_id"]) is not None and
                 type(claims.get("exp")) is int and claims["exp"] > time.time() + 30,
                 "issued session has the expected user, role and unexpired session ID")
    return access, refresh, claims["session_id"]


def password_login(stack, fixture, password=None):
    return stack.request("POST", "/auth/v1/token?grant_type=password", body={
        "email": fixture.email, "password": fixture.password if password is None else password})


def refresh_session(stack, refresh):
    return stack.request("POST", "/auth/v1/token?grant_type=refresh_token", body={"refresh_token": refresh})


def lifecycle_checks(stack, check, owner, other):
    check.denied(password_login(stack, owner, "deliberately-wrong-local-password"), (400,),
                 ("invalid_credentials",), "wrong password cannot create a session")
    check.denied(refresh_session(stack, "invalid-local-refresh-token"), (400,),
                 ("validation_failed",), "malformed refresh token cannot create a session")
    a, refresh_a, session_a = session(stack, check, password_login(stack, owner), owner, "owner password sign-in succeeds")
    b, refresh_b, _ = session(stack, check, password_login(stack, other), other, "second user password sign-in succeeds")
    for fixture, token in ((owner, a), (other, b)):
        user = check.response(stack.request("GET", "/auth/v1/user", token=token), 200,
                              "Auth validates the real issued user access token")
        check.expect(fixture.matches(user), "Auth get-user returns the correct synthetic identity")
    check.denied(stack.request("GET", "/auth/v1/admin/users/" + other.identifier, token=a), (403,),
                 ("not_admin",), "ordinary issued user token has no Admin privilege")
    check.denied(stack.rest("POST", "profiles", token=a, body={"id": other.identifier, "display_name": "Spoofed"}),
                 (403,), ("42501",), "real user cannot create another user's profile", field="code")
    for fixture, token in ((owner, a), (other, b)):
        check.rows(stack.rest("POST", "profiles", token=token, body={
            "id": fixture.identifier, "display_name": "Local Auth fixture"}), None,
            "real session creates only its own profile", status=201)
    listing = {"kind": "request", "title": "Local Auth request", "description": "Synthetic local fixture", "quantity": 1}
    check.denied(stack.rest("POST", "listings", token=a, body=listing), (403,), ("42501",),
                 "real session cannot publish before terms acceptance", field="code")
    current = datetime.now(timezone.utc).isoformat()
    check.rows(stack.rest("PATCH", "profiles", token=b, identifier=owner.identifier,
                          body={"accepted_terms_at": current}), [], "another user cannot accept owner terms")
    check.rows(stack.rest("PATCH", "profiles", token=a, identifier=owner.identifier,
                          body={"accepted_terms_at": current}), None, "owner accepts own terms")
    row = check.rows(stack.rest("POST", "listings", token=a, body=listing), None,
                     "real session publishes an owner-bound listing", status=201)[0]
    require(isinstance(row, dict) and isinstance(row.get("id"), str) and re.fullmatch(UUID, row["id"]),
            "Unexpected listing identity")
    identifier = row["id"]
    check.expect(row.get("owner_id") == owner.identifier, "listing owner comes from the issued JWT")
    for method, body in (("PATCH", {"title": "Forbidden cross-user write"}), ("DELETE", None)):
        check.rows(stack.rest(method, "listings", token=b, identifier=identifier, body=body), [],
                   "cross-user listing mutation affects no rows")
    check.rows(stack.rest("GET", "listings", token=a, identifier=identifier), [row],
               "failed cross-user mutations leave owner data unchanged")
    fresh_a, fresh_refresh_a, fresh_session_a = session(stack, check, refresh_session(stack, refresh_a),
                                                       owner, "owner refresh exchange succeeds")
    check.expect(fresh_refresh_a != refresh_a and fresh_session_a == session_a,
                 "refresh rotates refresh token and retains the same user session")
    check.rows(stack.rest("PATCH", "listings", token=fresh_a, identifier=identifier,
                          body={"title": "Updated with refreshed token"}), None,
               "refreshed real token retains owner write permission")
    check.rows(stack.rest("PATCH", "profiles", token=fresh_a, identifier=other.identifier,
                          body={"display_name": "Forbidden"}), [], "refresh does not broaden ownership")
    for token, label in (("malformed.local.token", "malformed access token"),
                         (expired_fixture(stack.secret, fresh_a), "correctly signed expired local fixture")):
        check.denied(stack.request("GET", "/auth/v1/user", token=token), (401, 403), ("bad_jwt",),
                     "Auth rejects " + label)
        check.denied(stack.rest("PATCH", "profiles", token=token, identifier=owner.identifier,
                                body={"display_name": "Forbidden expired write"}),
                     (401,), ("PGRST301", "PGRST303"), "PostgREST rejects " + label, field="code")
    check.response(stack.request("POST", "/auth/v1/logout?scope=local", token=fresh_a), 204,
                   "server acknowledges current-session logout")
    check.denied(refresh_session(stack, fresh_refresh_a), (400,),
                 ("refresh_token_not_found", "refresh_token_already_used"), "logout revokes the current refresh token")
    check.denied(stack.request("GET", "/auth/v1/user", token=fresh_a), (401, 403), ("session_not_found",),
                 "Auth rejects a session removed by logout")
    # PostgREST verifies JWT validity, not auth.sessions existence. This is a
    # deliberate limitation check, NOT a universal immediate-revocation claim.
    require(signed_claims(stack.secret, fresh_a)["exp"] > time.time() + 5,
            "Issued access JWT expired before residual-access check")
    check.rows(stack.rest("PATCH", "profiles", token=fresh_a, identifier=owner.identifier,
                          body={"display_name": "Residual JWT capability"}), None,
               "issued unexpired JWT still authorizes owner RLS writes after logout")
    check.rows(stack.rest("PATCH", "profiles", token=fresh_a, identifier=other.identifier,
                          body={"display_name": "Forbidden"}), [], "residual access JWT remains owner-limited")
    session(stack, check, refresh_session(stack, refresh_b), other,
            "one user's logout does not revoke the other user's refresh token")
    new_a, _, new_session = session(stack, check, password_login(stack, owner), owner,
                                     "owner can sign in again after logout")
    check.expect(new_session != session_a, "fresh sign-in creates a different session")
    check.rows(stack.rest("DELETE", "listings", token=new_a, identifier=identifier), None,
               "fresh sign-in preserves owner ability to delete own listing")
    check.rows(stack.rest("GET", "listings", token=b, identifier=identifier), [], "deleted listing is absent")


def run(stack):
    check, attempted = Checks(), []
    try:
        create_fixtures(stack, check, attempted)
        lifecycle_checks(stack, check, *attempted)
    finally:
        cleanup(stack, attempted)
    check.expect(True, "both exact synthetic Auth users were deleted and absence verified")
    print(f"PASS {check.passed} local Auth lifecycle/RLS checks; no hosted or provider validation")
    return check.passed


def source_evidence():
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
                            text=True, timeout=5, check=False)
    require(result.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}\n?", result.stdout),
            "Cannot identify checked-out source")
    print("SOURCE commit " + result.stdout.strip())
    paths = ["scripts/auth_lifecycle.py", "scripts/auth_lifecycle_test.py", "scripts/install_supabase.py",
             ".github/workflows/ci.yml", "supabase/config.toml"]
    paths += [str(path.relative_to(ROOT)) for path in sorted((ROOT / "supabase/migrations").glob("*.sql"))]
    for relative in paths:
        print("SOURCE SHA256 " + relative + " " + hashlib.sha256((ROOT / relative).read_bytes()).hexdigest())


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        require(len(argv) == 2 and argv[0] == "--local-disposable",
                "Expected --local-disposable and one private status-file path")
        config = tomllib.loads((ROOT / "supabase/config.toml").read_text())
        require(config.get("project_id") == "sudan-birds-local" and
                config.get("api", {}).get("port", 54321) == 54321 and
                not config.get("api", {}).get("external_url"), "Unexpected disposable project configuration")
        stack = LocalAuth(read_status(argv[1]))
        source_evidence()
        run(stack)
    except HarnessFailure as error:
        print("FAIL local Auth checks: " + str(error), file=sys.stderr)
        return 1
    except Exception:
        print("FAIL local Auth checks: infrastructure error; sensitive details suppressed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
