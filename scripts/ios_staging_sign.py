#!/usr/bin/env python3
"""Unexecuted macOS signing/upload adapter for docs/examples/ios-staging.

Never invoke with real credentials until the documented activation is approved.
No provisioning, automatic signing, external TestFlight groups or store release.
"""
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.parse
import urllib.request
import zipfile

from ios_staging_guard import (Blocked, CONFIG, ROOT, GitHub, NoRedirect, full,
                               live_gate, require, validate_config, validate_uploader)

SECRET_NAMES = ('BIRDS_DISTRIBUTION_P12_BASE64', 'BIRDS_P12_PASSWORD',
                'BIRDS_APP_PROFILE_BASE64', 'BIRDS_ASC_P8_BASE64')
GROUP_TERM_SECONDS = 2.0
GROUP_KILL_SECONDS = 2.0


def terminate_process_group(process):
    """Bound TERM/KILL by group liveness, never by leader exit alone."""
    previous = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)

        def alive():
            process.poll()  # Reap only our leader; surviving descendants retain its process group.
            try:
                os.killpg(process.pid, 0)
                return True
            except ProcessLookupError:
                return False

        for sig, grace in ((signal.SIGTERM, GROUP_TERM_SECONDS), (signal.SIGKILL, GROUP_KILL_SECONDS)):
            if not alive():
                return True
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                return True
            deadline = time.monotonic() + grace
            while alive():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                time.sleep(min(0.05, remaining))
            else:
                return True
        return not alive()
    except Exception:
        # Permission errors, unreaped zombies or inspection errors are not termination proof.
        return False
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def child_environment(source):
    # Do not let xcode/Flutter/package scripts inherit uploader secrets or GitHub tokens.
    return {k: source[k] for k in ('PATH', 'HOME', 'LANG', 'LC_ALL', 'TMPDIR', 'DEVELOPER_DIR',
                                  'CI', 'BOT', 'FLUTTER_SUPPRESS_ANALYTICS', 'FLUTTER_ROOT') if k in source}


def decode_secret(value):
    require(isinstance(value, str) and 1 <= len(value) <= 2000000, 'Signing secret is missing or oversized.')
    try:
        return base64.b64decode(value, validate=True)
    except ValueError:
        raise Blocked('Signing secret is not canonical base64.') from None


def validate_profile(profile, c, now):
    require(profile.get('UUID', '').upper() == c['profile_uuid'].upper()
            and profile.get('TeamIdentifier') == [c['approved_team_id']]
            and profile.get('ApplicationIdentifierPrefix') == [c['approved_team_id']],
            'Provisioning profile identity/team differs.')
    expiration = profile.get('ExpirationDate')
    require(isinstance(expiration, datetime) and expiration.replace(tzinfo=timezone.utc).timestamp() > now + 86400,
            'Provisioning profile is expired or too near expiry.')
    require('ProvisionedDevices' not in profile and profile.get('ProvisionsAllDevices') is not True,
            'App Store distribution profile is required; development/ad-hoc/enterprise is rejected.')
    entitlements = profile.get('Entitlements', {})
    require(entitlements.get('application-identifier') == c['approved_team_id'] + '.' + c['bundle_id']
            and entitlements.get('com.apple.developer.team-identifier') == c['approved_team_id']
            and entitlements.get('get-task-allow') is False, 'Profile app entitlement is not an exact distribution match.')
    fingerprints = [hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])]
    require(c['certificate_sha1'] in fingerprints, 'Profile does not include the approved signing certificate.')


def validate_app(app, c):
    require(isinstance(app, dict) and app.get('type') == 'apps' and app.get('id') == c['asc_app_id']
            and app.get('attributes', {}).get('bundleId') == c['bundle_id'],
            'Apple target app identity differs from the approved app.')


def validate_apps(body, c):
    validate_uploader(c)
    if c['uploader_kind'] == 'team':
        # An exact resource read verifies the destination, NOT the key's authority.
        validate_app(body.get('data'), c)
    else:
        apps = body.get('data', [])
        require(isinstance(apps, list) and len(apps) == 1 and body.get('links', {}).get('next') in {None, ''},
                'Uploader can see more than one app, or complete app access could not be verified.')
        validate_app(apps[0], c)


def apps_path(c):
    validate_uploader(c)
    return '/v1/apps/' + c['asc_app_id'] if c['uploader_kind'] == 'team' else '/v1/apps?limit=200'


