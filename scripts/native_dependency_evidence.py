#!/usr/bin/env python3
"""Stage a small, fail-closed native dependency evidence bundle; never upload it.

Only the capture shell invokes native tools. This module uses Python's standard
library and can be tested without Flutter, Gradle, CocoaPods, network or secrets.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

MAX_TEXT = 1024 * 1024
MAX_BUNDLE = 4 * MAX_TEXT
MAX_BINARY = 256 * MAX_TEXT
IOS_PROJECT_PATH = 'app/ios/Runner.xcodeproj/project.pbxproj'
SCHEMAS = {'android': 1, 'ios': 2}
COMMON_SOURCES = (
    'app/pubspec.yaml', 'app/pubspec.lock',
    '.github/workflows/native-checks.yml',
    'scripts/capture_native_dependency_evidence.sh',
    'scripts/native_dependency_evidence.py',
)
PLATFORM_SOURCES = {
    'android': (
        'app/android/app/build.gradle.kts', 'app/android/build.gradle.kts',
        'app/android/settings.gradle.kts', 'app/android/gradle.properties',
        'app/android/gradle/wrapper/gradle-wrapper.properties',
        'app/android/ci/flutter-plugin-repositories.init.gradle',
        'app/android/app/src/main/AndroidManifest.xml',
        'app/android/app/src/main/res/xml/backup_rules.xml',
        'app/android/app/src/main/res/xml/data_extraction_rules.xml',
        'app/android/app/src/main/kotlin/dev/sudanbirds/sudan_birds/MainActivity.kt',
    ),
    'ios': (
        IOS_PROJECT_PATH, 'app/ios/Runner/AppDelegate.swift',
        'app/ios/Runner/Info.plist', 'app/ios/Runner/Runner.entitlements',
    ),
}
RAW_NAMES = {
    'android': {'flutter.json', 'gradle.txt', 'android-debugRuntimeClasspath.txt',
                'android-tink-insight.txt'},
    'ios': {'flutter.json', 'xcode.txt', 'cocoapods.txt'},
}
OUTPUT_NAMES = {
    'android': {'pubspec.lock', 'manifest.json', 'android-debugRuntimeClasspath.txt',
                'android-tink-insight.txt'},
    'ios': {'pubspec.lock', 'manifest.json', 'Podfile.lock', 'pod-resolution.json',
            'ios-project.pbxproj'},
}
BUILD_FILES = {
    'android': 'app/build/app/outputs/flutter-apk/app-debug.apk',
    'ios': 'app/build/ios/iphonesimulator/Runner.app/Runner',
}
SOURCE_SNAPSHOT = 'post-build hashes, not a signed build attestation'
MANIFEST_FIELDS = {'schema', 'platform', 'scope', 'checked_out_commit',
                   'tracked_worktree_dirty_after_build', 'source_snapshot', 'source_sha256',
                   'tool_versions', 'built_file', 'evidence_sha256', 'release_clearance', 'remaining_gates'}
SCOPES = {'android': 'Android debugRuntimeClasspath / debug APK',
          'ios': 'iOS debug unsigned simulator / CocoaPods'}
SECRET_PATTERNS = (
    r'-----BEGIN (?:[A-Z ]*PRIVATE KEY|OPENSSH PRIVATE KEY)-----',
    r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    r'\bgh[pousr]_[A-Za-z0-9]{20,}\b',
    r'\bgithub_pat_[A-Za-z0-9_]{20,}\b',
    r'\bxox[baprs]-[A-Za-z0-9-]{10,}\b',
    r'\bAIza[0-9A-Za-z_-]{30,}\b',
    r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b',
    r'(?i)\b(?:password|passwd|secret|client_secret|api[_-]?key|access[_-]?key|'
    r'secret[_-]?key|token|authorization|service_role|signing[_-]?key)\b["\s]*[:=]',
    r'(?i)\b(?:bearer|basic)\s+[A-Za-z0-9+/_.=-]{8,}',
    r'(?i)\bhttps?://[^\s/]+@',
    r'(?i)\bhttps?://[^\s]+[?][^\s]+',
)
PRIVATE_PATH = re.compile(r'(?:/(?:home|Users|workspace|private|tmp|opt|var|Volumes)/|(?<![A-Za-z0-9])[A-Za-z]:[\\/])')
SAFE_NAME = re.compile(r'[A-Za-z0-9_.+-]+')


class EvidenceError(Exception):
    """Deliberately generic: never echo raw tool output or suspicious filenames."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def root_dir(path):
    path = Path(path).absolute()
    require(not path.is_symlink() and path.is_dir(), 'Required directory is missing or unsafe')
    return path.resolve()


