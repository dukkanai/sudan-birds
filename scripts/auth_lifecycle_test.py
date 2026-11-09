#!/usr/bin/env python3
"""Offline guardrail/orchestration tests; no Auth server, real account or network."""
import base64
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import auth_lifecycle as auth


SECRET = "synthetic-sentinel-never-print"
ID = "00000000-0000-4000-8000-000000000001"
SESSION = "00000000-0000-4000-8000-000000000002"
ABSENT = (404, {"error_code": "user_not_found"})


def configuration():
    return {"API_URL": "http://127.0.0.1:54321", "ANON_KEY": SECRET + "-public",
            "SERVICE_ROLE_KEY": SECRET + "-admin", "JWT_SECRET": SECRET}


def token(claims=None, *, secret=SECRET, algorithm="HS256"):
    payload = {"sub": ID, "role": "authenticated", "aud": "authenticated",
               "session_id": SESSION, "iat": int(time.time()), "exp": int(time.time()) + 3600}
    payload.update(claims or {})
    message = auth.segment({"alg": algorithm, "typ": "JWT"}) + "." + auth.segment(payload)
    signature = hmac.new(secret.encode(), message.encode(), hashlib.sha256).digest()
    return message + "." + base64.urlsafe_b64encode(signature).rstrip(b"=").decode()


def user(fixture):
    return {"id": fixture.identifier, "email": fixture.email, "email_confirmed_at": "2026-11-09T00:00:00Z",
            "role": "authenticated", "app_metadata": {"local_auth_fixture": fixture.marker}}


def session_payload(fixture):
    return {"access_token": token({"sub": fixture.identifier}), "refresh_token": SECRET + "-refresh",
            "token_type": "bearer", "user": user(fixture)}


