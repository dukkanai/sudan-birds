"""Explicitly approved transient P12 compatibility conversion; no activation logic.

Caller must enforce source/run approval and original Apple MAC rejection. No
network, keychain, secret-store mutation or plaintext key export occurs here.
The caller's p12-read-check stage returns only its sanitized MAC-presence label.
Use the context only around import, never around archive/upload. Inspect the
fixed invocation.p12_rewrap_cleanup_complete/source_unchanged flags in final
reporting; an existing body exception remains primary if final checks fail.
"""
import base64
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import tempfile

MAX_FILE = 2_000_000
MAX_CERT = 65536
MAX_CERTS = 16
OPENSSL = '/usr/bin/openssl'
CODES = frozenset({'invalid_source', 'password_format', 'invalid_approved_certificate',
    'mac_not_confirmed', 'private_tool_failed', 'process_cleanup_unconfirmed',
    'invalid_private_file', 'malformed_pem', 'key_count', 'certificate_count',
    'duplicate_certificate', 'invalid_certificate', 'approved_leaf_missing',
    'leaf_key_mismatch', 'certificate_set_changed', 'public_key_changed',
    'source_changed', 'temporary_cleanup_failed'})


class RewrapFailure(Exception):
    def __init__(self, code):
        self.code = code if isinstance(code, str) and code in CODES else 'private_tool_failed'
        super().__init__('P12 rewrap blocked: ' + self.code)


def require(value, code):
    if not value:
        raise RewrapFailure(code)


def password_line(value):
    require(isinstance(value, str) and 1 <= len(value) <= 128 and
            all(32 <= ord(c) <= 126 for c in value), 'password_format')
    return value.encode('ascii') + b'\n'


