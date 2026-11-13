"""Real synthetic crypto locally; every macOS operation is mocked."""
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import ios_p12_repack_probe as p


class LocalProbe(p.RepackProbe):
    def __init__(self, folder, fault=None):
        super().__init__(folder, folder)
        self.fault, self.calls, self.fingerprint, self.deleted = fault, [], None, False

    def run(self, args, stage, data=None):
        self.calls.append((args, stage, data))
        if stage == 'import' and self.fault == 'missing_then_import_fail':
            (self.path / 'owned-rewrap' / 'source.p12').unlink()
            raise p.Failure('synthetic-private-error')
        if stage == 'import' and self.fault == 'mutate_then_import_fail':
            (self.path / 'owned-rewrap' / 'source.p12').write_bytes(b'changed')
            raise p.Failure('synthetic-private-error')
        if stage == self.fault:
            raise p.Failure('synthetic-private-error')
        if args[0] == '/usr/bin/security':
            if stage == 'state':
                return b'drift' if self.fault == 'drift' and self.deleted else b'baseline'
            if stage == 'cleanup':
                self.deleted = True
            if stage == 'identity':
                if self.fault == 'source_changed':
                    (self.path / 'owned-rewrap' / 'source.p12').write_bytes(b'changed')
                return b'0 identities' if self.fault == 'wrong_identity' else self.fingerprint
            return b''
        value = super().run(args, stage, data)
        if stage == 'certificate':
            self.fingerprint = hashlib.sha1(value).hexdigest().upper().encode()
        return value


class Tests(unittest.TestCase):
    def test_real_crypto_two_password_flow_and_preserved_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = LocalProbe(folder)
            output = io.StringIO()
            with mock.patch('sys.stdout', output), mock.patch('sys.stderr', output):
                result, ok = probe.execute()
            self.assertTrue(ok)
            self.assertTrue(all(result[k] for k in ['certificate_equal', 'public_key_equal',
                'source_unchanged', 'matching_dummy_identity', 'cleanup']))
            self.assertEqual(output.getvalue(), '')
            for args, stage, data in probe.calls:
                if args[0] == p.OPENSSL:
                    self.assertNotIn('-nodes', args)
                    self.assertNotIn('-noenc', args)
                    if stage in {'generate', 'encrypted_extract', 'encrypted_verify', 'source_export', 'target_export'}:
                        self.assertIn('-out', args)
                    if stage in {'encrypted_extract', 'encrypted_verify'}:
                        self.assertIn('-aes256', args)
                    if 'genpkey' in args:
                        self.assertIn('-aes-256-cbc', args)
                    if data:
                        for password in data.decode().splitlines():
                            self.assertNotIn(password, args)
                            self.assertNotIn(password, probe.env.values())
                else:
                    self.assertNotIn('-s', args)
                    self.assertNotIn('-A', args)
            extracts = [data.splitlines() for _, stage, data in probe.calls
                        if stage in {'encrypted_extract', 'encrypted_verify', 'target_export'}]
            self.assertEqual(len(extracts), 3)
            self.assertTrue(all(len(pair) == 2 and pair[0] != pair[1] for pair in extracts))
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_plaintext_and_ambiguous_pem_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'fixture'
            # These deliberately incomplete headers have no key body. Build
            # markers separately so secret scanners cannot join adjacent
            # literals into a fictitious PEM block across Python punctuation.
            def header(kind):
                return b'-' * 5 + b'BEGIN ' + kind + b'-' * 5
            for raw in [header(b'PRIVATE KEY'), header(b'RSA PRIVATE KEY'),
                        header(b'ENCRYPTED PRIVATE KEY') + b'\n' + header(b'PRIVATE KEY'), b'x' * 65537]:
                path.write_bytes(raw)
                with self.assertRaises(p.Failure):
                    p.private_encrypted_pem(path)
            path.write_bytes(header(b'ENCRYPTED PRIVATE KEY'))
            p.private_encrypted_pem(path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_password_framing(self):
        for value in ['', 'x\ny', 'x\x00y', 'é' * 32, 'x' * 129]:
            with self.assertRaises(p.Failure):
                p.lines(value)

    def test_errors_identity_source_and_state_fail_closed(self):
        for fault in ['generate', 'target_export', 'keychain', 'import', 'wrong_identity',
                      'source_changed', 'mutate_then_import_fail', 'missing_then_import_fail', 'cleanup', 'drift']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as folder:
                probe = LocalProbe(folder, fault)
                result, ok = probe.execute()
                self.assertFalse(ok)
                if fault in {'source_changed', 'mutate_then_import_fail', 'missing_then_import_fail'}:
                    self.assertFalse(result['source_unchanged'])
                if fault in {'cleanup', 'drift'}:
                    self.assertFalse(result['cleanup'])
                self.assertEqual(list(Path(folder).iterdir()), [])
                if fault not in {'generate', 'target_export'}:
                    self.assertTrue(any(stage == 'cleanup' for _, stage, _ in probe.calls))

    def test_unrelated_file_and_keychain_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            untouched = Path(folder) / 'unrelated.keychain-db'
            untouched.write_bytes(b'preserve')
            probe = LocalProbe(folder)
            result, ok = probe.execute()
            self.assertTrue(ok)
            self.assertEqual(untouched.read_bytes(), b'preserve')
            self.assertEqual([args for args, stage, _ in probe.calls if stage == 'cleanup'],
                [['/usr/bin/security', 'delete-keychain', str(Path(folder) / 'owned-rewrap' / 'owned.keychain-db')]])

    def test_no_real_environment_or_nonmac_execution(self):
        with mock.patch.dict(os.environ, {'BIRDS_P12_PASSWORD': 'synthetic-secret'}, clear=True), \
                mock.patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(p.main(), 1)
        self.assertFalse(json.loads(output.getvalue())['passed'])
        self.assertNotIn('synthetic-secret', output.getvalue())


if __name__ == '__main__':
    unittest.main()