def uploader_auth(c):
    validate_uploader(c)
    auth = ['--api-key', c['uploader_key_id']]
    if c['uploader_kind'] == 'team':
        return auth + ['--api-issuer', c['uploader_issuer_id']]
    return auth + ['--api-key-subject', 'user']


def validate_uploader_help(help_text, c):
    options = uploader_auth(c)[::2] + ['--upload-package', '--wait']
    require(all(re.search(r'(?<![\w-])' + re.escape(flag) + r'(?![\w-])', help_text) for flag in options),
            'Installed altool lacks the exact reviewed upload/authentication flags; no credential fallback.')



def der_to_jose(der):
    # OpenSSL produces ASN.1 ECDSA; JOSE requires fixed-width r || s.
    require(len(der) >= 8 and der[0] == 0x30 and der[1] == len(der) - 2, 'ECDSA signature encoding rejected.')
    pos, result = 2, b''
    order = int('ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551', 16)
    for _ in range(2):
        require(pos + 2 <= len(der) and der[pos] == 2, 'ECDSA component rejected.')
        size = der[pos + 1]
        value = der[pos + 2:pos + 2 + size]
        require(1 <= size <= 33 and len(value) == size and value[0] < 128
                and not (size > 1 and value[0] == 0 and value[1] < 128), 'ECDSA integer rejected.')
        integer = int.from_bytes(value, 'big')
        require(0 < integer < order, 'ECDSA component is outside P-256.')
        result += integer.to_bytes(32, 'big')
        pos += size + 2
    require(pos == len(der), 'Trailing ECDSA bytes rejected.')
    return result


def base64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode('ascii')


def make_uploader_jwt(c, key_path, run, now):
    validate_uploader(c)
    pub = run(['/usr/bin/openssl', 'pkey', '-in', str(key_path), '-pubout', '-outform', 'DER'], 'uploader-key')
    prefix = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d03010703420004')
    require(len(pub) == 91 and pub.startswith(prefix), 'Uploader key must be an EC P-256 key.')
    header = {'alg': 'ES256', 'kid': c['uploader_key_id'], 'typ': 'JWT'}
    payload = {'iat': int(now), 'exp': int(now) + 120, 'aud': 'appstoreconnect-v1'}
    if c['uploader_kind'] == 'team':
        payload['iss'] = c['uploader_issuer_id']
    else:
        payload['sub'] = 'user'
    parts = [base64url(json.dumps(v, separators=(',', ':')).encode()) for v in (header, payload)]
    unsigned = '.'.join(parts).encode('ascii')
    sig = run(['/usr/bin/openssl', 'dgst', '-sha256', '-sign', str(key_path)], 'uploader-jwt', input_bytes=unsigned)
    return unsigned.decode() + '.' + base64url(der_to_jose(sig))


def apple_get(path, token):
    require(path.startswith('/v1/') and not path.startswith('//'), 'Apple endpoint rejected.')
    req = urllib.request.Request('https://api.appstoreconnect.apple.com' + path,
                                 headers={'Authorization': 'Bearer ' + token})
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=30) as response:
            raw = response.read(2000001)
        require(len(raw) <= 2000000, 'Apple response exceeds safe limit.')
        return json.loads(raw)
    except (OSError, ValueError):
        raise Blocked('Apple read-only verification failed; response was not logged.') from None


def validate_archive_info(info, c):
    require(info.get('CFBundleIdentifier') == c['bundle_id']
            and info.get('CFBundleVersion') == c['build_number']
            and info.get('CFBundleShortVersionString') == c['build_version'], 'Built app identity/version differs.')
    require(info.get('DTXcodeBuild') == c['xcode_build']
            and info.get('DTSDKName') == 'iphoneos' + c['ios_sdk'], 'Built app toolchain differs.')



def validate_signed_entitlements(entitlements, c):
    app_id = c['approved_team_id'] + '.' + c['bundle_id']
    require(entitlements.get('application-identifier') == app_id
            and entitlements.get('com.apple.developer.team-identifier') == c['approved_team_id']
            and entitlements.get('get-task-allow') is False
            and entitlements.get('keychain-access-groups') == [app_id],
            'Exported signature entitlements differ from the reviewed application.')
    allowed = {'application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow',
               'keychain-access-groups', 'beta-reports-active'}
    require(set(entitlements) <= allowed, 'Exported app has an unreviewed capability.')
    if 'beta-reports-active' in entitlements:
        require(entitlements['beta-reports-active'] is True, 'Invalid beta reporting entitlement.')


