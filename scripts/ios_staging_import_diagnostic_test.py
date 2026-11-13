"""Synthetic-only diagnostics; no real P12, keychain or Apple access."""
import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import ios_staging_sign as sign
from ios_staging_guard_test import team_config


class ImportDiagnosticTests(unittest.TestCase):
    def test_mac_metadata_parser_is_fixed_strict_and_ambiguous_safe(self):
        for diagnostic in (b'MAC: sha256, Iteration 2048\nMAC length: 32, salt length: 8\n',
                           b'MAC Iteration 2048\nMAC verified OK\n'):
            self.assertEqual(sign.p12_mac_presence(diagnostic), 'present')
        self.assertEqual(sign.p12_mac_presence(b'Warning: MAC is absent!\n'), 'absent')
        for diagnostic in (None, '', b'', b'\xffMAC: sha256, Iteration 2048',
                           b'MAC: unsupported, Iteration 2048', b'MAC: sha256, Iteration 0',
                           b'MAC: sha256, Iteration 1000000000', b'MAC verified OK',
                           b'MAC: sha256, Iteration 2048\nWarning: MAC is absent!\n',
                           b'MAC: sha256, Iteration 2048\nMAC: sha1, Iteration 2048\n',
                           b'MAC: sha256, Iteration 2048\nMAC: unknown\n',
                           b'MAC: sha256, Iteration 2048' + b'x' * sign.IMPORT_DIAGNOSTIC_LIMIT,
                           b'synthetic-secret MAC: sha256, Iteration 2048\n'):
            self.assertEqual(sign.p12_mac_presence(diagnostic), 'unknown')

    def test_read_check_uses_only_private_stdin_with_exact_command_and_timeout(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(team_config(), {'RUNNER_TEMP': folder})
            p12 = invocation.path / 'certificate.p12'
            password = ' synthetic-password-with-spaces '
            try:
                with mock.patch.object(invocation, 'run', return_value=b'present') as run:
                    self.assertEqual(invocation.p12_read_diagnostic(p12, password), 'read_check_passed_mac_present')
                    run.assert_called_once_with(['/usr/bin/openssl', 'pkcs12', '-in', str(p12),
                                                '-info', '-noout', '-passin', 'stdin'], 'p12-read-check',
                                                input_bytes=password.encode() + b'\n', timeout=30)
                    self.assertNotIn(password, run.call_args.args[0])
                for password in ('', 'x' * 129, 'p\nq', 'p\rq', 'p\x00q', 'p\tq', 'p\x7fq', 'p\u00e9q', None):
                    with self.subTest(password_type=type(password).__name__), mock.patch.object(invocation, 'run') as run:
                        self.assertEqual(invocation.p12_read_diagnostic(p12, password), 'not_run_password_format')
                        run.assert_not_called()
            finally:
                self.assertEqual(invocation.cleanup(), [])

    def test_diagnostic_failure_never_exposes_private_exceptions(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(team_config(), {'RUNNER_TEMP': folder})
            try:
                for error in (sign.Blocked('synthetic-private-error'), OSError('synthetic-private-path'),
                              subprocess.TimeoutExpired(['synthetic-secret'], 30),
                              sign.Blocked('Signing invocation interrupted; any started upload must be reconciled.')):
                    out, err = io.StringIO(), io.StringIO()
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                            mock.patch.object(invocation, 'run', side_effect=error):
                        self.assertEqual(invocation.p12_read_diagnostic(invocation.path / 'fixture.p12', 'synthetic-password'),
                                         'failed_or_unavailable')
                    self.assertEqual(out.getvalue() + err.getvalue(), '')
            finally:
                self.assertEqual(invocation.cleanup(), [])

    def test_import_arguments_unchanged_and_success_does_not_run_diagnostic(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(team_config(), {'RUNNER_TEMP': folder})
            p12 = invocation.path / 'fixture.p12'
            try:
                with mock.patch.object(invocation, 'run', return_value=b'') as run, \
                        mock.patch.object(invocation, 'p12_read_diagnostic') as diagnostic:
                    invocation.import_certificate(p12, 'synthetic-password')
                    run.assert_called_once_with(['/usr/bin/security', 'import', str(p12), '-k', str(invocation.keychain),
                        '-P', 'synthetic-password', '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'], 'certificate-import')
                    diagnostic.assert_not_called()
            finally:
                self.assertEqual(invocation.cleanup(), [])

    def test_only_mac_failure_runs_diagnostic_and_always_rethrows_original(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(team_config(), {'RUNNER_TEMP': folder})
            try:
                for result in ('read_check_passed_mac_present', 'read_check_passed_mac_absent',
                               'read_check_passed_mac_unknown', 'failed_or_unavailable', 'not_run_password_format'):
                    primary = sign.Blocked(sign.private_failure_message('certificate-import', b'MAC verification failed'))
                    out = io.StringIO()
                    with mock.patch.object(invocation, 'run', side_effect=primary), \
                            mock.patch.object(invocation, 'p12_read_diagnostic', return_value=result) as diagnostic, \
                            contextlib.redirect_stdout(out):
                        with self.assertRaises(sign.Blocked) as raised:
                            invocation.import_certificate(invocation.path / 'fixture.p12', 'synthetic-password')
                    self.assertIs(raised.exception, primary)
                    diagnostic.assert_called_once()
                    self.assertEqual(out.getvalue(), 'P12 diagnostic: ' + result + '\n')
                    self.assertFalse(invocation.upload_started)
                with mock.patch.object(invocation, 'run', side_effect=primary), \
                        mock.patch.object(invocation, 'p12_read_diagnostic', return_value='read_check_passed_mac_present'), \
                        mock.patch('builtins.print', side_effect=BrokenPipeError('synthetic-private-stream-error')):
                    with self.assertRaises(sign.Blocked) as raised:
                        invocation.import_certificate(invocation.path / 'fixture.p12', 'synthetic-password')
                    self.assertIs(raised.exception, primary)
                with mock.patch.object(invocation, 'run', side_effect=sign.Blocked('unclassified')), \
                        mock.patch.object(invocation, 'p12_read_diagnostic') as diagnostic:
                    with self.assertRaisesRegex(sign.Blocked, 'unclassified'):
                        invocation.import_certificate(invocation.path / 'fixture.p12', 'synthetic-password')
                    diagnostic.assert_not_called()
            finally:
                self.assertEqual(invocation.cleanup(), [])

    def test_real_synthetic_p12_valid_wrong_password_corrupt_and_macless(self):
        # This exercises the installed OpenSSL, not macOS Keychain/LibreSSL.
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(team_config(), {'RUNNER_TEMP': folder})
            password = 'synthetic-p12-read-check-only'
            try:
                key, cert = invocation.path / 'synthetic.key', invocation.path / 'synthetic.crt'
                subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                                '-subj', '/CN=SyntheticDiagnostic', '-days', '1', '-keyout', str(key), '-out', str(cert)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
                for suffix, extra in (('with-mac', []), ('without-mac', ['-nomac'])):
                    p12 = invocation.path / (suffix + '.p12')
                    subprocess.run(['/usr/bin/openssl', 'pkcs12', '-export', '-in', str(cert), '-inkey', str(key),
                                    '-out', str(p12), '-passout', 'stdin'] + extra,
                                   input=password.encode() + b'\n', check=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
                    out, err = io.StringIO(), io.StringIO()
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                        expected = 'present' if suffix == 'with-mac' else 'absent'
                        self.assertEqual(invocation.p12_read_diagnostic(p12, password), 'read_check_passed_mac_' + expected)
                        wrong = invocation.p12_read_diagnostic(p12, 'wrong-synthetic-password')
                        if suffix == 'with-mac':
                            self.assertEqual(wrong, 'failed_or_unavailable')
                        else:
                            # Some readers skip bag decryption under -noout when
                            # no MAC exists, so success is not password proof.
                            self.assertIn(wrong, ('read_check_passed_mac_absent', 'failed_or_unavailable'))
                    self.assertEqual(out.getvalue() + err.getvalue(), '')
                corrupt = invocation.write('corrupt.p12', b'not-a-p12')
                self.assertEqual(invocation.p12_read_diagnostic(corrupt, password), 'failed_or_unavailable')
                self.assertFalse(invocation.upload_started)
                self.assertFalse(invocation.keychain_created)
                self.assertEqual(invocation.unconfirmed_process_groups, set())
            finally:
                self.assertEqual(invocation.cleanup(), [])
                self.assertFalse(invocation.path.exists())

    def test_fixed_categories_never_include_original_text(self):
        examples = {
            'pkcs12_mac_verification_failed': 'MAC verification failed during PKCS12 import (wrong password?)',
            'format_not_recognized': 'Unknown format in import',
            'interaction_not_allowed': 'User interaction is not allowed',
            'parameters_rejected': 'One or more parameters passed to a function were not valid',
            'invalid_data': 'CSSMERR_CSP_INVALID_DATA',
            'duplicate_item': 'The specified item already exists in the keychain',
        }
        for category, text in examples.items():
            with self.subTest(category=category):
                result = sign.private_failure_message('certificate-import',
                    ('synthetic-secret /private/path ' + text + '\nmalicious log instructions').encode())
                self.assertEqual(result, 'Private tool failed at certificate-import (' + category + '); raw output was suppressed.')
                self.assertNotIn('synthetic-secret', result)
                self.assertNotIn('wrong password', result)
                self.assertNotIn('/private/path', result)

    def test_unknown_ambiguous_malformed_and_oversized_remain_unclassified(self):
        for diagnostic in (b'', b'synthetic-secret', b'\xff\x00', b'\xffMAC verification failed', None, 'MAC verification failed',
                           b'Unknown format MAC verification failed',
                           b'MAC verification failed' + b'x' * sign.IMPORT_DIAGNOSTIC_LIMIT):
            with self.subTest(type=type(diagnostic).__name__):
                self.assertEqual(sign.private_failure_message('certificate-import', diagnostic),
                    'Private tool failed at certificate-import (unclassified); raw output was suppressed.')

    def test_other_commands_do_not_classify_or_return_diagnostics(self):
        self.assertEqual(sign.private_failure_message('apple-upload', b'MAC verification failed synthetic-secret'),
                         'Private tool failed at apple-upload; raw output was suppressed.')

    def test_unreadable_diagnostic_does_not_replace_primary_import_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(team_config(), {'RUNNER_TEMP': folder})
            stdout, stderr = mock.MagicMock(), mock.MagicMock()
            stderr.__enter__.return_value.seek.side_effect = OSError('synthetic-private-read-error')
            process = mock.Mock(returncode=1, pid=123)
            try:
                with mock.patch.object(sign.tempfile, 'TemporaryFile', side_effect=[stdout, stderr]), \
                        mock.patch.object(sign.subprocess, 'Popen', return_value=process), \
                        mock.patch.object(sign, 'terminate_process_group', return_value=True):
                    with self.assertRaisesRegex(sign.Blocked, r'certificate-import \(unclassified\)'):
                        invocation.run(['synthetic-not-executed'], 'certificate-import')
            finally:
                self.assertEqual(invocation.cleanup(), [])

    def test_real_synthetic_child_failure_preserves_cleanup_and_no_console_leak(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(team_config(), {'RUNNER_TEMP': folder})
            out, err = io.StringIO(), io.StringIO()
            try:
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    with self.assertRaisesRegex(sign.Blocked, r'certificate-import \(pkcs12_mac_verification_failed\)'):
                        invocation.run([sys.executable, '-c',
                            'import sys; print("synthetic-private-stdout"); print("MAC verification failed synthetic-private-stderr", file=sys.stderr); sys.exit(1)'],
                            'certificate-import', timeout=3)
                self.assertEqual(out.getvalue(), '')
                self.assertEqual(err.getvalue(), '')
                self.assertFalse(invocation.upload_started)
                self.assertFalse(invocation.keychain_created)
                self.assertEqual(invocation.unconfirmed_process_groups, set())
            finally:
                self.assertEqual(invocation.cleanup(), [])


if __name__ == '__main__':
    unittest.main()