class LocalConfigurationTests(unittest.TestCase):
    def test_only_canonical_ipv4_ipv6_same_port_are_supported(self):
        for value, host in (("http://127.0.0.1:54321", "127.0.0.1"), ("http://[::1]:54321/", "::1")):
            self.assertEqual(auth.local_origin(value), (value.rstrip("/"), host))

    def test_targets_with_normalization_dns_or_unexpected_port_are_rejected(self):
        targets = ["https://project.supabase.co", "http://localhost:54321", "http://127.0.0.1:54322",
                   "http://0.0.0.0:54321", "http://127.0.0.2:54321", "http://2130706433:54321",
                   "http://127.1:54321", "http://[::ffff:127.0.0.1]:54321", "http://%31%32%37.0.0.1:54321",
                   "http://127.0.0.1:054321", "http://user@127.0.0.1:54321", "https://127.0.0.1:54321",
                   "HTTP://127.0.0.1:54321", "http://127.0.0.1:54321/path", "http://127.0.0.1:54321?x=1",
                   "http://127.0.0.1:54321#secret", " http://127.0.0.1:54321", "http://127.0.0.1:54321\n",
                   "http://127.0.0.1:54321//", None, {}, 54321]
        with patch.object(auth.http.client, "HTTPConnection") as connection:
            for target in targets:
                with self.subTest(target=target), self.assertRaises(auth.HarnessFailure):
                    auth.LocalAuth({**configuration(), "API_URL": target})
            connection.assert_not_called()

    def test_required_keys_must_be_header_safe_nonempty_strings(self):
        for name in ("ANON_KEY", "SERVICE_ROLE_KEY", "JWT_SECRET"):
            for value in (None, "", {}, 123, "bad\r\nheader", "bad value", "x" * 8193):
                with self.subTest(name=name, value=type(value)), self.assertRaises(auth.HarnessFailure):
                    auth.configuration({**configuration(), name: value})
        with self.assertRaises(auth.HarnessFailure):
            auth.configuration([])
        with self.assertRaises(auth.HarnessFailure):
            auth.configuration({**configuration(), "ANON_KEY": configuration()["SERVICE_ROLE_KEY"]})

    def test_lowercase_cli_status_keys_are_supported(self):
        result = auth.configuration({k.lower(): v for k, v in configuration().items()})
        self.assertEqual(result[1], "127.0.0.1")

    def test_status_file_requires_owner_only_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            path.write_text(json.dumps(configuration()))
            path.chmod(0o600)
            self.assertEqual(auth.read_status(path), configuration())
            for mode in (0o644, 0o640, 0o606):
                path.chmod(mode)
                with self.assertRaises(auth.HarnessFailure):
                    auth.read_status(path)

    def test_status_file_refuses_symlink_directory_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            path.write_text(" " * (auth.MAX_BODY + 1))
            path.chmod(0o600)
            link = Path(directory) / "link"
            link.symlink_to(path)
            for target in (path, link, Path(directory)):
                with self.subTest(target=target.name), self.assertRaises((OSError, auth.HarnessFailure)):
                    auth.read_status(target)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.stack = auth.LocalAuth(configuration())
        self.factory = patch.object(auth.http.client, "HTTPConnection")
        self.connection = self.factory.start().return_value
        self.addCleanup(self.factory.stop)
        self.response = self.connection.getresponse.return_value
        self.response.status = 200
        self.response.read1.side_effect = [b"{}", b""]

    def test_admin_key_is_only_sent_to_admin_path_and_not_caller_routes(self):
        self.stack.admin("GET", ID)
        headers = self.connection.request.call_args.kwargs["headers"]
        self.assertEqual(headers["Authorization"], "Bearer " + configuration()["SERVICE_ROLE_KEY"])
        self.assertEqual(headers["apikey"], configuration()["SERVICE_ROLE_KEY"])
        self.connection.reset_mock()
        for path in ("/auth/v1/user", "/auth/v1/token?grant_type=password", "/rest/v1/listings"):
            with self.assertRaises(auth.HarnessFailure):
                self.stack.request("GET", path, admin=True)
        with self.assertRaises(auth.HarnessFailure):
            self.stack.rest("GET", "listings", token=configuration()["SERVICE_ROLE_KEY"])
        self.connection.request.assert_not_called()

    def test_real_caller_header_is_distinct_from_public_api_key(self):
        self.stack.rest("PATCH", "profiles", token=token(), identifier=ID, body={"display_name": "Synthetic"})
        args, kwargs = self.connection.request.call_args
        self.assertEqual(args, ("PATCH", "/rest/v1/profiles?id=eq." + ID))
        self.assertEqual(kwargs["headers"]["apikey"], configuration()["ANON_KEY"])
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer " + token())
        self.assertEqual(json.loads(kwargs["body"]), {"display_name": "Synthetic"})
        self.connection.close.assert_called_once()

    def test_request_path_rejects_redirect_path_injection_and_unsupported_routes(self):
        for path in ("https://example.invalid", "//example.invalid", "/auth/v1/../admin/users",
                     "/auth/v1/signup", "/auth/v1/admin/users?filter=fixture", "/auth/v1/invite",
                     "/rest/v1/profiles?id=eq." + ID + "&select=*", "/rest/v1/profiles%3fselect=*"):
            with self.subTest(path=path), self.assertRaises(auth.HarnessFailure):
                self.stack.request("GET", path, token=token())
        self.connection.request.assert_not_called()

    def test_all_redirect_statuses_are_errors_without_following_or_reading_body(self):
        for status in (300, 301, 302, 303, 304, 305, 307, 308):
            self.response.status = status
            with self.assertRaises(auth.HarnessFailure):
                self.stack.request("GET", "/auth/v1/user", token=token())
        self.response.read1.assert_not_called()
        self.assertEqual(self.connection.request.call_count, 8)
        self.assertEqual(self.connection.close.call_count, 8)

    def test_destination_is_revalidated_for_every_call_including_cleanup(self):
        self.stack.origin = "https://example.supabase.co"
        self.stack.start_cleanup()
        with self.assertRaises(auth.HarnessFailure):
            self.stack.admin("GET", ID)
        self.connection.request.assert_not_called()

    def test_no_proxy_environment_is_consulted(self):
        with patch.dict(os.environ, {"HTTP_PROXY": "http://example.invalid", "ALL_PROXY": "http://example.invalid"}):
            self.stack.request("GET", "/auth/v1/user", token=token())
        self.assertEqual(auth.http.client.HTTPConnection.call_args.args, ("127.0.0.1", 54321))
        self.assertEqual(auth.http.client.HTTPConnection.call_args.kwargs["timeout"], 5)

    def test_token_header_injection_and_non_json_numbers_do_not_send(self):
        for value in ("bad\r\nvalue", "", "x" * 8193, 123):
            with self.assertRaises(auth.HarnessFailure):
                self.stack.request("GET", "/auth/v1/user", token=value)
        with self.assertRaises(ValueError):
            self.stack.request("POST", "/auth/v1/token?grant_type=password", body={"bad": float("nan")})
        self.connection.request.assert_not_called()

    def test_response_size_is_bounded(self):
        self.response.read1.side_effect = [b"x" * 4096] * 17
        with self.assertRaises(auth.HarnessFailure):
            self.stack.request("GET", "/auth/v1/user", token=token())
        self.connection.close.assert_called_once()

    def test_request_size_is_bounded(self):
        with self.assertRaises(auth.HarnessFailure):
            self.stack.request("POST", "/auth/v1/token?grant_type=password", body={"value": "x" * auth.MAX_BODY})
        self.connection.request.assert_not_called()

    def test_connection_always_closes_after_network_failure(self):
        self.connection.request.side_effect = TimeoutError(SECRET)
        with self.assertRaises(TimeoutError):
            self.stack.request("GET", "/auth/v1/user", token=token())
        self.connection.close.assert_called_once()

    def test_invalid_json_does_not_echo_the_response(self):
        self.response.read1.side_effect = [SECRET.encode(), b""]
        with self.assertRaises(auth.HarnessFailure) as result:
            self.stack.request("GET", "/auth/v1/user", token=token())
        self.assertNotIn(SECRET, str(result.exception))

    def test_error_json_is_returned_without_logging(self):
        self.response.status = 400
        self.response.read1.side_effect = [json.dumps({"error_code": "invalid_credentials", "message": SECRET}).encode(), b""]
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(output):
            code, payload = self.stack.request("POST", "/auth/v1/token?grant_type=password", body={})
        self.assertEqual(code, 400)
        self.assertEqual(payload["error_code"], "invalid_credentials")
        self.assertEqual(output.getvalue(), "")

    def test_request_count_and_wall_deadlines_fail_closed(self):
        self.stack.remaining = 0
        with self.assertRaises(auth.HarnessFailure):
            self.stack.admin("GET", ID)
        self.stack.remaining = 1
        self.stack.deadline = time.monotonic() - 1
        with self.assertRaises(auth.HarnessFailure):
            self.stack.admin("GET", ID)
        self.connection.request.assert_not_called()
        self.stack.start_cleanup()
        self.assertEqual(self.stack.remaining, 8)
        self.assertGreater(self.stack.deadline, time.monotonic())

    def test_streaming_response_cannot_extend_deadline_indefinitely(self):
        now = time.monotonic()
        with patch.object(auth.time, "monotonic", side_effect=[now, now, now + 11]):
            with self.assertRaises(auth.HarnessFailure):
                self.stack.admin("GET", ID)
        self.response.read1.assert_not_called()
        self.connection.close.assert_called_once()