def checked_path(root, relative):
    relative = Path(relative)
    require(not relative.is_absolute() and bool(relative.parts)
            and all(part not in ('.', '..') for part in relative.parts), 'Unsafe relative path')
    current = root_dir(root)
    for part in relative.parts:
        current = current / part
        require(not current.is_symlink(), 'Symlink is forbidden in evidence inputs')
    return current


def read_file(root, relative, limit=MAX_TEXT):
    path = checked_path(root, relative)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as handle:
            info = os.fstat(handle.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                    'Evidence input must be a regular, non-hardlinked file')
            require(0 < info.st_size <= limit, 'Evidence input is empty or oversized')
            data = handle.read(limit + 1)
            require(len(data) == info.st_size, 'Evidence input changed or exceeded its size bound')
            return data
    except OSError as error:
        raise EvidenceError('Required evidence input is missing or unreadable') from error


def scan(data, allow_paths=False):
    try:
        text = data.decode('utf-8')
    except UnicodeError as error:
        raise EvidenceError('Evidence text is not UTF-8') from error
    require(all(char in '\n\r\t' or ord(char) >= 32 for char in text)
            and '\x7f' not in text, 'Binary/control bytes are forbidden')
    require(not any(re.search(pattern, text) for pattern in SECRET_PATTERNS),
            'Credential-like content rejected; raw value suppressed')
    require(allow_paths or not PRIVATE_PATH.search(text), 'Unredacted private path rejected')
    return text


def clean_report(data, roots):
    # Reject credentials first. Only known local roots are redacted, never secrets.
    text = scan(data, allow_paths=True)
    for root in sorted({str(Path(p).absolute()) for p in roots if p}, key=len, reverse=True):
        require(root != '/', 'Unsafe redaction root')
        text = re.sub(re.escape(root) + r'(?=/|[\s\'"),:]|$)', '<LOCAL_ROOT>', text)
    scan(text.encode())
    return text


def exact_directory(root, expected):
    root = root_dir(root)
    require({entry.name for entry in root.iterdir()} == set(expected),
            'Evidence directory has missing or unexpected entries')
    for name in expected:
        read_file(root, name)


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + '\n').encode()


def strict_json(data):
    def no_duplicates(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON key rejected')
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=no_duplicates)
    except (ValueError, UnicodeError) as error:
        raise EvidenceError('Malformed evidence JSON') from error


def digest(data):
    return hashlib.sha256(data).hexdigest()


def tool_versions(platform, raw):
    flutter_data = read_file(raw, 'flutter.json')
    scan(flutter_data, allow_paths=True)
    flutter = strict_json(flutter_data)
    require(isinstance(flutter, dict), 'Missing Flutter version metadata')
    fields = ('frameworkVersion', 'channel', 'frameworkRevision', 'engineRevision', 'dartSdkVersion')
    versions = {}
    for field in fields:
        value = flutter.get(field)
        require(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_.+() -]{1,120}', value),
                'Invalid or absent Flutter version field')
        versions[field] = value
    if platform == 'android':
        text = scan(read_file(raw, 'gradle.txt'), allow_paths=True)
        gradle = re.search(r'^Gradle ([0-9][A-Za-z0-9.+-]*)$', text, re.M)
        java = re.search(r'^(?:Launcher JVM|JVM):\s+([0-9][A-Za-z0-9.+_-]*)', text, re.M)
        require(gradle and java, 'Missing Gradle/Java version metadata')
        versions.update(gradle=gradle.group(1), java=java.group(1))
    else:
        xcode = scan(read_file(raw, 'xcode.txt'))
        match = re.fullmatch(r'Xcode ([0-9.]+)\nBuild version ([A-Za-z0-9.]+)\s*', xcode)
        pod = scan(read_file(raw, 'cocoapods.txt')).strip()
        require(match and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', pod),
                'Missing Xcode/CocoaPods version metadata')
        versions.update(xcode=match.group(1), xcode_build=match.group(2), cocoapods=pod)
    return versions


