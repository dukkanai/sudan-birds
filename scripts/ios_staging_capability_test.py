"""Credential-free regressions for the shared CI/signing help query."""
import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import ios_staging_sign as sign
import ios_toolchain_probe as probe
from ios_staging_guard_test import SHA, team_config


HELP = '--api-key --api-issuer --upload-package --wait'


class CapabilityTransportTests(unittest.TestCase):
    def test_stdout_stderr_and_mixed_help_use_identical_bounded_transport(self):
        original_popen = subprocess.Popen
        for stdout, stderr in ((HELP, ''), ('', HELP), ('--api-key --api-issuer', '--upload-package --wait')):
            with self.subTest(stdout=bool(stdout), stderr=bool(stderr)):
                def launch(command, **kwargs):
                    self.assertEqual(command, probe.COMMANDS[2])
                    self.assertEqual(kwargs['stderr'], subprocess.STDOUT)
                    self.assertEqual(set(kwargs['env']), {'PATH', 'DEVELOPER_DIR', 'LC_ALL'})
                    self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
                    # Only this synthetic child runs; no Apple executable or account is used.
                    return original_popen([sys.executable, '-c',
                        'import sys; print(sys.argv[1]); print(sys.argv[2], file=sys.stderr)', stdout, stderr], **kwargs)
                out, err = io.StringIO(), io.StringIO()
                with mock.patch.object(probe.subprocess, 'Popen', side_effect=launch), \
                        mock.patch.dict(probe.os.environ, {'SECRET': 'synthetic-never-inherited'}), \
                        contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    sign.check_uploader_capability(team_config())
                self.assertEqual(out.getvalue(), '')
                self.assertEqual(err.getvalue(), '')

    def test_transport_failures_are_sanitized_and_chaining_suppressed(self):
        for failure in ('query_timeout', 'query_output_limit', 'query_failed', 'query_cleanup_failed'):
            with self.subTest(failure=failure), mock.patch.object(probe, 'query',
                    side_effect=probe.ProbeFailure('synthetic-private-detail:' + failure)) as query:
                with self.assertRaisesRegex(sign.Blocked, '^Bounded nonsecret uploader capability query failed; no credential fallback.$') as caught:
                    sign.check_uploader_capability(team_config())
                query.assert_called_once_with(probe.COMMANDS[2])
                self.assertNotIn('synthetic-private-detail', str(caught.exception))
                self.assertTrue(caught.exception.__suppress_context__)

    def test_shared_transport_does_not_relax_required_flags(self):
        for missing in HELP.split():
            for text in (HELP.replace(missing, ''), HELP.replace(missing, missing + '-other')):
                with self.subTest(missing=missing), mock.patch.object(probe, 'query', return_value=text):
                    with self.assertRaises(sign.Blocked):
                        sign.check_uploader_capability(team_config())
        with mock.patch.object(probe, 'query', return_value='--apiKey --apiIssuer --upload-package --wait'):
            with self.assertRaises(sign.Blocked):
                sign.check_uploader_capability(team_config())

    def test_query_failure_or_missing_flags_precedes_any_private_write_or_apple_call(self):
        for outcome in (probe.ProbeFailure('synthetic-private-detail'), ''):
            with self.subTest(outcome=type(outcome).__name__), tempfile.TemporaryDirectory() as folder:
                invocation = sign.Invocation(team_config(), {'RUNNER_TEMP': folder})
                invocation.run = mock.Mock(side_effect=[b'Xcode 26.3\nBuild version 17C529\n', b'26.2\n'])
                invocation.write = mock.Mock()
                invocation.upload_verified_ipa = mock.Mock()
                kwargs = {'side_effect': outcome} if isinstance(outcome, Exception) else {'return_value': outcome}
                try:
                    with mock.patch.object(probe, 'query', **kwargs), mock.patch.object(sign, 'apple_get') as apple:
                        with self.assertRaises(sign.Blocked):
                            invocation.execute({name: 'synthetic-unused' for name in sign.SECRET_NAMES}, SHA)
                        apple.assert_not_called()
                    self.assertEqual(invocation.stage, 'uploader-capability')
                    self.assertEqual(invocation.run.call_count, 2)
                    invocation.write.assert_not_called()
                    invocation.upload_verified_ipa.assert_not_called()
                    self.assertFalse(invocation.keychain_created)
                    self.assertIsNone(invocation.profile_path)
                    self.assertFalse(invocation.upload_started)
                    self.assertEqual(invocation.status, 'not_uploaded')
                finally:
                    self.assertEqual(invocation.cleanup(), [])


if __name__ == '__main__':
    unittest.main()