class TokenAndAssertionTests(unittest.TestCase):
    def test_expired_fixture_preserves_identity_and_session_with_valid_signature(self):
        claims = auth.signed_claims(SECRET, auth.expired_fixture(SECRET, token(), now=1000))
        self.assertEqual(claims["sub"], ID)
        self.assertEqual(claims["session_id"], SESSION)
        self.assertEqual(claims["role"], "authenticated")
        self.assertEqual(claims["exp"], 880)
        self.assertEqual(claims["iat"], -2600)

    def test_expiry_fixture_rejects_forgery_other_algorithms_and_privileged_roles(self):
        for value in ("bad.token", token(secret="wrong-secret"), token(algorithm="ES256"),
                      token({"role": "service_role"}), token({"role": "anon"})):
            with self.assertRaises(auth.HarnessFailure):
                auth.expired_fixture(SECRET, value)

    def test_session_requires_user_binding_session_id_role_and_live_expiry(self):
        fixture = auth.Fixture(identifier=ID)
        base = session_payload(fixture)
        mutations = [{"access_token": token({"sub": SESSION})}, {"user": {"id": SESSION}},
                     {"token_type": "unknown"}, {"refresh_token": ""},
                     {"access_token": token({"session_id": "not-a-uuid"})},
                     {"access_token": token({"exp": int(time.time()) - 1})},
                     {"access_token": token({"exp": True})}]
        for update in mutations:
            with redirect_stdout(io.StringIO()), self.assertRaises(auth.HarnessFailure):
                auth.session(auth.LocalAuth(configuration()), auth.Checks(), (200, {**base, **update}), fixture, "synthetic sign-in")

    def test_positive_session_output_contains_no_credentials_or_identity(self):
        fixture = auth.Fixture(identifier=ID)
        output = io.StringIO()
        with redirect_stdout(output):
            auth.session(auth.LocalAuth(configuration()), auth.Checks(), (200, session_payload(fixture)), fixture, "synthetic sign-in")
        for hidden in (SECRET, ID, fixture.email, fixture.password, fixture.marker):
            self.assertNotIn(hidden, output.getvalue())

    def test_denial_requires_exact_status_error_code_and_no_tokens(self):
        for value in ((200, {"error_code": "bad_jwt"}), (403, {"message": "denied"}),
                      (403, {"error_code": "unrelated"}), (403, {"error_code": "bad_jwt", "access_token": SECRET})):
            with self.assertRaises(auth.HarnessFailure):
                auth.Checks().denied(value, (403,), ("bad_jwt",), "synthetic denial")

    def test_zero_row_or_missing_insert_cannot_pass_single_row_assertion(self):
        for value in (None, [], {}, [{}, {}]):
            with self.assertRaises(auth.HarnessFailure):
                auth.Checks().rows((201, value), None, "synthetic row", status=201)