def validate_zip_members(members):
    names = [member.filename for member in members]
    require(len(set(names)) == len(names) and len(names) <= 50000, 'IPA paths are duplicated or excessive.')
    require(all(type(member.file_size) is int and member.file_size >= 0 for member in members)
            and sum(member.file_size for member in members) <= 2 * 1024**3,
            'IPA expansion exceeds safe bound.')
    # Include implicit directory prefixes: Foo/a and foo/b can collide on macOS
    # even though the two complete filenames differ. Conservative NFC/casefold
    # equivalence rejects aliases without depending on the host filesystem.
    nodes = {}
    for member in members:
        name = member.filename
        directory = name.endswith('/')
        parts = tuple((name[:-1] if directory else name).split('/'))
        mode = member.external_attr >> 16
        require(len(name) <= 4096 and len(parts) <= 128, 'IPA path complexity exceeds safe limit.')
        require(name == member.orig_filename and '\x00' not in name and '\\' not in name
                and all(part not in {'', '.', '..'} for part in parts),
                'Noncanonical or truncated IPA path rejected.')
        kind = stat.S_IFMT(mode)
        require(not stat.S_ISLNK(mode)
                and (kind == 0 or (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode))),
                'Unsafe or unsupported IPA archive entry.')
        normalized = tuple(unicodedata.normalize('NFC', unicodedata.normalize('NFC', part).casefold())
                           for part in parts)
        for depth in range(1, len(parts) + 1):
            prefix = normalized[:depth]
            node = (parts[:depth], 'directory' if depth < len(parts) or directory else 'file')
            require(prefix not in nodes or nodes[prefix] == node,
                    'IPA paths collide after filesystem normalization.')
            require(prefix in nodes or len(nodes) < 200000, 'IPA path index exceeds safe limit.')
            nodes[prefix] = node


