"""Synthetic-only tests: mock every macOS operation; no real keychain access."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import ios_p12_compatibility_probe as p


class Fake(p.Probe):
    def __init__(self, folder, failure=None, drift=False):
        super().__init__(folder, folder)
        self.calls = []
        self.failure = failure
        self.drift = drift
        self.deleted = False

    def run(self, args, stage, data=None):
        self.calls.append((args, stage, data))
        if stage == 'state':
            return b'changed' if self.deleted and self.drift else b'baseline'
        if stage == 'cleanup':
            self.deleted = True
        if stage == self.failure:
            raise p.Failure('synthetic-private-error')
        if stage == 'import' and self.failure == 'mac':
            raise p.Negative('mac_rejected')
        if stage == 'export' and self.failure == 'unsupported':
            raise p.Negative('unsupported_format')
        if stage == 'fingerprint':
            return b'synthetic-certificate'
        if stage == 'identity':
            return hashlib.sha1(b'synthetic-certificate').hexdigest().upper().encode()
        return b''


class Tests(unittest.TestCase):
    def test_environment_fails_before_host_operations(self):
        valid = {'RUNNER_ENVIRONMENT': 'github-hosted'}
        p.validate_environment(valid, 'darwin')
        for env, platform in [(valid, 'linux'), ({}, 'darwin')]:
            with self.assertRaises(p.Failure):
                p.validate_environment(env, platform)
        for name in ['BIRDS_P12_PASSWORD', 'BIRDS_ASC_P8_BASE64', 'AWS_SECRET_ACCESS_KEY',
                     'GH_TOKEN', 'GITHUB_TOKEN', 'SUPABASE_SERVICE_ROLE_KEY', 'ASC_PRIVATE_KEY']:
            with self.assertRaises(p.Failure):
                p.validate_environment(dict(valid, **{name: 'synthetic'}), 'darwin')
        for name, value in [('RUNNER_DEBUG', '1'), ('ACTIONS_STEP_DEBUG', 'true')]:
            with self.assertRaises(p.Failure):
                p.validate_environment(dict(valid, **{name: value}), 'darwin')

    def test_three_exact_profiles_and_owned_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Fake(folder)
            results, ok = probe.execute()
            self.assertTrue(ok)
            self.assertEqual([r['case'] for r in results], [n for n, _ in p.PROFILES])
            self.assertTrue(all(r['cleanup'] and r['matching_dummy_identity'] for r in results))
            for args, stage, data in probe.calls:
                if stage == 'export':
                    self.assertTrue(data.endswith(b'\n'))
                    self.assertNotIn(data[:-1].decode(), args)
                if args[0] == '/usr/bin/security':
                    self.assertNotIn('-s', args)
                    self.assertNotIn('-A', args)
                    if stage in {'keychain', 'import', 'identity', 'cleanup'}:
                        self.assertTrue(any(str(folder) in a for a in args))
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_negative_result_requires_another_working_format(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Fake(folder, 'mac')
            results, ok = probe.execute()
            self.assertFalse(ok)
            self.assertEqual(len(results), 3)
            self.assertTrue(all(r['import'] == 'mac_rejected' and r['cleanup'] for r in results))
        with tempfile.TemporaryDirectory() as folder:
            probe = Fake(folder, 'unsupported')
            results, ok = probe.execute()
            self.assertFalse(ok)
            self.assertTrue(all(r['export'] == 'unsupported_format' for r in results))
            self.assertFalse(any(stage == 'keychain' for _, stage, _ in probe.calls))

    def test_expected_negative_with_verified_alternative_is_acceptable(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Fake(folder)
            original = probe.run
            def run(args, stage, data=None):
                if stage == 'import' and any('platform_default' in arg for arg in args):
                    raise p.Negative('mac_rejected')
                return original(args, stage, data)
            probe.run = run
            results, ok = probe.execute()
            self.assertTrue(ok)
            self.assertEqual(results[0]['import'], 'mac_rejected')
            self.assertFalse(results[0]['matching_dummy_identity'])
            self.assertTrue(all(r['cleanup'] for r in results))

    def test_success_output_limit_and_unconfirmed_group_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = p.Probe(folder, folder)
            with self.assertRaises(p.Failure):
                probe.run([sys.executable, '-c', 'print("x" * 65537)'], 'read')
            with mock.patch.object(p, 'terminate_process_group', return_value=False):
                with self.assertRaises(p.Failure):
                    probe.run([sys.executable, '-c', 'pass'], 'read')
            self.assertFalse(probe.groups_clean)

    def test_unknown_error_stops_and_cleanup_preserves_ownership(self):
        for failure in ['generate', 'keychain', 'import', 'identity', 'cleanup']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as folder:
                probe = Fake(folder, failure)
                results, ok = probe.execute()
                self.assertFalse(ok)
                self.assertEqual(len(results), 1)
                if failure != 'generate':
                    self.assertTrue(any(stage == 'cleanup' for _, stage, _ in probe.calls))
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_automatic_search_drift_is_not_restored_by_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Fake(folder, drift=True)
            results, ok = probe.execute()
            self.assertFalse(ok)
            self.assertFalse(results[0]['cleanup'])
            self.assertFalse(any('-s' in args for args, _, _ in probe.calls))

    def test_missing_or_wrong_identity_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Fake(folder)
            original = probe.run
            def run(args, stage, data=None):
                return b'0 identities' if stage == 'identity' else original(args, stage, data)
            probe.run = run
            result, ok = probe.case(*p.PROFILES[0])
            self.assertFalse(ok)
            self.assertFalse(result['matching_dummy_identity'])
            self.assertTrue(result['cleanup'])

    def test_fixed_negative_classifier(self):
        self.assertEqual(p.negative_code('import', b'MAC verification failed synthetic-secret'), 'mac_rejected')
        self.assertEqual(p.negative_code('export', b'Unknown PBE algorithm synthetic-path'), 'unsupported_format')
        for raw in [b'unknown', b'\xffMAC verification failed', b'MAC verification failed unsupported algorithm',
                    b'MAC verification failed' + b'x' * p.LIMIT]:
            self.assertIsNone(p.negative_code('import', raw))

    def test_private_child_output_and_timeout(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = p.Probe(folder, folder)
            with mock.patch('sys.stdout', new_callable=io.StringIO) as out, mock.patch('sys.stderr', new_callable=io.StringIO) as err:
                with self.assertRaises(p.Negative):
                    probe.run([sys.executable, '-c', 'import sys; print("secret-out"); print("MAC verification failed secret-err", file=sys.stderr); sys.exit(1)'], 'import')
                self.assertEqual(out.getvalue() + err.getvalue(), '')
            process = mock.Mock(returncode=None, pid=123)
            process.communicate.side_effect = subprocess.TimeoutExpired('synthetic', 30)
            with mock.patch.object(p.subprocess, 'Popen', return_value=process), mock.patch.object(p, 'terminate_process_group', return_value=False) as terminate:
                with self.assertRaises(subprocess.TimeoutExpired):
                    probe.run(['synthetic-not-executed'], 'read')
                process.communicate.assert_called_once_with(None, timeout=30)
                terminate.assert_called_once_with(process)
                self.assertFalse(probe.groups_clean)

    def test_actual_synthetic_openssl_profiles(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = p.Probe(folder, folder)
            # Intercept security only. Generate/read actual dummy P12s locally.
            original = probe.run
            fingerprint = None
            def run(args, stage, data=None):
                nonlocal fingerprint
                if args[0] == '/usr/bin/security':
                    return fingerprint if stage == 'identity' else b'baseline' if stage == 'state' else b''
                value = original(args, stage, data)
                if stage == 'fingerprint':
                    fingerprint = hashlib.sha1(value).hexdigest().upper().encode()
                return value
            probe.run = run
            results, ok = probe.execute()
            self.assertTrue(ok)
            self.assertEqual([r['case'] for r in results], [name for name, _ in p.PROFILES])
            self.assertTrue(any(r['export'] == 'passed' and r['read'] == 'passed' for r in results))
            for result in results:
                self.assertIn(result['export'], {'passed', 'unsupported_format'})
                self.assertIn(result['read'], {'passed', 'unsupported_format', 'not_run'})
                self.assertIn(result['import'], {'passed', 'not_run'})
                self.assertTrue(result['cleanup'])
            # Preserve the observed Linux/OpenSSL baseline separately. macOS is
            # deliberately allowed to reject a known synthetic format.
            if sys.platform == 'linux':
                self.assertTrue(all(r['export'] == 'passed' and r['read'] == 'passed' for r in results))

    def test_unrelated_files_and_keychains_are_never_deleted(self):
        with tempfile.TemporaryDirectory() as folder:
            unrelated = Path(folder) / 'unrelated.keychain-db'
            unrelated.write_bytes(b'preserve-unrelated-keychain')
            sentinel = Path(folder) / 'unrelated.txt'
            sentinel.write_bytes(b'preserve-unrelated-file')
            probe = Fake(folder)
            result, ok = probe.case(*p.PROFILES[0])
            self.assertTrue(ok)
            self.assertTrue(result['cleanup'])
            deletes = [args for args, stage, _ in probe.calls if stage == 'cleanup']
            self.assertEqual(deletes, [['/usr/bin/security', 'delete-keychain',
                str(Path(folder) / 'platform_default' / 'owned.keychain-db')]])
            self.assertEqual(unrelated.read_bytes(), b'preserve-unrelated-keychain')
            self.assertEqual(sentinel.read_bytes(), b'preserve-unrelated-file')
            self.assertEqual(set(Path(folder).iterdir()), {unrelated, sentinel})

    def test_main_rejection_json_has_no_secret(self):
        with mock.patch.dict(p.os.environ, {'BIRDS_P12_PASSWORD': 'synthetic-secret'}, clear=True), mock.patch('sys.stdout', new_callable=io.StringIO) as out:
            self.assertEqual(p.main(), 1)
        result = json.loads(out.getvalue())
        self.assertFalse(result['passed'])
        self.assertEqual(result['cases'], [])
        self.assertNotIn('synthetic-secret', out.getvalue())


if __name__ == '__main__':
    unittest.main()