class FixtureCleanupTests(unittest.TestCase):
    def test_synthetic_fixtures_use_unique_invalid_emails_and_no_secret_repr(self):
        first, second = auth.Fixture(), auth.Fixture()
        self.assertNotEqual(first.identifier, second.identifier)
        self.assertTrue(first.email.endswith("@sudan-birds.invalid"))
        self.assertNotEqual(first.password, second.password)
        self.assertNotIn(first.password, repr(first))

    def test_create_uses_supported_admin_endpoint_with_explicit_id_and_no_mail(self):
        stack, attempted = Mock(), []
        def admin(method, identifier=None, body=None):
            if method == "GET":
                return ABSENT
            self.assertEqual(body["id"], attempted[-1].identifier)
            self.assertTrue(body["email_confirm"])
            self.assertNotIn("role", body)
            return 200, user(attempted[-1])
        stack.admin.side_effect = admin
        with redirect_stdout(io.StringIO()):
            auth.create_fixtures(stack, auth.Checks(), attempted)
        self.assertEqual(len(attempted), 2)
        self.assertEqual(stack.admin.call_count, 4)

    def test_preexisting_uuid_is_never_added_to_cleanup_or_deleted(self):
        stack, attempted = Mock(), []
        stack.admin.return_value = (200, {"id": ID})
        with self.assertRaises(auth.HarnessFailure):
            auth.create_fixtures(stack, auth.Checks(), attempted)
        self.assertEqual(attempted, [])
        self.assertEqual(stack.admin.call_count, 1)

    def test_uncertain_create_records_only_exact_attempted_id_and_verifies_marker(self):
        stack, attempted = Mock(), []
        stack.admin.side_effect = [ABSENT, TimeoutError(SECRET)]
        with redirect_stdout(io.StringIO()), self.assertRaises(TimeoutError):
            auth.create_fixtures(stack, auth.Checks(), attempted)
        self.assertEqual(len(attempted), 1)
        fixture = attempted[0]
        stack.admin.reset_mock(side_effect=True)
        stack.admin.side_effect = [(200, user(fixture)), (200, {}), ABSENT]
        auth.cleanup(stack, attempted)
        self.assertEqual([c.args for c in stack.admin.call_args_list],
                         [("GET", fixture.identifier), ("DELETE", fixture.identifier), ("GET", fixture.identifier)])

    def test_cleanup_does_not_delete_when_user_marker_email_or_id_differs(self):
        fixture = auth.Fixture()
        for update in ({"app_metadata": {}}, {"id": ID}, {"email": "someone@example.invalid"}):
            stack = Mock()
            stack.admin.return_value = (200, {**user(fixture), **update})
            with self.assertRaises(auth.HarnessFailure):
                auth.cleanup(stack, [fixture])
            stack.admin.assert_called_once_with("GET", fixture.identifier)

    def test_cleanup_continues_other_fixture_and_reports_static_failure(self):
        first, second = auth.Fixture(), auth.Fixture()
        stack = Mock()
        stack.admin.side_effect = [TimeoutError(SECRET), (200, user(first)), (200, {}), ABSENT]
        with self.assertRaises(auth.HarnessFailure) as result:
            auth.cleanup(stack, [first, second])
        self.assertNotIn(SECRET, str(result.exception))
        self.assertEqual([c.args for c in stack.admin.call_args_list],
                         [("GET", second.identifier), ("GET", first.identifier),
                          ("DELETE", first.identifier), ("GET", first.identifier)])

    def test_missing_fixture_needs_no_delete_and_bad_404_is_not_success(self):
        stack = Mock()
        stack.admin.return_value = ABSENT
        auth.cleanup(stack, [auth.Fixture()])
        self.assertEqual(stack.admin.call_count, 1)
        stack.admin.return_value = (404, {"message": "proxy missing route"})
        with self.assertRaises(auth.HarnessFailure):
            auth.cleanup(stack, [auth.Fixture()])

    def test_cleanup_verifies_deletion_and_never_retries_failed_or_uncertain_write(self):
        fixture = auth.Fixture()
        for ending in (TimeoutError(SECRET), (500, {"message": SECRET}), (200, {})):
            stack = Mock()
            stack.admin.side_effect = [(200, user(fixture)), ending, (200, user(fixture))]
            with self.assertRaises(auth.HarnessFailure):
                auth.cleanup(stack, [fixture])
            self.assertEqual(sum(c.args[0] == "DELETE" for c in stack.admin.call_args_list), 1)

    def test_run_cleans_partial_setup_when_second_create_fails(self):
        stack = Mock()
        attempted = []
        def create(_stack, _check, fixtures):
            fixtures.extend([auth.Fixture(), auth.Fixture()])
            attempted.extend(fixtures)
            raise RuntimeError(SECRET)
        with patch.object(auth, "create_fixtures", side_effect=create), patch.object(auth, "cleanup") as cleanup:
            with self.assertRaises(RuntimeError):
                auth.run(stack)
        cleanup.assert_called_once_with(stack, attempted)

    def test_run_cleans_after_lifecycle_failure_without_claiming_pass(self):
        output = io.StringIO()
        def create(_stack, _check, fixtures):
            fixtures.extend([auth.Fixture(), auth.Fixture()])
        with patch.object(auth, "create_fixtures", side_effect=create), patch.object(auth, "cleanup") as cleanup:
            with patch.object(auth, "lifecycle_checks", side_effect=auth.HarnessFailure("Synthetic check failed")):
                with redirect_stdout(output), self.assertRaises(auth.HarnessFailure):
                    auth.run(Mock())
        cleanup.assert_called_once()
        self.assertNotIn("PASS", output.getvalue())