def extract_verified_ipa(ipa, destination, c):
    # Destination is an absent child of this invocation's mode-0700 workspace.
    require(not destination.exists() and not destination.is_symlink(),
            'IPA extraction destination already exists.')
    with zipfile.ZipFile(ipa) as package:
        members = package.infolist()
        validate_zip_members(members)
        names = [m.filename for m in members if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', m.filename)]
        require(len(names) == 1, 'IPA app manifest is ambiguous.')
        manifest = package.getinfo(names[0])
        require(0 < manifest.file_size <= 1024 * 1024, 'IPA app manifest exceeds safe limit.')
        original = package.read(manifest)
        validate_archive_info(plistlib.loads(original), c)
        destination.mkdir(mode=0o700)
        package.extractall(destination)
        # zipfile does not retain executable bits; restore only safe mode bits.
        for member in members:
            if not member.is_dir():
                mode = (member.external_attr >> 16) & 0o777
                (destination / member.filename).chmod(mode or 0o600)
    extracted = destination / names[0]
    require(not extracted.is_symlink() and extracted.is_file()
            and 0 < extracted.stat().st_size <= 1024 * 1024,
            'Extracted app manifest is unsafe or oversized.')
    actual = extracted.read_bytes()
    require(actual == original, 'Extracted app manifest differs from the checked archive entry.')
    validate_archive_info(plistlib.loads(actual), c)
    return extracted.parent


def summarize(sha, digest, status):
    require(full(sha, r'[a-f0-9]{40}') and (digest is None or full(digest, r'[a-f0-9]{64}')),
            'Unsafe summary data rejected.')
    require(status in {'not_uploaded', 'upload_outcome_uncertain', 'upload_accepted_processing_unverified',
                       'apple_processed_valid'}, 'Unexpected summary status.')
    return {'source_sha': sha, 'ipa_sha256': digest, 'upload_status': status,
            'internal_tester_delivery': 'not_verified', 'production_release': False}


class Invocation:
    def __init__(self, c, env):
        self.c = c
        self.env = child_environment(env)
        self.path = Path(tempfile.mkdtemp(prefix='birds-sign-', dir=env['RUNNER_TEMP']))
        os.chmod(self.path, 0o700)
        self.keychain = self.path / 'signing.keychain-db'
        self.profile_path = None
        self.original_keychains = None
        self.search_changed = False
        self.keychain_created = False
        self.upload_started = False
        self.status = 'not_uploaded'
        self.digest = None
        self.stage = 'preflight'
        self.unconfirmed_process_groups = set()

    def run(self, command, stage, input_bytes=None, timeout=1200):
        self.stage = stage
        # Raw stdout/stderr may contain signing metadata or tokens, never stream to CI logs.
        with tempfile.TemporaryFile(dir=self.path) as stdout, tempfile.TemporaryFile(dir=self.path) as stderr:
            process = subprocess.Popen(command, cwd=ROOT, env=self.env, stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                process.communicate(input_bytes, timeout=timeout)
            except BaseException:
                if not terminate_process_group(process):
                    self.unconfirmed_process_groups.add(process.pid)
                raise  # Preserve the timeout/interruption as the primary failure.
            # A leader can exit (including nonzero) while descendants continue using private files.
            # Stop any remaining group even on success, before reading results or advancing stages.
            stopped = terminate_process_group(process)
            if not stopped:
                self.unconfirmed_process_groups.add(process.pid)
            require(process.returncode == 0, 'Private tool failed at ' + stage + '; raw output was suppressed.')
            require(stopped, 'Private process-group termination could not be verified at ' + stage + '.')
            stdout.seek(0)
            data = stdout.read(4000001)
            require(len(data) <= 4000000, 'Private tool output exceeds safe limit at ' + stage + '.')
            return data

    def write(self, name, data):
        path = self.path / name
        with path.open('xb') as file:
            file.write(data)
        path.chmod(0o600)
        return path

    def cleanup(self):
        failures = ['private-process-group-unconfirmed'] if self.unconfirmed_process_groups else []
        if self.search_changed:
            try:
                self.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s'] + self.original_keychains, 'cleanup-search', timeout=30)
            except Exception:
                failures.append('keychain-search')
        if self.keychain_created:
            try:
                self.run(['/usr/bin/security', 'delete-keychain', str(self.keychain)], 'cleanup-keychain', timeout=30)
            except Exception:
                failures.append('temporary-keychain')
        if self.profile_path is not None:
            try:
                self.profile_path.unlink(missing_ok=True)
            except OSError:
                failures.append('temporary-profile')
        try:
            shutil.rmtree(self.path)
        except OSError:
            failures.append('private-workspace')
        return failures

    def execute(self, private, sha):
        c = self.c
        xcode = self.run(['/usr/bin/xcodebuild', '-version'], 'toolchain').decode().strip()
        require(xcode == 'Xcode ' + c['xcode_version'] + '\nBuild version ' + c['xcode_build'], 'Exact Xcode build unavailable.')
        require(self.run(['/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], 'sdk').decode().strip() == c['ios_sdk'],
                'Exact iOS SDK unavailable.')
        help_text = self.run(['/usr/bin/xcrun', 'altool', '--help'], 'uploader-capability').decode()
        validate_uploader_help(help_text, c)
        # Secrets live only in this private temp directory; no source or cache destinations.
        p12 = self.write('certificate.p12', decode_secret(private['BIRDS_DISTRIBUTION_P12_BASE64']))
        profile_file = self.write('profile.mobileprovision', decode_secret(private['BIRDS_APP_PROFILE_BASE64']))
        profile = plistlib.loads(self.run(['/usr/bin/security', 'cms', '-D', '-i', str(profile_file)], 'profile-decode'))
        validate_profile(profile, c, time.time())
        password = secrets.token_urlsafe(32)
        self.original_keychains = shlex.split(self.run(['/usr/bin/security', 'list-keychains', '-d', 'user'], 'keychain-state').decode())
        # Set cleanup ownership before invoking creation because a command can fail after making changes.
        self.keychain_created = True
        self.run(['/usr/bin/security', 'create-keychain', '-p', password, str(self.keychain)], 'keychain-create')
        self.run(['/usr/bin/security', 'set-keychain-settings', '-lut', '3600', str(self.keychain)], 'keychain-settings')
        self.run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(self.keychain)], 'keychain-unlock')
        self.run(['/usr/bin/security', 'import', str(p12), '-k', str(self.keychain), '-P', private['BIRDS_P12_PASSWORD'],
                  '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'], 'certificate-import')
        self.run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password,
                  str(self.keychain)], 'key-partitions')
        identity = self.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', str(self.keychain)], 'certificate-identity').decode()
        require(len(re.findall(r'\b[A-F0-9]{40}\b', identity)) == 1 and c['certificate_sha1'] in identity,
                'Private key/valid signing identity does not match the one approved certificate.')
        self.search_changed = True
        self.run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', str(self.keychain)] + self.original_keychains, 'keychain-search')
        profile_dir = Path(self.env['HOME']) / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
        profile_dir.mkdir(parents=True, exist_ok=True)
        profile_path = profile_dir / (c['profile_uuid'] + '.mobileprovision')
        # Do not replace an existing profile, including a symlink, or later remove someone else's file.
        with profile_path.open('xb') as f:
            self.profile_path = profile_path
            f.write(profile_file.read_bytes())
        profile_path.chmod(0o600)
        p12.unlink()
        archive = self.path / 'SudanBirds.xcarchive'
        self.run(['/usr/bin/xcodebuild', '-workspace', str(ROOT / 'app/ios/Runner.xcworkspace'),
                  '-scheme', 'Runner', '-configuration', 'Release', '-destination', 'generic/platform=iOS',
                  '-archivePath', str(archive), '-derivedDataPath', str(self.path / 'DerivedData'),
                  'DEVELOPMENT_TEAM=' + c['approved_team_id'], 'CODE_SIGN_STYLE=Manual',
                  'CODE_SIGN_IDENTITY=' + c['certificate_sha1'], 'PROVISIONING_PROFILE_SPECIFIER=' + c['profile_uuid'],
                  'OTHER_CODE_SIGN_FLAGS=--keychain ' + str(self.keychain), 'archive'], 'archive', timeout=2100)
        app = archive / 'Products/Applications/Runner.app'
        validate_archive_info(plistlib.loads((app / 'Info.plist').read_bytes()), c)
        export = {'method': 'app-store-connect', 'destination': 'export', 'signingStyle': 'manual',
                  'teamID': c['approved_team_id'], 'signingCertificate': c['certificate_sha1'],
                  'provisioningProfiles': {c['bundle_id']: c['profile_uuid']},
                  'manageAppVersionAndBuildNumber': False, 'uploadSymbols': False,
                  'testFlightInternalTestingOnly': True}
        options = self.write('ExportOptions.plist', plistlib.dumps(export))
        export_dir = self.path / 'export'
        self.run(['/usr/bin/xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(export_dir),
                  '-exportOptionsPlist', str(options)], 'export', timeout=900)
        ipas = list(export_dir.glob('*.ipa'))
        require(len(ipas) == 1, 'Expected exactly one exported IPA.')
        ipa = ipas[0]
        verified_dir = self.path / 'verify-export'
        exported_app = extract_verified_ipa(ipa, verified_dir, c)
        self.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(exported_app)], 'verify-export-signature')
        signed_entitlements = plistlib.loads(self.run(['/usr/bin/codesign', '-d', '--entitlements', ':-',
                                                      str(exported_app)], 'verify-export-entitlements'))
        validate_signed_entitlements(signed_entitlements, c)
        embedded = plistlib.loads(self.run(['/usr/bin/security', 'cms', '-D', '-i',
                                          str(exported_app / 'embedded.mobileprovision')], 'verify-export-profile'))
        validate_profile(embedded, c, time.time())
        cert_prefix = self.path / 'export-cert-'
        self.run(['/usr/bin/codesign', '-d', '--extract-certificates', str(cert_prefix), str(exported_app)],
                 'verify-export-certificate')
        require(hashlib.sha1(Path(str(cert_prefix) + '0').read_bytes()).hexdigest().upper() == c['certificate_sha1'],
                'Exported app was signed by a different certificate.')
        with ipa.open('rb') as file:
            self.digest = hashlib.file_digest(file, 'sha256').hexdigest()
        self.upload_verified_ipa(private, ipa)

    def upload_verified_ipa(self, private, ipa):
        # Called only after exported identity/version/signature/profile checks.
        c = self.c
        # Uploader key is materialized only after all project build commands finish.
        key = self.write('ApiKey_' + c['uploader_key_id'] + '.p8', decode_secret(private['BIRDS_ASC_P8_BASE64']))
        token = make_uploader_jwt(c, key, self.run, time.time())
        validate_apps(apple_get(apps_path(c), token), c)
        query = urllib.parse.urlencode({'filter[app]': c['asc_app_id'], 'filter[version]': c['build_number'], 'limit': '2'})
        builds = apple_get('/v1/builds?' + query, token)
        require(builds.get('data') == [] and builds.get('links', {}).get('next') in {None, ''},
                'Build number already exists or cannot be reconciled; do not upload again.')
        self.env['API_PRIVATE_KEYS_DIR'] = str(self.path)
        self.upload_started = True
        self.status = 'upload_outcome_uncertain'
        self.run(['/usr/bin/xcrun', 'altool', '--upload-package', str(ipa), '--platform', 'ios',
                  '--apple-id', c['asc_app_id'], '--bundle-id', c['bundle_id'], '--bundle-version', c['build_number'],
                  '--bundle-short-version-string', c['build_version']] + uploader_auth(c) +
                 ['--wait', '--output-format', 'json'], 'apple-upload', timeout=900)
        self.status = 'upload_accepted_processing_unverified'
        # One read after an accepted upload, not a retry of the upload itself.
        token = make_uploader_jwt(c, key, self.run, time.time())
        builds = apple_get('/v1/builds?' + query, token)
        data = builds.get('data', [])
        if len(data) == 1 and data[0].get('attributes', {}).get('processingState') == 'VALID':
            self.status = 'apple_processed_valid'


