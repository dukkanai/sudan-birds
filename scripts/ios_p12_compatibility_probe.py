#!/usr/bin/env python3
"""Synthetic-only hosted-macOS format experiment, never real signing readiness.

create-keychain may automatically add an owned keychain to the search list.
No explicit search/default mutation is used. Delete only owned keychains and
require exact original search/default state after every case. Raw output and
all dummy material remain private. No network or real credential input.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile

# Import defines helpers only: no configuration, credentials or network access.
from ios_staging_sign import terminate_process_group

PROFILES = (
    ('platform_default', ()),
    ('aes256_sha256', ('-keypbe', 'AES-256-CBC', '-certpbe', 'AES-256-CBC', '-macalg', 'sha256')),
    ('tripledes_sha1', ('-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1')),
)
LIMIT = 65536


class Failure(Exception):
    pass


class Negative(Failure):
    def __init__(self, code):
        self.code = code


def validate_environment(env, platform):
    if platform != 'darwin' or env.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise Failure('host_not_allowed')
    for name, value in env.items():
        if value and (name.startswith(('BIRDS_', 'AWS_', 'ASC_')) or
                      name in {'GH_TOKEN', 'GITHUB_TOKEN', 'SUPABASE_SERVICE_ROLE_KEY'}):
            raise Failure('credential_environment_rejected')
    if any(env.get(k) == v for k, v in [('RUNNER_DEBUG', '1'), ('ACTIONS_STEP_DEBUG', 'true'),
                                       ('ACTIONS_RUNNER_DEBUG', 'true')]):
        raise Failure('debug_environment_rejected')


def negative_code(stage, raw):
    if len(raw) > LIMIT:
        return None
    try:
        text = raw.decode('utf-8', errors='strict').lower()
    except UnicodeError:
        return None
    found = set()
    if stage == 'import' and 'mac verification failed' in text:
        found.add('mac_rejected')
    if stage in {'export', 'read', 'import'} and any(p in text for p in
            ('unsupported algorithm', 'unknown pbe algorithm', 'unknown option', 'unknown cipher', 'digital envelope routines::unsupported')):
        found.add('unsupported_format')
    return next(iter(found)) if len(found) == 1 else None


class Probe:
    def __init__(self, folder, home):
        self.path = Path(folder)
        self.env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': home,
                    'TMPDIR': str(self.path), 'LC_ALL': 'C'}
        self.groups_clean = True

    def run(self, args, stage, data=None):
        # Private spool files are not a strict disk-output limit. Reads are bounded;
        # fixed trusted binaries, synthetic inputs and 30s deadline bound exposure.
        with tempfile.TemporaryFile(dir=self.path) as out, tempfile.TemporaryFile(dir=self.path) as err:
            process = subprocess.Popen(args, cwd=self.path, env=self.env,
                stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                stdout=out, stderr=err, start_new_session=True)
            try:
                process.communicate(data, timeout=30)
            finally:
                stopped = terminate_process_group(process)
                self.groups_clean = self.groups_clean and stopped
            if not stopped:
                raise Failure('process_cleanup_unverified')
            out.seek(0)
            raw = out.read(LIMIT + 1)
            err.seek(0)
            diagnostic = err.read(LIMIT + 1)
            if len(raw) > LIMIT or len(diagnostic) > LIMIT:
                raise Failure('output_limit')
            if process.returncode:
                category = negative_code(stage, diagnostic)
                if category:
                    raise Negative(category)
                raise Failure('tool_failed')
            return raw

    def snapshot(self):
        return (self.run(['/usr/bin/security', 'list-keychains', '-d', 'user'], 'state'),
                self.run(['/usr/bin/security', 'default-keychain', '-d', 'user'], 'state'))

    def case(self, name, options):
        result = {'case': name, 'export': 'not_run', 'read': 'not_run',
                  'import': 'not_run', 'matching_dummy_identity': False, 'cleanup': False}
        baseline = self.snapshot()
        folder = self.path / name
        folder.mkdir(mode=0o700)
        key, cert, p12, kc = [folder / n for n in ('dummy.key', 'dummy.crt', 'dummy.p12', 'owned.keychain-db')]
        password = secrets.token_urlsafe(32)
        owned = False
        ok = True
        stage = 'generate'
        try:
            self.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                '-subj', '/CN=Birds Synthetic Compatibility Only', '-days', '1',
                '-keyout', str(key), '-out', str(cert)], stage)
            der = self.run(['/usr/bin/openssl', 'x509', '-in', str(cert), '-outform', 'DER'], 'fingerprint')
            if not der:
                raise Failure('empty_certificate')
            fingerprint = hashlib.sha1(der).hexdigest().upper().encode('ascii')
            stage = 'export'
            self.run(['/usr/bin/openssl', 'pkcs12', '-export', '-in', str(cert), '-inkey', str(key),
                '-out', str(p12), '-passout', 'stdin'] + list(options), stage, password.encode() + b'\n')
            result[stage] = 'passed'
            stage = 'read'
            self.run(['/usr/bin/openssl', 'pkcs12', '-in', str(p12), '-noout', '-passin', 'stdin'], stage,
                     password.encode() + b'\n')
            result[stage] = 'passed'
            stage = 'keychain'
            owned = True  # create can fail after creating: ownership precedes command.
            self.run(['/usr/bin/security', 'create-keychain', '-p', password, str(kc)], stage)
            self.run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(kc)], stage)
            stage = 'import'
            self.run(['/usr/bin/security', 'import', str(p12), '-k', str(kc), '-P', password,
                      '-T', '/usr/bin/security'], stage)
            result[stage] = 'passed'
            stage = 'identity'
            # Without -v: includes self-signed/untrusted matching identities.
            identities = self.run(['/usr/bin/security', 'find-identity', '-p', 'basic', str(kc)], stage)
            fingerprints = set(re.findall(rb'\b[A-F0-9]{40}\b', identities))
            if fingerprints != {fingerprint}:
                raise Failure('identity_mismatch')
            result['matching_dummy_identity'] = True
        except Negative as error:
            if stage not in {'export', 'read', 'import'}:
                ok = False
            else:
                result[stage] = error.code
        except Exception:
            ok = False
            if stage in result:
                result[stage] = 'failed_or_unavailable'
        finally:
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

    def execute(self):
        results = []
        valid = True
        for name, options in PROFILES:
            result, ok = self.case(name, options)
            results.append(result)
            valid = valid and ok
            if not ok:
                break
        return results, valid and any(r['matching_dummy_identity'] for r in results)


def interrupted(*_):
    raise Failure('interrupted')


def main():
    results, success, cleanup = [], False, False
    folder = None
    try:
        validate_environment(os.environ, sys.platform)
        os.umask(0o077)
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, interrupted)
        folder = tempfile.mkdtemp(prefix='birds-synthetic-p12-')
        probe = Probe(folder, os.environ['HOME'])
        results, success = probe.execute()
    except Exception:
        success = False
    finally:
        if folder:
            try:
                shutil.rmtree(folder)
                cleanup = not Path(folder).exists()
            except Exception:
                cleanup = False
        else:
            cleanup = True
    success = success and cleanup
    print(json.dumps({'purpose': 'synthetic_format_compatibility_only', 'cases': results,
                      'passed': success, 'workspace_cleanup': cleanup,
                      'trusted_codesigning_proven': False}, sort_keys=True))
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