class LifecycleOrchestrationTests(unittest.TestCase):
    """A fixed HTTP transcript tests orchestration, not Supabase behavior."""
    def test_real_returned_tokens_are_used_for_rls_and_revocation_is_not_overclaimed(self):
        owner, other = auth.Fixture(identifier=ID), auth.Fixture()
        owner_login = session_payload(owner)
        other_login = session_payload(other)
        fresh = {**owner_login, "refresh_token": "new-synthetic-refresh",
                 "access_token": token({"sub": ID, "iat": int(time.time()) + 1})}
        new_login = {**owner_login, "access_token": token({"session_id": str(auth.uuid.uuid4())})}
        row = {"id": str(auth.uuid.uuid4()), "owner_id": ID, "title": "Local Auth request"}
        stack = Mock(secret=SECRET)
        stack.request.side_effect = [
            (400, {"error_code": "invalid_credentials"}),
            (400, {"error_code": "validation_failed"}),
            (200, owner_login), (200, other_login), (200, user(owner)), (200, user(other)),
            (403, {"error_code": "not_admin"}), (200, fresh),
            (403, {"error_code": "bad_jwt"}), (403, {"error_code": "bad_jwt"}),
            (204, None), (400, {"error_code": "refresh_token_not_found"}),
            (403, {"error_code": "session_not_found"}), (200, other_login), (200, new_login),
        ]
        stack.rest.side_effect = [
            (403, {"code": "42501"}), (201, [user(owner)]), (201, [user(other)]),
            (403, {"code": "42501"}), (200, []), (200, [user(owner)]), (201, [row]),
            (200, []), (200, []), (200, [row]), (200, [row]), (200, []),
            (401, {"code": "PGRST301"}), (401, {"code": "PGRST303"}),
            (200, [user(owner)]), (200, []), (200, [row]), (200, []),
        ]
        checks = auth.Checks()
        output = io.StringIO()
        with redirect_stdout(output):
            auth.lifecycle_checks(stack, checks, owner, other)
        self.assertEqual(stack.request.call_count, 15)
        self.assertEqual(stack.rest.call_count, 18)
        self.assertGreater(checks.passed, 40)
        calls = stack.rest.call_args_list
        self.assertEqual(calls[6].kwargs["token"], owner_login["access_token"])
        self.assertEqual(calls[7].kwargs["token"], other_login["access_token"])
        self.assertEqual(calls[10].kwargs["token"], fresh["access_token"])
        self.assertEqual(calls[14].kwargs["token"], fresh["access_token"])
        self.assertEqual(calls[16].kwargs["token"], new_login["access_token"])
        expired = auth.signed_claims(SECRET, calls[13].kwargs["token"])
        self.assertLess(expired["exp"], time.time())
        self.assertEqual(expired["session_id"], SESSION)
        for hidden in (SECRET, ID, owner.email, owner.password, owner.marker):
            self.assertNotIn(hidden, output.getvalue())


