#!/usr/bin/env python3
"""Offline guardrail tests for the loopback-only caller-JWT API harness.

No database, network request, real credentials or token logging is used here.
These tests do not count as the live integration checks.
"""
import base64
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import hmac
import io
import json
import os
import subprocess
import unittest
from unittest.mock import Mock, patch
import urllib.error

import api_smoke as api


SENTINEL = "synthetic-test-secret-never-log-this"
SUBJECT = "00000000-0000-4000-8000-000000000001"


def configuration():
    return {"API_URL": "http://127.0.0.1:54321", "ANON_KEY": SENTINEL + "-anon",
            "DB_URL": "postgresql://postgres:" + SENTINEL + "@127.0.0.1:54322/postgres",
            "JWT_SECRET": SENTINEL}


def response(payload=b"[]", status=200):
    result = io.BytesIO(payload)
    result.code = status
    return result


def decode(segment):
    return json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))


class ConfigurationTests(unittest.TestCase):
    def test_literal_ipv4_and_lowercase_status_keys_work(self):
        status = {name.lower(): value for name, value in configuration().items()}
        target, _, _, env = api.local_configuration(status)
        self.assertEqual(target, "http://127.0.0.1:54321")
        self.assertEqual(env["PGHOSTADDR"], "127.0.0.1")
        self.assertEqual(env["PGPORT"], "54322")

    def test_literal_ipv6_loopback_works(self):
        status = configuration()
        status["API_URL"] = "http://[::1]:54321/"
        status["DB_URL"] = "postgres://postgres@[::1]:54322/postgres"
        target, _, _, env = api.local_configuration(status)
        self.assertEqual(target, "http://[::1]:54321")
        self.assertEqual(env["PGHOSTADDR"], "::1")

    def test_hosted_or_dns_api_targets_rejected_before_io(self):
        for target in ("https://example.supabase.co", "http://localhost:54321", "http://0.0.0.0:54321",
                       "http://127.0.0.2:54321", "http://127.0.0.1.example.invalid:54321",
                       "http://2130706433:54321", "http://[::ffff:127.0.0.1]:54321"):
            with self.subTest(target=target):
                with self.assertRaises(api.HarnessFailure):
                    api.local_configuration({**configuration(), "API_URL": target})

    def test_nonlocal_database_rejected_even_with_local_api(self):
        for target in ("postgres://postgres@example.invalid:5432/postgres", "postgres://postgres@localhost:54322/postgres",
                       "postgres://postgres@0.0.0.0:54322/postgres"):
            with self.subTest(target=target):
                with self.assertRaises(api.HarnessFailure):
                    api.local_configuration({**configuration(), "DB_URL": target})

    def test_api_url_injection_and_non_http_rejected(self):
        for suffix in ("/rest/v1", "?host=example.invalid", "#fragment"):
            with self.subTest(suffix=suffix):
                with self.assertRaises(api.HarnessFailure):
                    api.local_configuration({**configuration(), "API_URL": "http://127.0.0.1:54321" + suffix})
        for target in ("http://userinfo@127.0.0.1:54321", "https://127.0.0.1:54321", "file:///tmp/test",
                       "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:bad"):
            with self.subTest(target=target):
                with self.assertRaises(api.HarnessFailure):
                    api.local_configuration({**configuration(), "API_URL": target})

    def test_database_connection_overrides_rejected(self):
        for target in ("postgres://postgres@127.0.0.1:54322/postgres?host=example.invalid",
                       "postgres://postgres@127.0.0.1:54322/postgres#fragment",
                       "postgres://postgres@127.0.0.1:54322/host%3Dexample.invalid",
                       "postgres://postgres@127.0.0.1:54322/", "postgres://postgres@127.0.0.1/postgres"):
            with self.subTest(target=target):
                with self.assertRaises(api.HarnessFailure):
                    api.local_configuration({**configuration(), "DB_URL": target})

    def test_required_values_must_be_nonempty_strings(self):
        for name in configuration():
            for value in (None, "", 123, {}):
                with self.subTest(name=name, value=value):
                    with self.assertRaises(api.HarnessFailure):
                        api.local_configuration({**configuration(), name: value})
        with self.assertRaises(api.HarnessFailure):
            api.local_configuration([])

    def test_libpq_environment_cannot_override_loopback_or_load_services(self):
        inherited = {"PGHOSTADDR": "example.invalid", "PGSERVICE": "external", "PGOPTIONS": "unsafe",
                     "PGSERVICEFILE": "/tmp/unsafe-service", "PGPASSFILE": "/tmp/unsafe-pass", "PATH": "/safe/path"}
        with patch.dict(os.environ, inherited, clear=True):
            _, _, _, env = api.local_configuration(configuration())
        self.assertEqual(env["PGHOSTADDR"], "127.0.0.1")
        self.assertEqual(env["PGPASSFILE"], os.devnull)
        self.assertEqual(env["PGSERVICEFILE"], os.devnull)
        self.assertNotIn("PGSERVICE", env)
        self.assertNotIn("unsafe", env["PGOPTIONS"])
        self.assertEqual(env["PATH"], "/safe/path")