def interrupted(signum, frame):
    raise Blocked('Signing invocation interrupted; any started upload must be reconciled.')


def main():
    invocation = None
    primary = 1
    sha = None
    try:
        os.umask(0o077)
        c = json.loads(CONFIG.read_text())
        validate_config(c)
        require(sys.platform == 'darwin' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted',
                'Signing is restricted to ephemeral GitHub-hosted macOS.')
        require(os.environ.get('RUNNER_DEBUG') != '1' and os.environ.get('ACTIONS_STEP_DEBUG') != 'true'
                and os.environ.get('ACTIONS_RUNNER_DEBUG') != 'true', 'Debug logging is forbidden for signing.')
        require(os.environ.get('BIRDS_APPROVED_UPLOAD_RUN_ID') == os.environ.get('GITHUB_RUN_ID')
                and full(os.environ.get('GITHUB_RUN_ID'), r'[1-9][0-9]+'),
                'This exact workflow run has not been approved for a one-time upload.')
        private = {name: os.environ.pop(name, '') for name in SECRET_NAMES}
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        sha = live_gate(c, event, os.environ, GitHub(os.environ.get('GH_TOKEN', '')))
        require(all(private.values()), 'Approved environment signing secrets are missing.')
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        invocation = Invocation(c, os.environ)
        invocation.execute(private, sha)
        primary = 0
    except Blocked as error:
        print('BLOCKED: ' + str(error), file=sys.stderr)
    except Exception:
        print('BLOCKED: Private signing operation failed; details were not published.', file=sys.stderr)
    finally:
        if invocation:
            # Cleanup errors never replace the primary failure or pretend an uncertain upload failed cleanly.
            status = invocation.status
            # A normal cancellation must not interrupt cleanup midway. SIGKILL/runner loss cannot be trapped.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            try:
                failures = invocation.cleanup()
            except Exception:
                failures = ['cleanup-outcome-unknown']
            if failures:
                print('Cleanup incomplete: ' + ', '.join(failures) + '. Revoke exposed credentials if runner isolation is uncertain.', file=sys.stderr)
                if primary == 0:
                    primary = 1
            try:
                result = summarize(sha, invocation.digest, status)
                result['cleanup_complete'] = not failures
                safe = json.dumps(result, sort_keys=True)
            except Exception:
                safe = '{"result_summary": "unavailable"}'
                if primary == 0:
                    primary = 1
            print(safe)
            summary = os.environ.get('GITHUB_STEP_SUMMARY')
            if summary:
                try:
                    with open(summary, 'a') as out:
                        out.write(safe + '\n')
                except OSError:
                    print('Safe result summary could not be saved; resource cleanup already ran.', file=sys.stderr)
                    if primary == 0:
                        primary = 1
            if status == 'upload_outcome_uncertain':
                print('Upload may have reached Apple. Inspect the app/build in App Store Connect before any retry.', file=sys.stderr)
    return primary


if __name__ == '__main__':
    sys.exit(main())