def read_private(path, limit=MAX_FILE):
    """Bounded regular-file read without following symlinks, no error text."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= limit and
                    info.st_mode & 0o077 == 0, 'invalid_private_file')
            data = stream.read(limit + 1)
            require(0 < len(data) <= limit, 'invalid_private_file')
            return data
    except RewrapFailure:
        raise
    except Exception:
        raise RewrapFailure('invalid_private_file') from None


def run(invocation, args, data=None, stage='p12-rewrap'):
    try:
        require(not getattr(invocation, 'unconfirmed_process_groups', ()), 'process_cleanup_unconfirmed')
        result = invocation.run(args, stage, input_bytes=data, timeout=30)
        require(not getattr(invocation, 'unconfirmed_process_groups', ()), 'process_cleanup_unconfirmed')
        require(isinstance(result, bytes) and len(result) <= MAX_FILE, 'private_tool_failed')
        return result
    except RewrapFailure:
        raise
    except Exception:
        raise RewrapFailure('private_tool_failed') from None


def parse_encrypted_bundle(raw):
    """Return only public certificates; encrypted key bytes never leave parser."""
    require(isinstance(raw, bytes) and 0 < len(raw) <= MAX_FILE, 'malformed_pem')
    begins = re.findall(rb'-----BEGIN ([A-Z0-9 _-]+)-----', raw)
    ends = re.findall(rb'-----END ([A-Z0-9 _-]+)-----', raw)
    require(raw.count(b'-----BEGIN ') == len(begins) and raw.count(b'-----END ') == len(ends), 'malformed_pem')
    require(begins == ends and all(label in {b'CERTIFICATE', b'ENCRYPTED PRIVATE KEY'}
                                  for label in begins), 'malformed_pem')
    require(begins.count(b'ENCRYPTED PRIVATE KEY') == 1, 'key_count')
    require(1 <= begins.count(b'CERTIFICATE') <= MAX_CERTS, 'certificate_count')
    pattern = rb'-----BEGIN (CERTIFICATE|ENCRYPTED PRIVATE KEY)-----\r?\n([A-Za-z0-9+/=\r\n]+)-----END \1-----'
    blocks = list(re.finditer(pattern, raw))
    require(len(blocks) == len(begins), 'malformed_pem')
    certs = []
    for block in blocks:
        try:
            data = base64.b64decode(re.sub(rb'[\r\n]', b'', block.group(2)), validate=True)
        except Exception:
            raise RewrapFailure('malformed_pem') from None
        require(bool(data), 'malformed_pem')
        if block.group(1) == b'CERTIFICATE':
            require(len(data) <= MAX_CERT, 'invalid_certificate')
            certs.append(data)
    require(len(set(certs)) == len(certs), 'duplicate_certificate')
    return frozenset(certs)


def cert_public(invocation, der):
    canonical = run(invocation, [OPENSSL, 'x509', '-inform', 'DER', '-outform', 'DER'], der)
    require(canonical == der, 'invalid_certificate')
    pem = run(invocation, [OPENSSL, 'x509', '-inform', 'DER', '-pubkey', '-noout'], der)
    return run(invocation, [OPENSSL, 'pkey', '-pubin', '-outform', 'DER'], pem)


def inspect_bundle(invocation, path, password, approved):
    certs = parse_encrypted_bundle(read_private(path))
    require(approved in certs, 'approved_leaf_missing')
    # Validate every certificate, not only the first PEM block/approved leaf.
    leaf_public = None
    for der in sorted(certs):
        public = cert_public(invocation, der)
        if der == approved:
            leaf_public = public
    key_public = run(invocation, [OPENSSL, 'pkey', '-in', str(path), '-passin', 'stdin',
                                  '-pubout', '-outform', 'DER'], password_line(password))
    require(bool(key_public) and key_public == leaf_public, 'leaf_key_mismatch')
    return certs, key_public


def ensure_owned_file(path):
    # Files are pre-created exclusively at 0600 before tools write into them.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(fd)


def source_digest(source):
    return hashlib.sha256(read_private(source)).digest()


@contextmanager
def temporary_compatible_p12(invocation, source_path, source_password, approved_cert_der):
    """Yield (owned ephemeral P12, fresh password); never replace saved inputs."""
    source_line = password_line(source_password)
    require(isinstance(approved_cert_der, bytes) and 0 < len(approved_cert_der) <= MAX_CERT,
            'invalid_approved_certificate')
    try:
        root = Path(invocation.path)
        source = Path(source_path)
        # Production adapter supplies a direct file in its private workspace.
        require(root.is_dir() and not root.is_symlink() and root.stat().st_mode & 0o077 == 0 and
                source.parent == root and not source.is_symlink(), 'invalid_source')
        original = source_digest(source)
    except RewrapFailure:
        raise
    except Exception:
        raise RewrapFailure('invalid_source') from None
    invocation.p12_rewrap_cleanup_complete = False
    invocation.p12_rewrap_source_unchanged = True
    owned = None
    primary = None
    final_code = None
    yielded = False
    try:
        require(run(invocation, [OPENSSL, 'pkcs12', '-in', str(source), '-info', '-noout',
                                 '-passin', 'stdin'], source_line, stage='p12-read-check') == b'present',
                'mac_not_confirmed')
        owned = Path(tempfile.mkdtemp(prefix='p12-rewrap-', dir=root))
        owned.chmod(0o700)
        middle, target, verified = [owned / n for n in ('encrypted.pem', 'compatible.p12', 'verified.pem')]
        for path in (middle, target, verified):
            ensure_owned_file(path)
        intermediate_password, ephemeral_password = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        run(invocation, [OPENSSL, 'pkcs12', '-in', str(source), '-out', str(middle), '-aes256',
                         '-passin', 'stdin', '-passout', 'stdin'],
            source_line + password_line(intermediate_password))
        before_certs, before_public = inspect_bundle(invocation, middle, intermediate_password, approved_cert_der)
        run(invocation, [OPENSSL, 'pkcs12', '-export', '-in', str(middle), '-inkey', str(middle),
                         '-out', str(target), '-passin', 'stdin', '-passout', 'stdin',
                         '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1'],
            password_line(intermediate_password) + password_line(ephemeral_password))
        read_private(target)
        require(run(invocation, [OPENSSL, 'pkcs12', '-in', str(target), '-info', '-noout',
                                 '-passin', 'stdin'], password_line(ephemeral_password),
                    stage='p12-read-check') == b'present', 'mac_not_confirmed')
        run(invocation, [OPENSSL, 'pkcs12', '-in', str(target), '-out', str(verified), '-aes256',
                         '-passin', 'stdin', '-passout', 'stdin'],
            password_line(ephemeral_password) + password_line(intermediate_password))
        after_certs, after_public = inspect_bundle(invocation, verified, intermediate_password, approved_cert_der)
        require(before_certs == after_certs, 'certificate_set_changed')
        require(before_public == after_public, 'public_key_changed')
        require(source_digest(source) == original, 'source_changed')
        # Remove encrypted intermediates before import; only temporary P12 remains.
        middle.unlink()
        verified.unlink()
        yielded = True
        yield target, ephemeral_password
    except BaseException as error:
        if not yielded and isinstance(error, Exception) and not isinstance(error, RewrapFailure):
            primary = RewrapFailure('private_tool_failed')
            raise primary from None
        primary = error
        raise
    finally:
        try:
            invocation.p12_rewrap_source_unchanged = source_digest(source) == original
        except Exception:
            invocation.p12_rewrap_source_unchanged = False
        if not invocation.p12_rewrap_source_unchanged:
            final_code = 'source_changed'
        if getattr(invocation, 'unconfirmed_process_groups', ()):
            final_code = final_code or 'process_cleanup_unconfirmed'
        try:
            if owned is not None:
                shutil.rmtree(owned)
                require(not os.path.lexists(owned), 'temporary_cleanup_failed')
            invocation.p12_rewrap_cleanup_complete = not bool(getattr(invocation, 'unconfirmed_process_groups', ()))
        except Exception:
            invocation.p12_rewrap_cleanup_complete = False
            final_code = final_code or 'temporary_cleanup_failed'
        if final_code:
            if primary is None:
                raise RewrapFailure(final_code) from None
            # Preserve original body/helper error; expose fixed final-state flags
            # and a fixed note instead of overwriting it with a cleanup error.
            try:
                primary.add_note('P12 rewrap final check: ' + final_code)
            except Exception:
                pass
