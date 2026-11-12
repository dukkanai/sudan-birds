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
