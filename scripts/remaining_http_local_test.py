"""Offline, credential-free boundary tests for the isolated HTTP launcher."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

import remaining_http_local as harness
from auth_lifecycle import HarnessFailure, read_status


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.status = {'API_URL': 'http://127.0.0.1:54321', 'ANON_KEY': 'synthetic-public',
                       'SERVICE_ROLE_KEY': 'synthetic-admin', 'JWT_SECRET': 'synthetic-secret'}
        self.config = {'project_id': 'sudan-birds-local', 'api': {}}

    def test_accepts_exact_local_and_minimizes_credentials(self):
        result = harness.validate(self.status, self.config)
        self.assertEqual(set(result), {'API_URL', 'ANON_KEY', 'SERVICE_ROLE_KEY'})

    def test_rejects_host_port_scheme_and_credential_routing(self):
        for url in ['https://example.supabase.co', 'http://localhost:54321',
                    'http://127.0.0.1:80', 'http://127.0.0.1:54321@evil.invalid',
                    'http://127.0.0.1:54321/?target=evil', 'http://[::1]:54321',
                    'https://127.0.0.1:54321', 'http://127.0.0.1:54321.evil.invalid']:
            with self.subTest(url=url), self.assertRaises(HarnessFailure):
                harness.validate({**self.status, 'API_URL': url}, self.config)

    def test_rejects_non_disposable_config(self):
        for config in [{'project_id': 'hosted'},
                       {'project_id': 'sudan-birds-local', 'api': {'port': 443}},
                       {'project_id': 'sudan-birds-local', 'api': {'external_url': 'https://example.invalid'}}]:
            with self.assertRaises(HarnessFailure):
                harness.validate(self.status, config)

    def test_rejects_missing_equal_and_control_credentials(self):
        for key in ['ANON_KEY', 'SERVICE_ROLE_KEY', 'JWT_SECRET']:
            for value in ['', None, 'unsafe\nheader']:
                with self.assertRaises(HarnessFailure):
                    harness.validate({**self.status, key: value}, self.config)
        with self.assertRaises(HarnessFailure):
            harness.validate({**self.status, 'ANON_KEY': self.status['SERVICE_ROLE_KEY']}, self.config)

    def test_status_private_regular_file_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'status.json'
            path.write_text(json.dumps(self.status))
            path.chmod(0o600)
            self.assertEqual(read_status(path), self.status)
            path.chmod(0o644)
            with self.assertRaises(HarnessFailure):
                read_status(path)
            link = Path(directory) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                read_status(link)

    def test_explicit_disposable_mode_required_before_reads(self):
        with patch('sys.argv', ['remaining_http_local.py', 'secret-status-file']), \
                patch.object(harness, 'read_status') as read, \
                contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(harness.main(), 1)
            read.assert_not_called()
            self.assertNotIn('secret-status-file', output.getvalue())

    def test_runtime_failure_relays_only_one_allowlisted_label(self):
        safe = 'FAIL local HTTP phase=contact checks=42 requests=12'
        result = subprocess.CompletedProcess([], 1, 'PRIVATE_RESPONSE',
                                             'SECRET_TOKEN\n' + safe + '\nPRIVATE_ID')
        with contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(harness.relay_result(result), 1)
        self.assertEqual(output.getvalue(), safe + '\n')

    def test_rejects_malicious_or_ambiguous_runtime_labels(self):
        safe = 'FAIL local HTTP phase=contact checks=42 requests=12'
        for unsafe in ['SECRET_TOKEN', safe + ' PRIVATE_ID', safe + '\r',
                       safe.replace('contact', 'private-owner-id'),
                       safe.replace('42', '-1'), safe.replace('42', '100000'),
                       safe.replace('42', '01'), safe.replace('42', '4.2'),
                       safe.replace('42', '４２'), safe + '\n' + safe,
                       '\x1b[31m' + safe]:
            with self.subTest(value=unsafe), contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(harness.relay_result(subprocess.CompletedProcess([], 1, safe, unsafe)), 1)
                self.assertEqual(output.getvalue(),
                                 'FAIL remaining handler harness; sensitive details suppressed\n')

    def test_all_fixed_phases_relay(self):
        for phase in ['setup', 'contact', 'deletion', 'lifecycle_authorization',
                      'lifecycle_batching', 'lifecycle_reconciliation', 'unrelated_fixture', 'shutdown']:
            safe = f'FAIL local HTTP phase={phase} checks=0 requests=99999'
            with contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(harness.relay_result(subprocess.CompletedProcess([], 1, '', safe)), 1)
                self.assertEqual(output.getvalue(), safe + '\n')

    def test_runtime_has_bounded_capabilities_and_owned_deletion(self):
        source = Path(harness.__file__).read_text()
        for flag in ['--cached-only', '--no-remote', '--no-prompt', '--deny-read',
                     '--deny-write', '--deny-run', '--deny-ffi', '--deny-sys',
                     '--allow-net=127.0.0.1:54321,127.0.0.1:54329']:
            self.assertIn(flag, source)
        ts = (harness.ROOT / 'scripts/remaining_http_local.ts').read_text()
        self.assertNotIn('Deno.env', ts)
        self.assertIn('owned.has(match[1])', ts)
        self.assertIn('await server.shutdown()', ts)
        self.assertIn('redirect: "error"', ts)
        self.assertIn('AbortSignal.timeout', ts)


if __name__ == '__main__':
    unittest.main()