class TokenTests(unittest.TestCase):
    def test_short_lived_authenticated_hmac_jwt_is_cryptographically_valid(self):
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(output):
            token = api.caller_token(SENTINEL, SUBJECT, "http://127.0.0.1:54321", now=1000)
        header, payload, signature = token.split(".")
        self.assertEqual(decode(header), {"alg": "HS256", "typ": "JWT"})
        claims = decode(payload)
        self.assertEqual(claims, {"aud": "authenticated", "role": "authenticated", "sub": SUBJECT,
                                 "iss": "http://127.0.0.1:54321/auth/v1", "iat": 1000, "exp": 1900})
        expected = hmac.new(SENTINEL.encode(), (header + "." + payload).encode(), hashlib.sha256).digest()
        actual = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
        self.assertTrue(hmac.compare_digest(actual, expected))
        self.assertEqual(output.getvalue(), "")

    def test_expired_and_future_tokens_preserve_authenticated_role(self):
        for extra in ({"exp": 1}, {"nbf": 5000}, {"user_metadata": {"role": "admin"}}):
            claims = decode(api.caller_token(SENTINEL, SUBJECT, "http://127.0.0.1:54321", now=1000, claims=extra).split(".")[1])
            self.assertEqual(claims["role"], "authenticated")
            for name, value in extra.items():
                self.assertEqual(claims[name], value)

    def test_token_signer_refuses_privileged_database_roles(self):
        for role in ("service_role", "postgres", "admin", None):
            with self.assertRaises(api.HarnessFailure):
                api.caller_token(SENTINEL, SUBJECT, "http://127.0.0.1:54321", claims={"role": role})


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.stack = api.LocalStack(configuration())
        self.stack.opener = Mock()

    def test_caller_jwt_and_anonymous_key_use_distinct_headers(self):
        self.stack.opener.open.return_value = response()
        token = self.stack.token(SUBJECT)
        self.stack.call("listings", token=token)
        request = self.stack.opener.open.call_args.args[0]
        self.assertTrue(request.get_header("Authorization") == "Bearer " + token)
        self.assertTrue(request.get_header("Apikey") == configuration()["ANON_KEY"])
        self.assertEqual(request.get_header("Prefer"), "return=representation")
        self.assertEqual(self.stack.opener.open.call_args.kwargs["timeout"], 15)

    def test_anonymous_call_has_no_caller_authorization(self):
        self.stack.opener.open.return_value = response()
        self.stack.call("listings")
        request = self.stack.opener.open.call_args.args[0]
        self.assertIsNone(request.get_header("Authorization"))

    def test_duplicate_or_parameters_survive_url_encoding(self):
        self.stack.opener.open.return_value = response()
        query = [("or", '(title.ilike."%alpha%")'), ("or", "(created_at.lt.2026-01-01)")]
        self.stack.call("listings", query)
        request = self.stack.opener.open.call_args.args[0]
        self.assertEqual(api.urllib.parse.parse_qsl(api.urllib.parse.urlsplit(request.full_url).query), query)

    def test_write_uses_json_and_requested_method(self):
        self.stack.opener.open.return_value = response(b'[{"title":"Updated request"}]')
        self.stack.call("listings", method="PATCH", body={"title": "Updated request"})
        request = self.stack.opener.open.call_args.args[0]
        self.assertEqual(request.method, "PATCH")
        self.assertEqual(json.loads(request.data), {"title": "Updated request"})

    def test_unexpected_api_paths_never_reach_transport(self):
        for table in ("//example.invalid", "../auth", "listings?select=*", "rpc/private.foo", "https://example.invalid"):
            with self.assertRaises(api.HarnessFailure):
                self.stack.call(table)
        self.stack.opener.open.assert_not_called()

    def test_sqlstate_error_preserved_for_assertion_without_logging(self):
        output = io.StringIO()
        body = json.dumps({"code": "42501", "message": SENTINEL}).encode()
        self.stack.opener.open.side_effect = urllib.error.HTTPError("http://127.0.0.1:54321", 403, "denied", {}, io.BytesIO(body))
        with redirect_stdout(output), redirect_stderr(output):
            status, result = self.stack.call("listings")
        self.assertEqual(status, 403)
        self.assertEqual(result["code"], "42501")
        self.assertEqual(output.getvalue(), "")

    def test_non_json_error_does_not_echo_raw_response(self):
        self.stack.opener.open.return_value = response(SENTINEL.encode())
        with self.assertRaises(api.HarnessFailure) as failure:
            self.stack.call("listings")
        self.assertNotIn(SENTINEL, str(failure.exception))

    def test_response_size_is_bounded(self):
        self.stack.opener.open.return_value = response(b" " * 1_048_577)
        with self.assertRaises(api.HarnessFailure):
            self.stack.call("listings")

    def test_redirect_is_refused_even_if_target_is_loopback(self):
        with self.assertRaises(api.HarnessFailure):
            api.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "http://127.0.0.1:54321/other")

    def test_environment_proxies_are_disabled(self):
        with patch.dict(os.environ, {"http_proxy": "http://example.invalid", "HTTP_PROXY": "http://example.invalid"}):
            stack = api.LocalStack(configuration())
        for handler in stack.opener.handlers:
            if isinstance(handler, api.urllib.request.ProxyHandler):
                self.assertEqual(handler.proxies, {})

    def test_non_json_numbers_never_reach_transport(self):
        with self.assertRaises(ValueError):
            self.stack.call("listings", method="POST", body={"price": float("nan")})
        self.stack.opener.open.assert_not_called()

    def test_psql_does_not_put_secrets_in_argv_or_log_errors(self):
        output = io.StringIO()
        with patch.object(api.subprocess, "run", return_value=Mock(returncode=1, stderr=SENTINEL)) as process:
            with redirect_stdout(output), redirect_stderr(output):
                with self.assertRaises(api.HarnessFailure) as failure:
                    self.stack.sql("select 1")
        self.assertNotIn(SENTINEL, " ".join(process.call_args.args[0]))
        self.assertNotIn(SENTINEL, str(failure.exception))
        self.assertTrue(process.call_args.kwargs["capture_output"])
        self.assertEqual(process.call_args.kwargs["timeout"], 30)
        self.assertEqual(output.getvalue(), "")