def source_hashes(repo, platform):
    sources = list(COMMON_SOURCES + PLATFORM_SOURCES[platform])
    lib = checked_path(repo, 'app/lib')
    require(lib.is_dir(), 'Missing Dart source directory')
    for directory, dirs, files in os.walk(lib, followlinks=False):
        require(not any((Path(directory) / name).is_symlink() for name in dirs + files),
                'Symlink in source snapshot')
        require(all(SAFE_NAME.fullmatch(name) for name in dirs), 'Unexpected source directory name')
        for name in files:
            require(name.endswith('.dart') and SAFE_NAME.fullmatch(name),
                    'Unexpected file in Dart source snapshot')
            sources.append((Path(directory) / name).relative_to(repo).as_posix())
    require('app/lib/main.dart' in sources and len(sources) <= 200,
            'Source snapshot is missing or too large')
    return [{'path': name, 'sha256': digest(read_file(repo, name))} for name in sorted(sources)]


def android_reports(raw, roots):
    reports = {}
    for name in ('android-debugRuntimeClasspath.txt', 'android-tink-insight.txt'):
        text = clean_report(read_file(raw, name), roots)
        require(not re.search(r'FAILED|Could not resolve|No dependencies matching|\(n\)', text, re.I),
                'Android resolution is failed, absent or unresolved')
        require('debugRuntimeClasspath' in text and 'BUILD SUCCESSFUL' in text,
                'Android report has no successful target configuration')
        require(re.search(r'com\.google\.crypto\.tink:tink-android:[0-9]', text),
                'Tink selection is missing')
        reports[name] = text.encode()
    require(re.search(r'^debugRuntimeClasspath(?:\s|$)',
                      reports['android-debugRuntimeClasspath.txt'].decode(), re.M),
            'Android dependency graph targets the wrong configuration')
    return reports


def ios_resolution(repo):
    lock = read_file(repo, 'app/ios/Podfile.lock')
    text = scan(lock)
    require(lock == read_file(repo, 'app/ios/Pods/Manifest.lock'),
            'Installed Pods do not match Podfile.lock')
    require(all(re.search(r'^' + name + r':', text, re.M)
                for name in ('PODS', 'DEPENDENCIES', 'SPEC CHECKSUMS', 'PODFILE CHECKSUM', 'COCOAPODS'))
            and re.search(r'^  - Flutter \(', text, re.M), 'Incomplete CocoaPods lock evidence')
    specs = checked_path(repo, 'app/ios/Pods/Local Podspecs')
    require(specs.is_dir(), 'Missing CocoaPods local resolution metadata')
    entries = list(specs.iterdir())
    require(0 < len(entries) <= 100, 'Missing or excessive CocoaPods metadata')
    result = []
    for entry in sorted(entries):
        require(re.fullmatch(r'[A-Za-z0-9_+.-]+\.podspec\.json', entry.name),
                'Unexpected CocoaPods metadata file')
        data = read_file(specs, entry.name)
        scan(data, allow_paths=True)
        spec = strict_json(data)
        require(isinstance(spec, dict), 'Malformed CocoaPods metadata')
        name, version = spec.get('name'), spec.get('version')
        require(isinstance(name, str) and SAFE_NAME.fullmatch(name)
                and entry.name == name + '.podspec.json'
                and isinstance(version, str) and re.fullmatch(r'[A-Za-z0-9_.+-]{1,80}', version),
                'Invalid CocoaPods identity')
        # Match the installed pod's identity, not just a syntactically valid JSON file.
        require(re.search(r'^  - ' + re.escape(name) + r'(?:/[^ (]+)? \('
                          + re.escape(version) + r'\)', text, re.M),
                'Local pod identity is absent from the resolved lock')
        ios = spec.get('ios', {})
        require(isinstance(ios, dict), 'Malformed CocoaPods iOS declarations')
        declarations = {'dependencies': spec.get('dependencies', {}),
                        'ios_dependencies': ios.get('dependencies', {})}
        for dependencies in declarations.values():
            require(isinstance(dependencies, dict)
                    and all(isinstance(key, str) and re.fullmatch(r'[A-Za-z0-9_+./-]+', key)
                            and isinstance(values, list)
                            and all(isinstance(value, str)
                                    and re.fullmatch(r'[A-Za-z0-9_.+<>=~! ,*-]{1,80}', value)
                                    for value in values)
                            for key, values in dependencies.items()),
                    'Malformed CocoaPods dependencies')
        result.append({'pod': name, 'pod_version': version,
                       'local_podspec_sha256': digest(data), **declarations})
    return {'Podfile.lock': lock, 'pod-resolution.json': json_bytes({
        'resolution': 'CocoaPods; installed Manifest.lock byte-matches Podfile.lock',
        'local_podspecs': result,
        'limits': 'Pod versions may differ from Dart package versions. No binary, license or privacy clearance.',
    })}