class MainBoundaryTests(unittest.TestCase):
    def test_explicit_local_disposable_opt_in_required_before_file_or_network_access(self):
        for argv in ([], ["status.json"], ["--hosted", "status.json"], ["--local-disposable"]):
            with patch.object(auth, "read_status") as read, patch.object(auth, "run") as run:
                with redirect_stderr(io.StringIO()):
                    self.assertEqual(auth.main(argv), 1)
                read.assert_not_called()
                run.assert_not_called()

    def test_hosted_status_rejected_before_fixture_or_source_evidence_work(self):
        with patch.object(auth, "read_status", return_value={**configuration(), "API_URL": "https://example.supabase.co"}):
            with patch.object(auth, "run") as run, patch.object(auth, "source_evidence") as evidence:
                with redirect_stderr(io.StringIO()):
                    self.assertEqual(auth.main(["--local-disposable", "private-status.json"]), 1)
                run.assert_not_called()
                evidence.assert_not_called()

    def test_arbitrary_errors_never_leak_file_path_secret_response_or_traceback(self):
        for error in (RuntimeError(SECRET), TimeoutError(SECRET), ValueError(SECRET)):
            output = io.StringIO()
            with patch.object(auth, "read_status", side_effect=error):
                with redirect_stdout(output), redirect_stderr(output):
                    self.assertEqual(auth.main(["--local-disposable", SECRET]), 1)
            self.assertNotIn(SECRET, output.getvalue())
            self.assertNotIn("Traceback", output.getvalue())

    def test_approved_project_marker_is_required(self):
        with patch.object(auth.Path, "read_text", return_value='project_id = "another-project"'):
            with patch.object(auth, "read_status") as read, redirect_stderr(io.StringIO()):
                self.assertEqual(auth.main(["--local-disposable", "status.json"]), 1)
            read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
