#!/usr/bin/env python3
"""Synthetic-only temporary P12 rewrap experiment. No real credential inputs.

OpenSSL passwords use stdin, never argv/env/files. security's required -p/-P
arguments contain ONLY fresh dummy passwords, as in the compatibility probe.
Encrypted PEM intermediates use AES256; no plaintext key file/stdout is created.
The 3DES/SHA1 target is an explicit synthetic compatibility experiment, NOT
permission or a recommendation to weaken encryption of real credentials.
One self-signed identity only: this does not prove production chain preservation.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import sys
import tempfile

from ios_p12_compatibility_probe import Failure, Probe, interrupted, validate_environment

OPENSSL = '/usr/bin/openssl'
MODERN = ['-keypbe', 'AES-256-CBC', '-certpbe', 'AES-256-CBC', '-macalg', 'sha256']
COMPAT = ['-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1']


def private_encrypted_pem(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise Failure('encrypted_pem_invalid')
    path.chmod(0o600)
    raw = path.read_bytes()
    # Fail closed on other PEM key encodings, even if a platform might encrypt
    # them. Never print or return the bytes, key attributes or file path.
    keys = re.findall(rb'-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----', raw)
    if keys != [b'ENCRYPTED PRIVATE KEY']:
        raise Failure('encrypted_pem_required')


def lines(*passwords):
    if any(not re.fullmatch(r'[A-Za-z0-9_-]{32,128}', value) for value in passwords):
        raise Failure('dummy_password_framing')
    return b''.join(value.encode('ascii') + b'\n' for value in passwords)


class RepackProbe(Probe):
    def public_material(self, pem, password):
        cert = self.run([OPENSSL, 'x509', '-in', str(pem), '-outform', 'DER'], 'certificate')
        public = self.run([OPENSSL, 'pkey', '-in', str(pem), '-passin', 'stdin',
                           '-pubout', '-outform', 'DER'], 'public_key', lines(password))
        if not cert or not public:
            raise Failure('public_material_missing')
        return cert, public

    def cryptographic_flow(self, folder):
        """Generate every input internally. Return only paths to owned dummy data/public cert."""
        source_password, intermediate_password, target_password = [secrets.token_urlsafe(32) for _ in range(3)]
        key, cert, source, middle, target, verified = [folder / name for name in
            ('generated.key', 'generated.crt', 'source.p12', 'encrypted.pem', 'target.p12', 'verified.pem')]
        self.run([OPENSSL, 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048',
                  '-aes-256-cbc', '-pass', 'stdin', '-out', str(key)], 'generate', lines(source_password))
        private_encrypted_pem(key)
        self.run([OPENSSL, 'req', '-new', '-x509', '-key', str(key), '-passin', 'stdin',
                  '-subj', '/CN=Birds Synthetic Rewrap Only', '-days', '1', '-out', str(cert)],
                 'generate', lines(source_password))
        self.run([OPENSSL, 'pkcs12', '-export', '-in', str(cert), '-inkey', str(key),
                  '-out', str(source), '-passin', 'stdin', '-passout', 'stdin'] + MODERN,
                 'source_export', lines(source_password, source_password))
        source.chmod(0o600)
        original = hashlib.sha256(source.read_bytes()).digest()
        # When passin and passout have the same source, OpenSSL consumes separate
        # successive lines. This exact two-password flow is tested, not guessed.
        self.run([OPENSSL, 'pkcs12', '-in', str(source), '-out', str(middle), '-aes256',
                  '-passin', 'stdin', '-passout', 'stdin'], 'encrypted_extract',
                 lines(source_password, intermediate_password))
        private_encrypted_pem(middle)
        before = self.public_material(middle, intermediate_password)
        original_cert = self.run([OPENSSL, 'x509', '-in', str(cert), '-outform', 'DER'], 'certificate')
        original_public = self.run([OPENSSL, 'pkey', '-in', str(key), '-passin', 'stdin',
                                   '-pubout', '-outform', 'DER'], 'public_key', lines(source_password))
        if before != (original_cert, original_public):
            raise Failure('source_identity_mismatch')
        self.run([OPENSSL, 'pkcs12', '-export', '-in', str(middle), '-inkey', str(middle),
                  '-out', str(target), '-passin', 'stdin', '-passout', 'stdin'] + COMPAT,
                 'target_export', lines(intermediate_password, target_password))
        target.chmod(0o600)
        self.run([OPENSSL, 'pkcs12', '-in', str(target), '-noout', '-passin', 'stdin'],
                 'target_read', lines(target_password))
        self.run([OPENSSL, 'pkcs12', '-in', str(target), '-out', str(verified), '-aes256',
                  '-passin', 'stdin', '-passout', 'stdin'], 'encrypted_verify',
                 lines(target_password, intermediate_password))
        private_encrypted_pem(verified)
        if self.public_material(verified, intermediate_password) != before:
            raise Failure('rewrapped_identity_mismatch')
        if hashlib.sha256(source.read_bytes()).digest() != original:
            raise Failure('source_changed')
        return source, original, target, target_password, original_cert

    def execute(self):
        result = {'case': 'synthetic_aes256_sha256_to_tripledes_sha1',
                  'rewrap': 'not_run', 'certificate_equal': False, 'public_key_equal': False,
                  'source_unchanged': False, 'import': 'not_run',
                  'matching_dummy_identity': False, 'cleanup': False}
        baseline = self.snapshot()
        folder = self.path / 'owned-rewrap'
        folder.mkdir(mode=0o700)
        kc = folder / 'owned.keychain-db'
        owned, ok = False, False
        source, original = None, None
        stage = 'rewrap'
        try:
            source, original, target, password, cert = self.cryptographic_flow(folder)
            result.update(rewrap='passed', certificate_equal=True, public_key_equal=True,
                          source_unchanged=True)
            stage = 'import'
            owned = True
            self.run(['/usr/bin/security', 'create-keychain', '-p', password, str(kc)], 'keychain')
            self.run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(kc)], 'keychain')
            self.run(['/usr/bin/security', 'import', str(target), '-k', str(kc), '-P', password,
                      '-T', '/usr/bin/security'], 'import')
            result['import'] = 'passed'
            identities = self.run(['/usr/bin/security', 'find-identity', '-p', 'basic', str(kc)], 'identity')
            fingerprint = hashlib.sha1(cert).hexdigest().upper().encode('ascii')
            if set(re.findall(rb'\b[A-F0-9]{40}\b', identities)) != {fingerprint}:
                raise Failure('identity_mismatch')
            if hashlib.sha256(source.read_bytes()).digest() != original:
                result['source_unchanged'] = False
                raise Failure('source_changed')
            result['matching_dummy_identity'] = True
            ok = True
        except Exception:
            result[stage] = 'failed_or_unavailable'
        finally:
            # Report final preservation even when import/identity fails before
            # the normal post-import check. Never retain a stale true field.
            if source is not None:
                try:
                    result['source_unchanged'] = (not source.is_symlink() and
                        hashlib.sha256(source.read_bytes()).digest() == original)
                except Exception:
                    result['source_unchanged'] = False
                ok = ok and result['source_unchanged']
            clean = self.groups_clean
            if owned:
                try:
                    self.run(['/usr/bin/security', 'delete-keychain', str(kc)], 'cleanup')
                    clean = clean and not kc.exists() and not kc.is_symlink()
                except Exception:
                    clean = False
            try:
                clean = (self.snapshot() == baseline) and clean
            except Exception:
                clean = False
            try:
                shutil.rmtree(folder)
                clean = clean and not folder.exists()
            except Exception:
                clean = False
            result['cleanup'] = clean and self.groups_clean
        return result, ok and result['cleanup']


def main():
    folder, result, success, clean = None, None, False, False
    try:
        validate_environment(os.environ, sys.platform)
        os.umask(0o077)
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, interrupted)
        folder = tempfile.mkdtemp(prefix='birds-synthetic-rewrap-')
        result, success = RepackProbe(folder, os.environ['HOME']).execute()
    except Exception:
        success = False
    finally:
        if folder:
            try:
                shutil.rmtree(folder)
                clean = not Path(folder).exists()
            except Exception:
                clean = False
        else:
            clean = True
    success = success and clean
    print(json.dumps({'purpose': 'synthetic_rewrap_only', 'result': result, 'passed': success,
                      'workspace_cleanup': clean, 'real_credential_change_authorized': False,
                      'trusted_codesigning_proven': False}, sort_keys=True))
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