def stage(platform, repo, raw, output, commit, dirty, redaction_roots=()):
    repo, raw = root_dir(repo), root_dir(raw)
    require(re.fullmatch(r'[a-f0-9]{40}', commit) is not None, 'Invalid checked-out commit')
    require(type(dirty) is bool, 'Invalid working tree status')
    output = Path(output).absolute()
    require(not output.exists() and not output.is_symlink(), 'Output must be a fresh directory')
    parent = root_dir(output.parent)
    require(not parent.is_relative_to(repo) and not parent.is_relative_to(raw),
            'Output must be separate from source and raw capture directories')
    exact_directory(raw, RAW_NAMES[platform])
    lock = read_file(repo, 'app/pubspec.lock')
    lock_text = scan(lock)
    require('packages:\n' in lock_text and 'sdks:\n' in lock_text,
            'Missing Dart package lock structure')
    files = {'pubspec.lock': lock}
    if platform == 'android':
        files.update(android_reports(raw, (repo, *redaction_roots)))
    else:
        files.update(ios_resolution(repo))
        # One fixed source file, never an arbitrary source directory or raw diff.
        # Keep exact bytes; credentials/private paths fail instead of being redacted.
        files['ios-project.pbxproj'] = read_file(repo, IOS_PROJECT_PATH)
        scan(files['ios-project.pbxproj'])
    built = read_file(repo, BUILD_FILES[platform], MAX_BINARY)
    sources = source_hashes(repo, platform)
    if platform == 'ios':
        require({item['path']: item['sha256'] for item in sources}[IOS_PROJECT_PATH]
                == digest(files['ios-project.pbxproj']),
                'iOS project snapshot changed during capture')
    manifest = {
        'schema': SCHEMAS[platform], 'platform': platform, 'scope': SCOPES[platform],
        'checked_out_commit': commit, 'tracked_worktree_dirty_after_build': dirty,
        'source_snapshot': SOURCE_SNAPSHOT,
        'source_sha256': sources,
        'tool_versions': tool_versions(platform, raw),
        'built_file': {'path': BUILD_FILES[platform], 'sha256': digest(built), 'bytes': len(built)},
        'evidence_sha256': {name: digest(data) for name, data in sorted(files.items())},
        'release_clearance': False,
        'remaining_gates': ['exact release native graph and artifact verification',
                            'full resolved Maven/Pod and Dart/FFI source/license/notice inventory',
                            'packaged native assets, privacy manifests and entitlements inspection',
                            'signed-device builds, real-device storage/OAuth and security tests'],
    }
    files['manifest.json'] = json_bytes(manifest)
    require(set(files) == OUTPUT_NAMES[platform], 'Unexpected staged evidence files')
    require(sum(len(data) for data in files.values()) <= MAX_BUNDLE, 'Evidence bundle is oversized')
    for data in files.values():
        require(0 < len(data) <= MAX_TEXT, 'Evidence output is empty or oversized')
        scan(data)
    # Nothing is staged before every input and output passes validation.
    output.mkdir(mode=0o700)
    for name, data in files.items():
        with (output / name).open('xb') as handle:
            os.chmod(output / name, 0o600)
            handle.write(data)
    validate(platform, output)


