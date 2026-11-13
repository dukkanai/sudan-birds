"""Synthetic CA/leaf tests only; no Apple, real keys or network."""
import base64
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import ios_staging_p12_rewrap as r
from ios_staging_sign import Invocation
from ios_staging_guard_test import team_config


class RewrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.inv = Invocation(team_config(), {'RUNNER_TEMP': cls.temporary.name})
        inv = cls.inv
        cls.password = 'synthetic-source-password-with-spaces '
        cls.ca_password = 'synthetic-ca-password'
        def cmd(args, password=None):
            return inv.run(['/usr/bin/openssl'] + args, 'synthetic-fixture',
                           input_bytes=(password + '\n').encode() if password else None, timeout=30)
        cls.cmd = staticmethod(cmd)
        ca_key, ca_cert, leaf_key, csr, leaf_cert = [inv.path / name for name in
            ('ca.key', 'ca.crt', 'leaf.key', 'leaf.csr', 'leaf.crt')]
        for key, password in [(ca_key, cls.ca_password), (leaf_key, cls.password)]:
            inv.write(key.name, b'')
            cmd(['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048',
                 '-aes-256-cbc', '-pass', 'stdin', '-out', str(key)], password)
        cmd(['req', '-new', '-x509', '-key', str(ca_key), '-passin', 'stdin',
             '-subj', '/CN=SyntheticRoot', '-days', '1', '-out', str(ca_cert)], cls.ca_password)
        cmd(['req', '-new', '-key', str(leaf_key), '-passin', 'stdin', '-subj', '/CN=SyntheticLeaf',
             '-out', str(csr)], cls.password)
        cmd(['x509', '-req', '-in', str(csr), '-CA', str(ca_cert), '-CAkey', str(ca_key),
             '-passin', 'stdin', '-set_serial', '2', '-days', '1', '-out', str(leaf_cert)], cls.ca_password)
        cls.approved = cmd(['x509', '-in', str(leaf_cert), '-outform', 'DER'])
        cls.other = cmd(['x509', '-in', str(ca_cert), '-outform', 'DER'])
        cls.leaf_key = leaf_key
        for name, flags in [('source.p12', []), ('nomac.p12', ['-nomac'])]:
            path = inv.write(name, b'')
            inv.run(['/usr/bin/openssl', 'pkcs12', '-export', '-in', str(leaf_cert), '-inkey', str(leaf_key),
                '-certfile', str(ca_cert), '-out', str(path), '-passin', 'stdin', '-passout', 'stdin',
                '-keypbe', 'AES-256-CBC', '-certpbe', 'AES-256-CBC', '-macalg', 'sha256'] + flags,
                'synthetic-fixture', input_bytes=r.password_line(cls.password) * 2, timeout=30)
        cls.source_bytes = (inv.path / 'source.p12').read_bytes()
        cls.nomac_bytes = (inv.path / 'nomac.p12').read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.inv.cleanup()
        cls.temporary.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.invocation = Invocation(team_config(), {'RUNNER_TEMP': self.temp.name})
        self.source = self.invocation.write('source.p12', self.source_bytes)

    def tearDown(self):
        self.invocation.cleanup()
        self.temp.cleanup()

    def context(self, **kwargs):
        return r.temporary_compatible_p12(self.invocation, kwargs.get('source', self.source),
            kwargs.get('password', self.password), kwargs.get('approved', self.approved))

    def test_real_chain_preserved_encrypted_intermediates_removed_before_yield(self):
        output = io.StringIO()
        with mock.patch('sys.stdout', output), mock.patch('sys.stderr', output):
            with self.context() as (target, password):
                self.assertNotEqual(password, self.password)
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(list(target.parent.iterdir()), [target])
                self.assertEqual(self.source.read_bytes(), self.source_bytes)
                pem = self.invocation.run(['/usr/bin/openssl', 'pkcs12', '-in', str(target), '-nokeys',
                    '-passin', 'stdin'], 'synthetic-public-check', input_bytes=r.password_line(password), timeout=30)
                certs = [base64.b64decode(body) for body in
                    __import__('re').findall(rb'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----', pem)]
                self.assertEqual(set(certs), {self.approved, self.other})
            self.assertFalse(target.parent.exists())
        self.assertEqual(output.getvalue(), '')
        self.assertTrue(self.invocation.p12_rewrap_source_unchanged)
        self.assertTrue(self.invocation.p12_rewrap_cleanup_complete)

    def test_macless_unknown_wrong_password_and_wrong_approved_rejected(self):
        for mode in ['nomac', 'unknown', 'password', 'approved', 'corrupt']:
            with self.subTest(mode=mode):
                self.source.write_bytes(self.nomac_bytes if mode == 'nomac' else b'corrupt' if mode == 'corrupt' else self.source_bytes)
                original = self.invocation.run
                def run(args, stage, **kw):
                    return b'unknown' if mode == 'unknown' and stage == 'p12-read-check' else original(args, stage, **kw)
                with mock.patch.object(self.invocation, 'run', side_effect=run):
                    with self.assertRaises(r.RewrapFailure):
                        with self.context(password='wrong-password' if mode == 'password' else self.password,
                                          approved=self.other if mode == 'approved' else self.approved):
                            self.fail('must not yield')
                self.assertEqual(list(self.invocation.path.iterdir()), [self.source])

    def test_failure_codes_and_file_size_fail_closed(self):
        for value in ['synthetic-secret-message', None, {}, ['private-path']]:
            failure = r.RewrapFailure(value)
            self.assertEqual(str(failure), 'P12 rewrap blocked: private_tool_failed')
        self.source.write_bytes(b'x' * (r.MAX_FILE + 1))
        with self.assertRaises(r.RewrapFailure):
            with self.context():
                pass

    def test_source_boundary_and_password_framing(self):
        link = self.invocation.path / 'link'
        link.symlink_to(self.source)
        for source in [link, Path(self.temp.name) / 'outside.p12']:
            with self.assertRaises(r.RewrapFailure):
                with self.context(source=source):
                    pass
        for password in ['', 'x\ny', 'x\ry', 'x\x00y', 'x' * 129, '\u00e9']:
            with self.assertRaises(r.RewrapFailure):
                with self.context(password=password):
                    pass
        link.unlink()
        self.source.chmod(0o644)
        with self.assertRaises(r.RewrapFailure):
            with self.context():
                pass

    def test_nonregular_file_rejected_without_waiting_for_fifo_writer(self):
        fifo = self.invocation.path / 'nonregular'
        os.mkfifo(fifo, 0o600)
        try:
            with self.assertRaises(r.RewrapFailure) as raised:
                r.read_private(fifo)
            self.assertEqual(raised.exception.code, 'invalid_private_file')
        finally:
            fifo.unlink()

    def test_failed_import_plus_source_and_cleanup_failure_keeps_flags(self):
        primary = RuntimeError('synthetic-import-failure')
        original = shutil.rmtree
        with mock.patch.object(r.shutil, 'rmtree', side_effect=OSError('synthetic-cleanup-failure')):
            with self.assertRaises(RuntimeError) as raised:
                with self.context():
                    self.source.write_bytes(b'changed')
                    raise primary
        self.assertIs(raised.exception, primary)
        self.assertFalse(self.invocation.p12_rewrap_cleanup_complete)
        self.assertFalse(self.invocation.p12_rewrap_source_unchanged)
        for path in self.invocation.path.iterdir():
            if path.is_dir():
                original(path)

    def test_timeout_unconfirmed_process_and_no_private_exception_text(self):
        for error in [subprocess.TimeoutExpired(['synthetic-private-command'], 30), OSError('private-path')]:
            with mock.patch.object(self.invocation, 'run', side_effect=error):
                with self.assertRaises(r.RewrapFailure) as raised:
                    with self.context():
                        pass
                self.assertNotIn('private-path', str(raised.exception))
                self.assertEqual(raised.exception.code, 'private_tool_failed')
        self.invocation.unconfirmed_process_groups.add(123)
        with self.assertRaises(r.RewrapFailure) as raised:
            with self.context():
                pass
        self.assertEqual(raised.exception.code, 'process_cleanup_unconfirmed')
        self.assertFalse(self.invocation.p12_rewrap_cleanup_complete)
        self.invocation.unconfirmed_process_groups.clear()

    def test_source_mutation_missing_and_body_failure_preserve_primary(self):
        for mode in ['changed', 'missing', 'body']:
            self.source.write_bytes(self.source_bytes)
            primary = RuntimeError('synthetic-primary')
            with self.assertRaises((r.RewrapFailure, RuntimeError)) as raised:
                with self.context():
                    if mode == 'missing':
                        self.source.unlink()
                    else:
                        self.source.write_bytes(b'changed')
                    if mode == 'body':
                        raise primary
            self.assertFalse(self.invocation.p12_rewrap_source_unchanged)
            self.assertTrue(self.invocation.p12_rewrap_cleanup_complete)
            if mode == 'body':
                self.assertIs(raised.exception, primary)
                self.assertIn('P12 rewrap final check: source_changed', raised.exception.__notes__)
            else:
                self.assertEqual(raised.exception.code, 'source_changed')
            if not self.source.exists():
                self.source = self.invocation.write('source.p12', self.source_bytes)

    def test_cleanup_failure_preserves_primary_and_unrelated_file(self):
        unrelated = self.invocation.write('unrelated', b'keep')
        original = shutil.rmtree
        for body_error in [False, True]:
            primary = RuntimeError('synthetic-primary')
            with mock.patch.object(r.shutil, 'rmtree', side_effect=OSError('private-cleanup-path')):
                with self.assertRaises((r.RewrapFailure, RuntimeError)) as raised:
                    with self.context():
                        if body_error:
                            raise primary
            self.assertFalse(self.invocation.p12_rewrap_cleanup_complete)
            self.assertEqual(unrelated.read_bytes(), b'keep')
            if body_error:
                self.assertIs(raised.exception, primary)
            else:
                self.assertEqual(raised.exception.code, 'temporary_cleanup_failed')
            for path in self.invocation.path.iterdir():
                if path.is_dir():
                    original(path)

    def test_parser_rejects_duplicate_multiple_plaintext_malformed_oversized(self):
        def block(label, data):
            return b'-----' + b'BEGIN ' + label + b'-----\n' + base64.b64encode(data) + b'\n-----' + b'END ' + label + b'-----\n'
        cert = block(b'CERTIFICATE', self.approved)
        key = block(b'ENCRYPTED PRIVATE KEY', b'synthetic-encrypted-placeholder')
        for raw in [cert + key + cert, cert + key + key, cert + block(b'PRIVATE KEY', b'not-secret'),
                    cert + key.replace(b'\n', b'!\n', 1), b'x' * (r.MAX_FILE + 1)]:
            with self.assertRaises(r.RewrapFailure):
                r.parse_encrypted_bundle(raw)

    def test_wrong_key_and_certificate_set_tampering_fail_closed(self):
        original = self.invocation.run
        for mode in ['key', 'chain']:
            def run(args, stage, **kw):
                value = original(args, stage, **kw)
                if mode == 'key' and 'pkey' in args and '-pubout' in args:
                    return b'wrong-public-key'
                return value
            original_inspect = r.inspect_bundle
            def inspect(inv, path, password, approved):
                certs, public = original_inspect(inv, path, password, approved)
                if mode == 'chain' and path.name == 'verified.pem':
                    return frozenset({self.approved}), public
                return certs, public
            with mock.patch.object(self.invocation, 'run', side_effect=run), mock.patch.object(r, 'inspect_bundle', side_effect=inspect):
                with self.assertRaises(r.RewrapFailure) as raised:
                    with self.context():
                        self.fail('must not yield')
                self.assertEqual(raised.exception.code, 'leaf_key_mismatch' if mode == 'key' else 'certificate_set_changed')


if __name__ == '__main__':
    unittest.main()