class FailureAndCleanupTests(unittest.TestCase):
    def test_main_suppresses_arbitrary_exception_details(self):
        for failure in (RuntimeError(SENTINEL), urllib.error.URLError(SENTINEL),
                        subprocess.TimeoutExpired("unsafe-" + SENTINEL, 30)):
            output = io.StringIO()
            with patch.object(api.Path, "read_text", side_effect=failure):
                with redirect_stdout(output), redirect_stderr(output):
                    result = api.main(["private-status-file.json"])
            self.assertEqual(result, 1)
            self.assertNotIn(SENTINEL, output.getvalue())
            self.assertNotIn("Traceback", output.getvalue())

    def test_main_rejects_hosted_status_without_starting_fixture_io(self):
        output = io.StringIO()
        status = {**configuration(), "API_URL": "https://example.supabase.co"}
        with patch.object(api.Path, "read_text", return_value=json.dumps(status)), patch.object(api, "run") as run:
            with redirect_stdout(output), redirect_stderr(output):
                result = api.main(["private-status-file.json"])
        self.assertEqual(result, 1)
        run.assert_not_called()
        self.assertNotIn(SENTINEL, output.getvalue())

    def test_existing_fixtures_are_cleaned_after_assertion_failure(self):
        stack = Mock()
        with patch.object(api, "anonymous_and_removed_checks", side_effect=api.HarnessFailure("synthetic failure")):
            with self.assertRaises(api.HarnessFailure):
                api.run(stack)
        self.assertEqual(stack.sql.call_count, 2)
        create, cleanup = (call.args[0] for call in stack.sql.call_args_list)
        ids = api.re.findall(r"'[0-9a-f-]{36}'", create)
        self.assertEqual(len(ids), 3)
        self.assertIn("delete from public.moderation_actions where actor_id in (", cleanup)
        self.assertIn("delete from auth.users where id in (", cleanup)
        for identifier in ids:
            self.assertEqual(cleanup.count(identifier), 2)
        self.assertNotIn("truncate", cleanup.lower())

    def test_no_cleanup_after_atomic_fixture_creation_failure(self):
        stack = Mock()
        stack.sql.side_effect = api.HarnessFailure("synthetic SQL failure")
        with self.assertRaises(api.HarnessFailure):
            api.run(stack)
        self.assertEqual(stack.sql.call_count, 1)

    def test_check_counter_does_not_increment_on_failure(self):
        checks = api.Checks(Mock())
        with self.assertRaises(api.HarnessFailure):
            checks.expect(False, "synthetic check")
        self.assertEqual(checks.passed, 0)

    def test_expected_sqlstate_not_just_status_is_required(self):
        stack = Mock()
        stack.call.return_value = (403, {"code": "UNRELATED"})
        with self.assertRaises(api.HarnessFailure):
            api.Checks(stack).denied("synthetic denial", "listings")

    def test_failure_diagnostic_only_allows_http_status_and_sqlstate(self):
        stack = Mock()
        stack.call.return_value = (403, {"code": "42501", "message": SENTINEL, "details": SENTINEL})
        with self.assertRaises(api.HarnessFailure) as failure:
            api.Checks(stack).rows("synthetic check", "listings")
        self.assertIn("HTTP 403", str(failure.exception))
        self.assertIn("42501", str(failure.exception))
        self.assertNotIn(SENTINEL, str(failure.exception))
        detail = api.Checks.diagnostic(SENTINEL, {"code": SENTINEL})
        self.assertNotIn(SENTINEL, detail)
        self.assertIn("unknown", detail)
        self.assertIn("none", detail)

    def test_unexpected_empty_insert_response_fails_rows_assertion(self):
        stack = Mock()
        stack.call.return_value = (201, None)
        with self.assertRaises(api.HarnessFailure):
            api.Checks(stack).rows("synthetic insertion", "listings", status=201)


if __name__ == "__main__":
    unittest.main()