def validate(platform, output):
    exact_directory(output, OUTPUT_NAMES[platform])
    files = {name: read_file(output, name) for name in OUTPUT_NAMES[platform]}
    require(sum(len(data) for data in files.values()) <= MAX_BUNDLE, 'Evidence bundle is oversized')
    for data in files.values():
        scan(data)
    manifest = strict_json(files.pop('manifest.json'))
    require(isinstance(manifest, dict) and set(manifest) == MANIFEST_FIELDS
            and manifest.get('schema') == SCHEMAS[platform]
            and manifest.get('platform') == platform and manifest.get('scope') == SCOPES[platform]
            and manifest.get('release_clearance') is False,
            'Evidence manifest scope is invalid')
    require(manifest.get('evidence_sha256') == {name: digest(data) for name, data in files.items()},
            'Evidence files changed after staging')
    require(isinstance(manifest['checked_out_commit'], str)
            and re.fullmatch(r'[a-f0-9]{40}', manifest['checked_out_commit'])
            and type(manifest['tracked_worktree_dirty_after_build']) is bool
            and manifest['source_snapshot'] == SOURCE_SNAPSHOT,
            'Invalid source identity metadata')
    built = manifest['built_file']
    require(isinstance(built, dict) and set(built) == {'path', 'sha256', 'bytes'}
            and built['path'] == BUILD_FILES[platform]
            and isinstance(built['sha256'], str) and re.fullmatch(r'[a-f0-9]{64}', built['sha256'])
            and type(built['bytes']) is int and 0 < built['bytes'] <= MAX_BINARY,
            'Invalid build product metadata')
    sources = manifest['source_sha256']
    require(isinstance(sources, list) and 0 < len(sources) <= 200, 'Invalid source snapshot')
    source_map = {}
    for item in sources:
        require(isinstance(item, dict) and set(item) == {'path', 'sha256'}
                and isinstance(item['path'], str)
                and item['path'] not in source_map
                and isinstance(item['sha256'], str)
                and re.fullmatch(r'[a-f0-9]{64}', item['sha256']), 'Invalid source snapshot item')
        name = item['path']
        require(name in COMMON_SOURCES + PLATFORM_SOURCES[platform]
                or (name.startswith('app/lib/') and name.endswith('.dart')
                    and all(SAFE_NAME.fullmatch(part) and part not in ('.', '..')
                            for part in name.split('/'))), 'Unexpected source snapshot path')
        source_map[name] = item['sha256']
    require(set(COMMON_SOURCES + PLATFORM_SOURCES[platform]).issubset(source_map)
            and 'app/lib/main.dart' in source_map
            and source_map['app/pubspec.lock'] == digest(files['pubspec.lock']),
            'Source snapshot does not match the evidence lock')
    if platform == 'ios':
        require(source_map[IOS_PROJECT_PATH] == digest(files['ios-project.pbxproj']),
                'iOS project snapshot does not match the source manifest')
    versions = manifest['tool_versions']
    common = {'frameworkVersion', 'channel', 'frameworkRevision', 'engineRevision', 'dartSdkVersion'}
    extra = {'gradle', 'java'} if platform == 'android' else {'xcode', 'xcode_build', 'cocoapods'}
    require(isinstance(versions, dict) and set(versions) == common | extra
            and all(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_.+() -]{1,120}', value)
                    for value in versions.values()), 'Unexpected tool version metadata')
    gates = manifest['remaining_gates']
    require(isinstance(gates, list) and bool(gates)
            and all(isinstance(value, str) and 0 < len(value) <= 160 for value in gates),
            'Missing release limitations')


def git_identity(repo):
    def git(*arguments):
        result = subprocess.run(['git', '-C', str(repo), *arguments],
                                capture_output=True, timeout=15, check=False)
        require(result.returncode == 0, 'Cannot verify checked-out source identity')
        return result.stdout
    commit = git('rev-parse', 'HEAD').decode('ascii').strip()
    dirty = bool(git('status', '--porcelain', '--untracked-files=no'))
    return commit, dirty


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('stage', 'validate'))
    parser.add_argument('--platform', choices=('android', 'ios'), required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repo', type=Path)
    parser.add_argument('--raw', type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.action == 'validate':
            validate(arguments.platform, arguments.output)
        else:
            require(arguments.repo is not None and arguments.raw is not None, 'Source and raw paths required')
            commit, dirty = git_identity(arguments.repo)
            stage(arguments.platform, arguments.repo, arguments.raw, arguments.output, commit, dirty,
                  (os.environ.get('HOME'), os.environ.get('GRADLE_USER_HOME')))
    except (EvidenceError, OSError, ValueError, subprocess.SubprocessError):
        # Avoid credential/path leakage even when a parser or OS operation fails.
        print('Native evidence rejected: missing, unsafe, unresolved or inconsistent input. No upload allowed.',
              file=sys.stderr)
        return 1
    print('Native dependency evidence validated; debug/simulator scope only, not release clearance.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
