import contextlib
import io
import json
import subprocess
import unittest
from unittest.mock import Mock, patch

import ios_toolchain_probe as probe

GOOD = ['Xcode 26.3\nBuild version 17C529\n', '26.2\n',
        '  --api-key <key>\n  --api-issuer <uuid>\n  --api-key-subject <subject>\n  --upload-package <file>\n  --wait\n']


class CapabilityTests(unittest.TestCase):
    def run_probe(self, output=GOOD):
        with patch.object(probe.Path, 'is_dir', return_value=True), \
                patch.object(probe, 'query', side_effect=output) as query:
            result = probe.probe()
        self.assertEqual(query.call_args_list[0].args[0], probe.COMMANDS[0])
        return result

    def test_exact_toolchain_and_capabilities(self):
        result = self.run_probe()
        self.assertEqual(result['status'], 'signing_preparation_capabilities_present')
        self.assertTrue(result['exact_toolchain'])
        self.assertEqual(result['ios_sdk_version'], '26.2')

    def test_missing_toolchain_never_runs_any_query(self):
        with patch.object(probe.Path, 'is_dir', return_value=False), \
                patch.object(probe, 'query') as query:
            result = probe.probe()
        query.assert_not_called()
        self.assertEqual(result['status'], 'signing_preparation_blocked')

    def test_wrong_version_build_or_sdk_blocks(self):
        for output in [
            ['Xcode 26.2\nBuild version 17C529\n', *GOOD[1:]],
            ['Xcode 26.3\nBuild version 17C500\n', *GOOD[1:]],
            [GOOD[0], '26.3', GOOD[2]],
        ]:
            with self.subTest(output=output):
                result = self.run_probe(output)
                self.assertFalse(result['exact_toolchain'])
                self.assertEqual(result['status'], 'signing_preparation_blocked')

    def test_each_missing_capability_blocks(self):
        for field, flag in [('api_key_subject', '--api-key-subject'),
                            ('api_key', '--api-key'), ('api_issuer', '--api-issuer'),
                            ('upload_package', '--upload-package'), ('wait', '--wait')]:
            result = self.run_probe([*GOOD[:2], GOOD[2].replace(flag, flag + '-other')])
            self.assertFalse(result[field])
            self.assertEqual(result['status'], 'signing_preparation_blocked')

    def test_legacy_issuer_spelling_is_not_modern_capability_evidence(self):
        result = self.run_probe([*GOOD[:2], GOOD[2].replace('--api-issuer', '--apiIssuer')])
        self.assertFalse(result['api_issuer'])
        self.assertEqual(result['status'], 'signing_preparation_blocked')

    def test_untrusted_versions_and_exception_text_not_emitted(self):
        result = self.run_probe(['SECRET invalid output', 'SECRET', GOOD[2]])
        self.assertNotIn('SECRET', json.dumps(result))
        self.assertIsNone(result['xcode_version'])
        result = self.run_probe([probe.ProbeFailure('SECRET')])
        self.assertNotIn('SECRET', json.dumps(result))
        self.assertFalse(result['queries_succeeded'])

    def test_exit_status_is_closed(self):
        for status, expected in [('signing_preparation_blocked', 1),
                                 ('signing_preparation_capabilities_present', 0)]:
            with patch.object(probe, 'probe', return_value={'status': status}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(probe.main(), expected)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.child = Mock(pid=123)
        self.child.__enter__ = Mock(return_value=self.child)
        self.child.__exit__ = Mock(return_value=False)
        self.child.wait.return_value = 0
        self.child.poll.return_value = 0
        self.selector = Mock()
        self.selector.__enter__ = Mock(return_value=self.selector)
        self.selector.__exit__ = Mock(return_value=False)
        self.selector.select.return_value = [True]
        self.popen = self.enterContext(patch.object(probe.subprocess, 'Popen', return_value=self.child))
        self.enterContext(patch.object(probe.selectors, 'DefaultSelector', return_value=self.selector))
        self.read = self.enterContext(patch.object(probe.os, 'read', side_effect=[b'help', b'']))
        self.kill = self.enterContext(patch.object(probe.os, 'killpg'))

    def test_fixed_command_minimal_environment_no_credentials(self):
        with patch.dict(probe.os.environ, {'SECRET': 'private', 'HOME': '/secret-home'}):
            self.assertEqual(probe.query(probe.COMMANDS[2]), 'help')
        args, kwargs = self.popen.call_args
        self.assertEqual(args, (('/usr/bin/xcrun', 'altool', '--help'),))
        self.assertNotIn('shell', kwargs)
        self.assertEqual(set(kwargs['env']), {'PATH', 'DEVELOPER_DIR', 'LC_ALL'})
        self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
        self.assertEqual(kwargs['stdout'], subprocess.PIPE)
        self.assertEqual(kwargs['stderr'], subprocess.STDOUT)
        self.assertGreater(self.child.wait.call_args_list[0].kwargs['timeout'], 0)
        self.assertLessEqual(self.child.wait.call_args_list[0].kwargs['timeout'], probe.TIMEOUT)

    def test_signing_upload_and_arbitrary_queries_denied(self):
        for command in [('/usr/bin/xcrun', 'altool', '--upload-package', 'x.ipa'),
                        ('/usr/bin/codesign', '--help'), ('/usr/bin/security', 'list-keychains')]:
            with self.assertRaises(probe.ProbeFailure):
                probe.query(command)
        self.popen.assert_not_called()

    def test_nonzero_exit_safe(self):
        self.child.wait.return_value = 1
        with self.assertRaisesRegex(probe.ProbeFailure, '^query_failed$'):
            probe.query(probe.COMMANDS[0])

    def test_timeout_kills_process_group(self):
        self.selector.select.return_value = []
        self.child.poll.return_value = None
        with self.assertRaisesRegex(probe.ProbeFailure, '^query_timeout$'):
            probe.query(probe.COMMANDS[0])
        self.kill.assert_called_once_with(123, probe.signal.SIGKILL)

    def test_oversized_output_kills_process_group(self):
        self.read.side_effect = [b'x' * (probe.OUTPUT_LIMIT + 1)]
        self.child.poll.return_value = None
        with self.assertRaisesRegex(probe.ProbeFailure, '^query_output_limit$'):
            probe.query(probe.COMMANDS[0])
        self.kill.assert_called_once_with(123, probe.signal.SIGKILL)

    def test_dead_leader_with_live_pipe_still_kills_group(self):
        self.selector.select.return_value = []
        self.child.poll.return_value = 0
        with self.assertRaisesRegex(probe.ProbeFailure, '^query_timeout$'):
            probe.query(probe.COMMANDS[0])
        self.kill.assert_called_once_with(123, probe.signal.SIGKILL)
        self.child.wait.assert_called_once_with(timeout=2)
        self.child.__exit__.assert_not_called()

    def test_cleanup_wait_is_bounded_and_safe(self):
        self.selector.select.return_value = []
        self.child.wait.side_effect = subprocess.TimeoutExpired('SECRET', 2)
        with self.assertRaisesRegex(probe.ProbeFailure, '^query_cleanup_failed$'):
            probe.query(probe.COMMANDS[0])
        self.child.wait.assert_called_once_with(timeout=2)
        self.child.stdout.close.assert_called_once()

    def test_unexpected_dependency_failure_main_is_safe(self):
        output = io.StringIO()
        with patch.object(probe, 'probe', side_effect=RuntimeError('SECRET')), \
                contextlib.redirect_stdout(output):
            self.assertEqual(probe.main(), 1)
        self.assertNotIn('SECRET', output.getvalue())
        self.assertEqual(json.loads(output.getvalue()), probe.empty_result())

    def test_spawn_failure_safe(self):
        self.popen.side_effect = OSError('SECRET')
        with self.assertRaisesRegex(probe.ProbeFailure, '^query_failed$'):
            probe.query(probe.COMMANDS[0])

    def test_invalid_utf8_safe(self):
        self.read.side_effect = [b'\xff', b'']
        with self.assertRaisesRegex(probe.ProbeFailure, '^query_failed$'):
            probe.query(probe.COMMANDS[0])


if __name__ == '__main__':
    unittest.main()
