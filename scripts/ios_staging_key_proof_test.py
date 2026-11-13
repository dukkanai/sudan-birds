"""Execute the exact guarded inline program, using synthetic keys only."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import types
import unittest
from unittest.mock import Mock, patch
from workflow_permissions import has_no_token_permissions

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / 'docs/examples/signing-key-proof/workflow.yml.example'


def source():
    text = EXAMPLE.read_text()
    body = text.split("          /usr/bin/python3 -I - <<'PYPROOF'\n", 1)[1].split('          PYPROOF\n', 1)[0]
    return '\n'.join(line[10:] for line in body.splitlines()) + '\n'


def module():
    result = types.ModuleType('key_proof_test')
    exec(compile(source(), str(EXAMPLE), 'exec'), result.__dict__)
    return result


class ProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        path = Path(cls.fixture.name)
        cls.password = 'synthetic-password-for-offline-tests-only-123456789'
        (path / 'password').write_text(cls.password)
        subprocess.run(['/usr/bin/openssl', 'genpkey', '-algorithm', 'RSA',
                        '-pkeyopt', 'rsa_keygen_bits:2048', '-aes-256-cbc',
                        '-pass', 'file:' + str(path / 'password'), '-out', str(path / 'key')],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        cls.key = (path / 'key').read_text()
        public = subprocess.run(['/usr/bin/openssl', 'pkey', '-in', str(path / 'key'),
                                 '-passin', 'file:' + str(path / 'password'), '-pubout', '-outform', 'DER'],
                                check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
        cls.digest = hashlib.sha256(public).hexdigest()

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.p = module()
        self.p.EXPECTED_SPKI_SHA256 = self.digest
        self.temp = self.enterContext(tempfile.TemporaryDirectory())
        self.created = []
        original_mkdtemp = tempfile.mkdtemp
        def own_temp(**kwargs):
            path = original_mkdtemp(dir=self.temp, **kwargs)
            self.created.append(Path(path))
            return path
        self.enterContext(patch.object(self.p.tempfile, 'mkdtemp', side_effect=own_temp))
        self.event = {'repository': {'full_name': 'dukkanai/sudan-birds'}, 'pull_request': {
            'number': 1, 'state': 'open', 'head': {'ref': 'build/foundation', 'sha': 'a' * 40,
            'repo': {'full_name': 'dukkanai/sudan-birds', 'fork': False}}, 'base': {'ref': 'main'}}}
        self.path = Path(self.temp) / 'event.json'
        self.path.write_text(json.dumps(self.event))
        self.env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'dukkanai/sudan-birds',
                    'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REF': 'refs/pull/1/merge',
                    'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_ACTOR': 'dukkanai',
                    'GITHUB_TRIGGERING_ACTOR': 'dukkanai', 'RUNNER_ENVIRONMENT': 'github-hosted',
                    'BIRDS_ENABLE_KEY_PROOF': 'true', 'GITHUB_RUN_ID': '123',
                    'BIRDS_KEY_PROOF_RUN_ID': '123', 'BIRDS_KEY_PROOF_HEAD_SHA': 'a' * 40,
                    'BIRDS_KEY_PROOF_WORKFLOW_SHA': 'b' * 40, 'GITHUB_SHA': 'b' * 40,
                    'GITHUB_EVENT_PATH': str(self.path),
                    'BIRDS_DISTRIBUTION_KEY_PEM': self.key, 'BIRDS_P12_PASSWORD': self.password}

    def run_main(self):
        out = io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stdout(out):
            code = self.p.main()
            self.assertNotIn('BIRDS_DISTRIBUTION_KEY_PEM', os.environ)
            self.assertNotIn('BIRDS_P12_PASSWORD', os.environ)
        value = out.getvalue()
        self.assertNotIn(self.password, value)
        self.assertNotIn('PRIVATE KEY', value)
        self.assertEqual(len(value.splitlines()), 1)
        result = json.loads(value)
        self.assertEqual(set(result), {'key_proof', 'stage', 'cleanup'})
        return code, result

    def test_real_encrypted_key_matches_and_owned_files_are_removed(self):
        code, result = self.run_main()
        self.assertEqual(code, 0)
        self.assertEqual(result, {'key_proof': 'passed', 'stage': 'complete', 'cleanup': 'passed'})
        self.assertEqual(len(self.created), 1)
        self.assertFalse(self.created[0].exists())

    def test_unconfigured_placeholder_blocks_before_file_write(self):
        self.p.EXPECTED_SPKI_SHA256 = 'REPLACE_WITH_64_LOWERCASE_HEX_SPKI_SHA256'
        with patch.object(self.p, 'write_private') as write:
            self.assertEqual(self.run_main()[1]['stage'], 'context')
            write.assert_not_called()

    def test_each_context_boundary_blocks(self):
        invalid = {'GITHUB_ACTIONS': 'false', 'GITHUB_REPOSITORY': 'other/repo',
                   'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main',
                   'GITHUB_RUN_ATTEMPT': '2', 'GITHUB_ACTOR': 'attacker',
                   'GITHUB_TRIGGERING_ACTOR': 'dependabot[bot]', 'RUNNER_ENVIRONMENT': 'self-hosted',
                   'BIRDS_ENABLE_KEY_PROOF': 'false', 'GITHUB_RUN_ID': '0123',
                   'BIRDS_KEY_PROOF_RUN_ID': '124', 'BIRDS_KEY_PROOF_HEAD_SHA': 'c' * 40,
                   'BIRDS_KEY_PROOF_WORKFLOW_SHA': 'c' * 40, 'GITHUB_SHA': 'c' * 40}
        for key, value in invalid.items():
            with self.subTest(key=key), patch.dict(self.env, {key: value}):
                self.assertEqual(self.run_main()[1]['stage'], 'context')

    def test_fork_closed_wrong_branch_wrong_pr_and_wrong_repository_block(self):
        replacements = [('number', 2), ('number', True), ('state', 'closed'),
                        ('base', {'ref': 'other'}),
                        ('head', {**self.event['pull_request']['head'], 'repo': {'full_name': 'fork/repo', 'fork': True}})]
        for key, value in replacements:
            with self.subTest(key=key):
                event = json.loads(json.dumps(self.event))
                event['pull_request'][key] = value
                self.path.write_text(json.dumps(event))
                self.assertEqual(self.run_main()[1]['stage'], 'context')

    def test_duplicate_malformed_oversize_and_symlink_events_block(self):
        for value in ['{"pull_request":{},"pull_request":{}}', 'SECRET invalid', 'x' * 2_000_001]:
            self.path.write_text(value)
            self.assertEqual(self.run_main()[1]['stage'], 'context')
        self.path.unlink()
        self.path.symlink_to('/nonexistent')
        self.assertEqual(self.run_main()[1]['stage'], 'context')

    def test_input_bounds_and_unencrypted_key_rejected(self):
        for key, value in [('BIRDS_P12_PASSWORD', ''), ('BIRDS_P12_PASSWORD', 'x' * 129),
                           ('BIRDS_P12_PASSWORD', self.password + '\n'),
                           ('BIRDS_DISTRIBUTION_KEY_PEM', self.key.replace('ENCRYPTED ', '')),
                           ('BIRDS_DISTRIBUTION_KEY_PEM', self.key + self.key),
                           ('BIRDS_DISTRIBUTION_KEY_PEM', 'x' * 16385)]:
            with self.subTest(key=key), patch.dict(self.env, {key: value}):
                self.assertEqual(self.run_main()[1]['stage'], 'input')

    def test_exact_inline_program_runs_in_isolated_python(self):
        program = Path(self.temp) / 'inline.py'
        program.write_text(source().replace(
            "EXPECTED_SPKI_SHA256 = 'dd7b9f6a5d8c3fe69f2bab9c28cffc2dc86bcbf6d7861e8b940be68bdd5a6f87'",
            'EXPECTED_SPKI_SHA256 = ' + repr(self.digest)))
        result = subprocess.run(['/usr/bin/python3', '-I', str(program)], env=self.env,
                                capture_output=True, timeout=40, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b'')
        self.assertEqual(json.loads(result.stdout),
                         {'key_proof': 'passed', 'stage': 'complete', 'cleanup': 'passed'})
        self.assertNotIn(self.password.encode(), result.stdout)

    def test_failed_key_consistency_check_prevents_public_derivation(self):
        process = Mock(pid=12345)
        process.wait.return_value = 1
        with patch.object(self.p.subprocess, 'Popen', return_value=process) as popen, \
                patch.object(self.p, 'stop_owned_group'):
            self.assertFalse(self.p.derive_public(Path(self.temp)))
        self.assertEqual(popen.call_count, 1)
        self.assertEqual(popen.call_args.args[0][-2:], ['-check', '-noout'])

    def test_wrong_password_fails_without_child_output(self):
        self.env['BIRDS_P12_PASSWORD'] = 'wrong-password-but-long-enough-to-pass-input'
        code, result = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(result, {'key_proof': 'failed', 'stage': 'derive', 'cleanup': 'passed'})

    def test_wrong_digest_is_a_failure(self):
        self.p.EXPECTED_SPKI_SHA256 = 'f' * 64
        self.assertEqual(self.run_main(), (1, {'key_proof': 'failed', 'stage': 'match', 'cleanup': 'passed'}))

    def test_child_and_primary_exceptions_never_escape(self):
        for error in [RuntimeError('SECRET'), KeyboardInterrupt('SECRET'), InterruptedError('SECRET')]:
            with self.subTest(error=type(error)), patch.object(self.p, 'derive_public', side_effect=error):
                self.assertEqual(self.run_main(), (1, {'key_proof': 'failed', 'stage': 'derive', 'cleanup': 'passed'}))

    def test_process_cleanup_failure_is_not_hidden_by_file_cleanup(self):
        with patch.object(self.p, 'derive_public', side_effect=self.p.GroupCleanupFailure('SECRET')):
            self.assertEqual(self.run_main(), (1, {'key_proof': 'failed', 'stage': 'derive', 'cleanup': 'failed'}))

    def test_filesystem_cleanup_failure_keeps_primary_stage(self):
        with patch.object(self.p, 'derive_public', side_effect=ValueError('SECRET')), \
                patch.object(self.p.shutil, 'rmtree', side_effect=OSError('SECRET')):
            code, result = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(result, {'key_proof': 'failed', 'stage': 'derive', 'cleanup': 'failed'})

    def test_file_permissions_are_owner_only(self):
        path = Path(self.temp) / 'new'
        self.p.write_private(path, b'synthetic')
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            self.p.write_private(path, b'other')
        self.assertEqual(path.read_bytes(), b'synthetic')

    def test_derivation_command_has_no_secret_arguments_or_environment(self):
        process = Mock(pid=12345)
        process.wait.return_value = 0
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            with patch.object(self.p.subprocess, 'Popen', return_value=process) as popen, \
                    patch.object(self.p, 'stop_owned_group') as stop:
                self.assertTrue(self.p.derive_public(Path(self.temp)))
            args, kw = popen.call_args
            self.assertEqual(args[0][0:2], ['/usr/bin/openssl', 'pkey'])
            self.assertNotIn(self.password, str(args))
            self.assertEqual(kw['env'], {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
            self.assertTrue(kw['start_new_session'])
            self.assertEqual(kw['stdout'], subprocess.DEVNULL)
            self.assertEqual(kw['stderr'], subprocess.DEVNULL)
            self.assertEqual(kw['stdin'], subprocess.DEVNULL)
            self.assertEqual(process.wait.call_count, 2)
            self.assertTrue(all(call.kwargs == {'timeout': 15} for call in process.wait.call_args_list))
            self.assertEqual(stop.call_count, 2)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)

    def test_derive_timeout_still_terminates_owned_group(self):
        process = Mock(pid=12345)
        process.wait.side_effect = subprocess.TimeoutExpired('not printed', 15)
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            with patch.object(self.p.subprocess, 'Popen', return_value=process), \
                    patch.object(self.p, 'stop_owned_group') as stop:
                with self.assertRaises(subprocess.TimeoutExpired):
                    self.p.derive_public(Path(self.temp))
            stop.assert_called_once_with(process)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)

    def test_group_cleanup_kills_descendants_after_leader_has_exited(self):
        process = Mock(pid=12345)
        process.poll.return_value = 0
        # TERM, group still present; then grace deadline and KILL; then absent.
        with patch.object(self.p.os, 'killpg', side_effect=[None, None, None, ProcessLookupError]) as kill, \
                patch.object(self.p.time, 'monotonic', side_effect=[0, 0.1, 1, 2, 2.1]), \
                patch.object(self.p.time, 'sleep'):
            self.p.stop_owned_group(process)
        self.assertEqual(kill.call_args_list[0].args, (12345, signal.SIGTERM))
        self.assertEqual(kill.call_args_list[2].args, (12345, signal.SIGKILL))

    def test_group_cleanup_unconfirmed_is_bounded_failure(self):
        process = Mock(pid=12345)
        with patch.object(self.p.os, 'killpg'), \
                patch.object(self.p.time, 'monotonic', side_effect=[0, 1, 2, 5]):
            with self.assertRaises(RuntimeError):
                self.p.stop_owned_group(process)

    def test_registered_workflow_matches_reviewed_example_except_comments(self):
        active = ROOT / '.github/workflows/signing-key-proof.yml'
        self.assertEqual(active.read_text().splitlines()[2:], EXAMPLE.read_text().splitlines()[2:])
        self.assertIn("vars.BIRDS_ENABLE_KEY_PROOF == 'true'", active.read_text())
        self.assertIn('types: [labeled]', active.read_text())

    def test_zero_permission_policy_cannot_hide_job_overrides(self):
        active = (ROOT / '.github/workflows/signing-key-proof.yml').read_text()
        self.assertTrue(has_no_token_permissions(active))
        self.assertFalse(has_no_token_permissions(active.replace('\n', '\r\n')))
        for extra in ['\n# changed', '\n  \"permissions\": write-all',
                      '\n  task: {permissions: write-all}',
                      '\n  task: {\"\\x70ermissions\": write-all}',
                      '\n  task: {<<: *elevated}']:
            self.assertFalse(has_no_token_permissions(active + extra))
        for text in ['# permissions: {}\n', '  permissions: {}\n',
                     'permissions: read-all\n', 'permissions: write-all\n',
                     'permissions: {}\njobs:\n  task:\n    permissions: write-all\n',
                     'permissions: {}\npermissions: {}\n']:
            with self.subTest(text=text):
                self.assertFalse(has_no_token_permissions(text))

    def test_inert_no_checkout_no_network_no_token_or_artifacts(self):
        text = EXAMPLE.read_text()
        self.assertNotIn('.github/workflows', str(EXAMPLE.relative_to(ROOT)))
        self.assertIn('permissions: {}', text)
        self.assertNotIn('uses:', text)
        self.assertNotIn('actions/checkout', text)
        self.assertNotIn('github.token', text)
        self.assertNotIn('urllib', source())
        self.assertNotIn('requests', source())
        self.assertNotIn('http', source())
        self.assertEqual(text.count('${{ secrets.'), 2)
        self.assertIn("EXPECTED_SPKI_SHA256 = 'dd7b9f6a5d8c3fe69f2bab9c28cffc2dc86bcbf6d7861e8b940be68bdd5a6f87'", text)
        self.assertIn("['-check', '-noout']", text)


if __name__ == '__main__':
    unittest.main()
