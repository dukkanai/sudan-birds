#!/usr/bin/env python3
"""Offline synthetic boundary tests; no native tool, network, or upload is used."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import native_dependency_evidence as evidence

ROOT = Path(__file__).resolve().parents[1]
COMMIT = 'a' * 40
DART_LOCK = b'packages:\n  flutter:\n    source: sdk\n    version: "0.0.0"\nsdks:\n  dart: ">=3.10.3 <4.0.0"\n'
POD_LOCK = b'''PODS:
  - Flutter (1.0.0)
  - flutter_secure_storage_darwin (10.0.0):
    - Flutter
DEPENDENCIES:
  - Flutter
  - flutter_secure_storage_darwin
SPEC CHECKSUMS:
  Flutter: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  flutter_secure_storage_darwin: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PODFILE CHECKSUM: cccccccccccccccccccccccccccccccccccccccc
COCOAPODS: 1.16.2
'''
GRAPH = b'''> Task :app:dependencies
debugRuntimeClasspath - Runtime classpath of debug.
+--- com.google.crypto.tink:tink-android:1.23.0
BUILD SUCCESSFUL in 1s
'''
INSIGHT = b'''> Task :app:dependencyInsight
com.google.crypto.tink:tink-android:1.23.0
  Variant runtime:
  Selection reasons:
     - By conflict resolution: between versions 1.23.0 and 1.22.0
\\--- debugRuntimeClasspath
BUILD SUCCESSFUL in 1s
'''


class EvidenceBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / 'repo'
        self.raw = self.base / 'raw'
        self.out = self.base / 'staged'
        self.repo.mkdir()
        self.raw.mkdir()
        for name in (*evidence.COMMON_SOURCES, *evidence.PLATFORM_SOURCES['android'],
                     *evidence.PLATFORM_SOURCES['ios'], 'app/lib/main.dart'):
            self.write(name, b'synthetic source\n')
        self.write('app/pubspec.lock', DART_LOCK)
        for name in evidence.BUILD_FILES.values():
            self.write(name, b'synthetic executable; never staged\x00')

    def write(self, name, value):
        target = self.repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(value)

    def raw_files(self, platform):
        flutter = {key: '3.38.5' for key in ('frameworkVersion', 'frameworkRevision',
                                           'engineRevision', 'dartSdkVersion')}
        flutter['channel'] = 'stable'
        (self.raw / 'flutter.json').write_text(json.dumps(flutter))
        if platform == 'android':
            (self.raw / 'gradle.txt').write_text('Gradle 8.14\nLauncher JVM: 17.0.17 (Vendor)\n')
            (self.raw / 'android-debugRuntimeClasspath.txt').write_bytes(GRAPH)
            (self.raw / 'android-tink-insight.txt').write_bytes(INSIGHT)
        else:
            (self.raw / 'xcode.txt').write_text('Xcode 16.4\nBuild version 16F6\n')
            (self.raw / 'cocoapods.txt').write_text('1.16.2\n')
            self.write('app/ios/Podfile.lock', POD_LOCK)
            self.write('app/ios/Pods/Manifest.lock', POD_LOCK)
            self.write('app/ios/Pods/Local Podspecs/flutter_secure_storage_darwin.podspec.json',
                       json.dumps({'name': 'flutter_secure_storage_darwin', 'version': '10.0.0',
                                   'dependencies': {'Flutter': []},
                                   'ios': {'dependencies': {'Flutter': []}},
                                   'source': {'path': str(self.repo / 'private-cache')}}).encode())

    def stage(self, platform='android', roots=()):
        evidence.stage(platform, self.repo, self.raw, self.out, COMMIT, False, roots)

    def rejected(self, platform='android'):
        with self.assertRaises(evidence.EvidenceError):
            self.stage(platform)
        self.assertFalse(self.out.exists(), 'Failure must happen before staging any files')

    def test_android_stages_exact_allowlist_and_exact_dart_lock(self):
        self.raw_files('android')
        self.write('.env', b'do not inspect or stage')
        self.write('app/android/local.properties', b'private sdk directory')
        self.stage()
        self.assertEqual({p.name for p in self.out.iterdir()}, evidence.OUTPUT_NAMES['android'])
        self.assertEqual((self.out / 'pubspec.lock').read_bytes(), DART_LOCK)
        self.assertEqual((self.out / 'android-tink-insight.txt').read_bytes(), INSIGHT)
        manifest = json.loads((self.out / 'manifest.json').read_text())
        self.assertEqual(manifest['checked_out_commit'], COMMIT)
        self.assertIn({'path': 'app/pubspec.lock', 'sha256': hashlib.sha256(DART_LOCK).hexdigest()},
                      manifest['source_sha256'])
        self.assertFalse(manifest['release_clearance'])
        self.assertEqual(manifest['tool_versions']['gradle'], '8.14')
        self.assertEqual(manifest['tool_versions']['java'], '17.0.17')
        self.assertNotIn(str(self.base), (self.out / 'manifest.json').read_text())
        self.assertNotIn('synthetic executable', ''.join(p.read_text() for p in self.out.iterdir()))
        evidence.validate('android', self.out)

    def test_real_public_dart_lock_is_preserved_without_url_false_positive(self):
        self.raw_files('android')
        lock = (ROOT / 'app/pubspec.lock').read_bytes()
        self.assertIn(b'https://pub.dev', lock)
        self.write('app/pubspec.lock', lock)
        self.stage()
        self.assertEqual((self.out / 'pubspec.lock').read_bytes(), lock)

    def test_windows_private_path_still_fails(self):
        self.raw_files('android')
        self.write('app/pubspec.lock', DART_LOCK + b'path: C:\\Users\\person\\private\n')
        self.rejected()

    def test_ios_stages_exact_lock_and_reduced_pod_metadata(self):
        self.raw_files('ios')
        self.stage('ios')
        self.assertEqual({p.name for p in self.out.iterdir()}, evidence.OUTPUT_NAMES['ios'])
        self.assertEqual((self.out / 'Podfile.lock').read_bytes(), POD_LOCK)
        resolution = json.loads((self.out / 'pod-resolution.json').read_text())
        pod = resolution['local_podspecs'][0]
        self.assertEqual(pod['pod_version'], '10.0.0')
        self.assertEqual(pod['dependencies'], {'Flutter': []})
        self.assertEqual(pod['ios_dependencies'], {'Flutter': []})
        self.assertEqual(len(pod['local_podspec_sha256']), 64)
        self.assertNotIn(str(self.repo), (self.out / 'pod-resolution.json').read_text())
        self.assertNotIn('source', pod)
        evidence.validate('ios', self.out)

    def test_ios_preserves_exact_public_project_snapshot_and_dirty_status(self):
        self.raw_files('ios')
        project = (ROOT / evidence.IOS_PROJECT_PATH).read_bytes()
        self.write(evidence.IOS_PROJECT_PATH, project)
        evidence.stage('ios', self.repo, self.raw, self.out, COMMIT, True)
        self.assertEqual((self.out / 'ios-project.pbxproj').read_bytes(), project)
        manifest = json.loads((self.out / 'manifest.json').read_text())
        self.assertEqual(manifest['schema'], 2)
        self.assertTrue(manifest['tracked_worktree_dirty_after_build'])
        self.assertFalse(manifest['release_clearance'])
        project_hash = hashlib.sha256(project).hexdigest()
        self.assertEqual(manifest['evidence_sha256']['ios-project.pbxproj'], project_hash)
        self.assertIn({'path': evidence.IOS_PROJECT_PATH, 'sha256': project_hash},
                      manifest['source_sha256'])
        evidence.validate('ios', self.out)

    def test_missing_ios_project_fails_before_staging(self):
        self.raw_files('ios')
        (self.repo / evidence.IOS_PROJECT_PATH).unlink()
        self.rejected('ios')

    def test_ios_project_unsafe_file_types_fail_before_staging(self):
        self.raw_files('ios')
        project = self.repo / evidence.IOS_PROJECT_PATH
        original = project.read_bytes()
        for kind in ('symlink', 'hardlink', 'fifo'):
            with self.subTest(kind=kind):
                project.unlink()
                if kind == 'symlink':
                    project.symlink_to(self.repo / 'app/pubspec.lock')
                elif kind == 'hardlink':
                    os.link(self.repo / 'app/pubspec.lock', project)
                else:
                    os.mkfifo(project)
                self.rejected('ios')
                project.unlink()
                project.write_bytes(original)

    def test_ios_project_empty_or_oversized_fails_before_staging(self):
        self.raw_files('ios')
        for value in (b'', b'x' * (evidence.MAX_TEXT + 1)):
            with self.subTest(length=len(value)):
                self.write(evidence.IOS_PROJECT_PATH, value)
                self.rejected('ios')

    def test_ios_project_binary_or_control_text_fails_before_staging(self):
        self.raw_files('ios')
        for value in (b'\xff', b'\x00', b'\x1b[31m', b'\x7f'):
            with self.subTest(value=value):
                self.write(evidence.IOS_PROJECT_PATH, b'synthetic project\n' + value)
                self.rejected('ios')

    def test_ios_project_credentials_fail_without_echoing_content(self):
        self.raw_files('ios')
        value = b'password' + b'=synthetic-project-sensitive'
        self.write(evidence.IOS_PROJECT_PATH, value)
        with self.assertRaises(evidence.EvidenceError) as error:
            self.stage('ios')
        self.assertNotIn(value.decode(), str(error.exception))
        self.assertFalse(self.out.exists())

    def test_ios_project_private_paths_fail_without_redaction(self):
        self.raw_files('ios')
        for value in (b'/Users/another/private', b'C:\\Users\\person\\private',
                      str(self.repo).encode() + b'/private'):
            with self.subTest(value=value):
                self.write(evidence.IOS_PROJECT_PATH, value)
                self.rejected('ios')

    def test_ios_project_change_during_capture_fails_before_staging(self):
        self.raw_files('ios')
        sources = evidence.source_hashes(self.repo, 'ios')
        for item in sources:
            if item['path'] == evidence.IOS_PROJECT_PATH:
                item['sha256'] = '0' * 64
        with patch.object(evidence, 'source_hashes', return_value=sources):
            self.rejected('ios')

    def test_ios_project_missing_output_fails_final_validation(self):
        self.raw_files('ios')
        self.stage('ios')
        (self.out / 'ios-project.pbxproj').unlink()
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('ios', self.out)

    def test_ios_project_tampering_fails_final_validation(self):
        self.raw_files('ios')
        self.stage('ios')
        (self.out / 'ios-project.pbxproj').write_bytes(b'changed synthetic project\n')
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('ios', self.out)

    def test_ios_project_output_symlink_fails_final_validation(self):
        self.raw_files('ios')
        self.stage('ios')
        project = self.out / 'ios-project.pbxproj'
        project.unlink()
        project.symlink_to(self.repo / evidence.IOS_PROJECT_PATH)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('ios', self.out)

    def test_ios_unexpected_output_file_fails_final_validation(self):
        self.raw_files('ios')
        self.stage('ios')
        (self.out / 'signing.p12').write_bytes(b'not a real credential')
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('ios', self.out)

    def test_ios_project_evidence_hash_cannot_override_source_hash(self):
        self.raw_files('ios')
        self.stage('ios')
        project = b'changed synthetic project\n'
        (self.out / 'ios-project.pbxproj').write_bytes(project)
        manifest = json.loads((self.out / 'manifest.json').read_text())
        manifest['evidence_sha256']['ios-project.pbxproj'] = hashlib.sha256(project).hexdigest()
        (self.out / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('ios', self.out)

    def test_ios_legacy_schema_cannot_claim_project_snapshot_evidence(self):
        self.raw_files('ios')
        self.stage('ios')
        manifest = json.loads((self.out / 'manifest.json').read_text())
        manifest['schema'] = 1
        (self.out / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('ios', self.out)

    def test_ios_snapshot_keeps_bundle_limit(self):
        self.raw_files('ios')
        with patch.object(evidence, 'MAX_BUNDLE', 10):
            self.rejected('ios')

    def test_missing_each_raw_input_fails(self):
        self.raw_files('android')
        for name in evidence.RAW_NAMES['android']:
            with self.subTest(name=name):
                file = self.raw / name
                data = file.read_bytes()
                file.unlink()
                self.rejected()
                file.write_bytes(data)

    def test_unexpected_raw_file_fails_without_reading_credential(self):
        self.raw_files('android')
        (self.raw / 'signing.p12').write_bytes(b'not a real credential')
        self.rejected()

    def test_raw_nested_directory_fails(self):
        self.raw_files('android')
        (self.raw / 'cache').mkdir()
        self.rejected()

    def test_raw_symlink_file_fails(self):
        self.raw_files('android')
        (self.raw / 'gradle.txt').unlink()
        (self.raw / 'gradle.txt').symlink_to(self.repo / 'app/pubspec.lock')
        self.rejected()

    def test_source_symlink_file_fails(self):
        self.raw_files('android')
        (self.repo / 'app/pubspec.lock').unlink()
        (self.repo / 'app/pubspec.lock').symlink_to(self.raw / 'gradle.txt')
        self.rejected()

    def test_source_symlink_parent_fails(self):
        self.raw_files('android')
        lib = self.repo / 'app/lib'
        lib.rename(self.repo / 'real-lib')
        lib.symlink_to(self.repo / 'real-lib', target_is_directory=True)
        self.rejected()

    def test_source_nested_symlink_directory_fails(self):
        self.raw_files('android')
        (self.repo / 'app/lib/linked').symlink_to(self.raw, target_is_directory=True)
        self.rejected()

    def test_hardlink_fails(self):
        self.raw_files('android')
        os.link(self.raw / 'gradle.txt', self.base / 'other-link')
        self.rejected()

    def test_fifo_fails_without_hanging(self):
        self.raw_files('android')
        (self.raw / 'gradle.txt').unlink()
        os.mkfifo(self.raw / 'gradle.txt')
        self.rejected()

    def test_oversized_and_empty_input_fail(self):
        self.raw_files('android')
        for value in (b'', b'x' * (evidence.MAX_TEXT + 1)):
            with self.subTest(length=len(value)):
                (self.raw / 'android-debugRuntimeClasspath.txt').write_bytes(value)
                self.rejected()

    def test_binary_or_control_text_fails(self):
        self.raw_files('android')
        for value in (b'\xff', b'\x00', b'\x1b[31m', b'\x7f'):
            with self.subTest(value=value):
                (self.raw / 'android-debugRuntimeClasspath.txt').write_bytes(GRAPH + value)
                self.rejected()

    def test_credential_patterns_fail_without_echoing_content(self):
        self.raw_files('android')
        values = [
            'password' + '=synthetic-example',
            'api_key' + ': synthetic-example',
            'Authorization' + ': Bearer synthetic-example',
            '-----BEGIN ' + 'PRIVATE KEY-----',
            'ghp_' + 'A' * 30,
            'AKIA' + 'A' * 16,
            'https://synthetic:example@invalid.example/source',
            'https://invalid.example/source?credential=example',
        ]
        for value in values:
            with self.subTest(kind=value[:8]):
                (self.raw / 'android-debugRuntimeClasspath.txt').write_bytes(GRAPH + value.encode())
                with self.assertRaises(evidence.EvidenceError) as error:
                    self.stage()
                self.assertNotIn(value, str(error.exception))
                self.assertFalse(self.out.exists())

    def test_only_known_private_paths_are_redacted(self):
        self.raw_files('android')
        (self.raw / 'android-debugRuntimeClasspath.txt').write_bytes(
            GRAPH + ('Report: ' + str(self.repo) + '/app/build/report.html\n').encode())
        self.stage()
        staged = (self.out / 'android-debugRuntimeClasspath.txt').read_text()
        self.assertIn('<LOCAL_ROOT>/app/build/report.html', staged)
        self.assertNotIn(str(self.repo), staged)

    def test_unknown_private_path_fails(self):
        self.raw_files('android')
        (self.raw / 'android-debugRuntimeClasspath.txt').write_bytes(GRAPH + b'/Users/another/account\n')
        self.rejected()

    def test_lockfile_is_never_redacted(self):
        self.raw_files('android')
        self.write('app/pubspec.lock', DART_LOCK + b'path: /Users/person/private\n')
        self.rejected()

    def test_unresolved_or_missing_tink_fails(self):
        self.raw_files('android')
        values = [GRAPH + b'FAILED\n', GRAPH + b'Could not resolve module\n',
                  GRAPH + b'component (n)\n', GRAPH.replace(b'tink-android', b'other-artifact'),
                  GRAPH.replace(b'debugRuntimeClasspath', b'releaseRuntimeClasspath'),
                  GRAPH.replace(b'BUILD SUCCESSFUL', b'BUILD FAILED')]
        for value in values:
            with self.subTest(value=value[-30:]):
                (self.raw / 'android-debugRuntimeClasspath.txt').write_bytes(value)
                self.rejected()

    def test_tink_insight_missing_selection_fails(self):
        self.raw_files('android')
        (self.raw / 'android-tink-insight.txt').write_bytes(
            b'No dependencies matching given input were found in debugRuntimeClasspath\nBUILD SUCCESSFUL\n')
        self.rejected()

    def test_missing_built_file_fails(self):
        self.raw_files('android')
        (self.repo / evidence.BUILD_FILES['android']).unlink()
        self.rejected()

    def test_symlink_built_file_fails(self):
        self.raw_files('android')
        target = self.repo / evidence.BUILD_FILES['android']
        target.unlink()
        target.symlink_to(self.repo / 'app/pubspec.lock')
        self.rejected()

    def test_missing_source_file_fails(self):
        self.raw_files('android')
        (self.repo / 'app/android/gradle.properties').unlink()
        self.rejected()

    def test_missing_pod_lock_fails_even_after_successful_simulator_build(self):
        self.raw_files('ios')
        (self.repo / 'app/ios/Podfile.lock').unlink()
        self.rejected('ios')

    def test_installed_pod_lock_mismatch_fails(self):
        self.raw_files('ios')
        self.write('app/ios/Pods/Manifest.lock', POD_LOCK + b'\n')
        self.rejected('ios')

    def test_pod_metadata_identity_mismatch_fails(self):
        self.raw_files('ios')
        self.write('app/ios/Pods/Local Podspecs/flutter_secure_storage_darwin.podspec.json',
                   b'{"name":"flutter_secure_storage_darwin","version":"0.4.3"}')
        self.rejected('ios')

    def test_unexpected_pod_metadata_file_fails(self):
        self.raw_files('ios')
        self.write('app/ios/Pods/Local Podspecs/account.key', b'not a real credential')
        self.rejected('ios')

    def test_pod_metadata_symlink_fails(self):
        self.raw_files('ios')
        file = self.repo / 'app/ios/Pods/Local Podspecs/flutter_secure_storage_darwin.podspec.json'
        file.unlink()
        file.symlink_to(self.repo / 'app/pubspec.lock')
        self.rejected('ios')

    def test_empty_pod_metadata_fails(self):
        self.raw_files('ios')
        (self.repo / 'app/ios/Pods/Local Podspecs/flutter_secure_storage_darwin.podspec.json').unlink()
        self.rejected('ios')

    def test_duplicate_json_keys_fail(self):
        self.raw_files('android')
        (self.raw / 'flutter.json').write_bytes(b'{"channel":"stable","channel":"other"}')
        self.rejected()

    def test_missing_version_metadata_fails(self):
        self.raw_files('android')
        (self.raw / 'gradle.txt').write_bytes(b'Gradle 8.14\n')
        self.rejected()

    def test_output_existing_or_symlink_fails(self):
        self.raw_files('android')
        self.out.symlink_to(self.raw, target_is_directory=True)
        with self.assertRaises(evidence.EvidenceError):
            self.stage()
        self.out.unlink()
        self.out.mkdir()
        with self.assertRaises(evidence.EvidenceError):
            self.stage()

    def test_output_inside_source_tree_fails(self):
        self.raw_files('android')
        self.out = self.repo / 'evidence'
        self.rejected()

    def test_bundle_size_limit_fails(self):
        self.raw_files('android')
        with patch.object(evidence, 'MAX_BUNDLE', 10):
            self.rejected()

    def test_missing_output_file_fails_final_validation(self):
        self.raw_files('android')
        self.stage()
        (self.out / 'android-tink-insight.txt').unlink()
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('android', self.out)

    def test_extra_output_file_fails_final_validation(self):
        self.raw_files('android')
        self.stage()
        (self.out / '.env').write_text('do not upload')
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('android', self.out)

    def test_output_tampering_fails_final_validation(self):
        self.raw_files('android')
        self.stage()
        (self.out / 'pubspec.lock').write_bytes(DART_LOCK + b'\n')
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('android', self.out)

    def test_output_symlink_fails_final_validation(self):
        self.raw_files('android')
        self.stage()
        (self.out / 'pubspec.lock').unlink()
        (self.out / 'pubspec.lock').symlink_to(self.repo / 'app/pubspec.lock')
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('android', self.out)

    def test_unknown_manifest_field_fails_final_validation(self):
        self.raw_files('android')
        self.stage()
        manifest = json.loads((self.out / 'manifest.json').read_text())
        manifest['arbitrary_extra_metadata'] = 'not allowed'
        (self.out / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('android', self.out)

    def test_manifest_source_or_build_shape_tampering_fails(self):
        self.raw_files('android')
        self.stage()
        original = (self.out / 'manifest.json').read_bytes()
        for target in ('built_file', 'source_sha256', 'tool_versions', 'checked_out_commit'):
            with self.subTest(target=target):
                manifest = json.loads(original)
                manifest[target] = 'invalid'
                (self.out / 'manifest.json').write_text(json.dumps(manifest))
                with self.assertRaises(evidence.EvidenceError):
                    evidence.validate('android', self.out)

    def test_wrong_platform_and_release_clearance_fail(self):
        self.raw_files('android')
        self.stage()
        manifest = json.loads((self.out / 'manifest.json').read_text())
        manifest['release_clearance'] = True
        (self.out / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('android', self.out)
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate('ios', self.out)

    def test_cli_failure_does_not_print_private_path_or_raw_content(self):
        self.raw_files('android')
        with patch.object(evidence, 'git_identity', return_value=(COMMIT, False)), \
             patch('sys.argv', ['evidence', 'stage', '--platform', 'android', '--repo', str(self.repo),
                                '--raw', str(self.raw), '--output', str(self.out)]):
            (self.raw / 'gradle.txt').write_bytes(b'password' + b'=synthetic-sensitive\n')
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(evidence.main(), 1)
            self.assertNotIn(str(self.base), stderr.getvalue())
            self.assertNotIn('synthetic-sensitive', stderr.getvalue())


class WorkflowBoundaryTest(unittest.TestCase):
    def test_ios_explicitly_provisions_pinned_go_before_build_and_scan(self):
        workflow = (ROOT / '.github/workflows/native-checks.yml').read_text()
        ios = workflow.split('  ios-simulator:', 1)[1]
        setup = """      - name: Prepare Go for evidence secret scan
        uses: actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e # v7.0.0
        with:
          go-version: '1.27.3'
          cache: false
"""
        # macos-15 did not provide Go on PATH in the first real capture run.
        # Do not substitute runner-image assumptions or a success-on-error path.
        self.assertEqual(ios.count(setup), 1)
        self.assertLess(ios.index(setup), ios.index('flutter build ios --simulator'))
        self.assertLess(ios.index(setup), ios.index('gitleaks/v8@v8.21.2 dir'))
        self.assertNotIn('continue-on-error', ios)
        self.assertNotIn('|| true', ios)
        self.assertNotIn('if:', ios)

    def test_native_jobs_upload_only_platform_allowlists_after_scanning(self):
        workflow = (ROOT / '.github/workflows/native-checks.yml').read_text()
        self.assertIn('contents: read', workflow)
        self.assertNotIn('contents: write', workflow)
        self.assertNotIn('continue-on-error', workflow)
        self.assertNotIn('if: always()', workflow)
        self.assertNotIn('pull_request_target', workflow)
        for platform, job, build in (
            ('android', workflow.split('  android-debug:', 1)[1].split('  ios-simulator:', 1)[0],
             'flutter build apk --debug'),
            ('ios', workflow.split('  ios-simulator:', 1)[1],
             'flutter build ios --simulator --debug --no-codesign'),
        ):
            with self.subTest(platform=platform):
                capture = 'bash scripts/capture_native_dependency_evidence.sh ' + platform
                scan = 'gitleaks/v8@v8.21.2 dir --redact'
                upload = 'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'
                self.assertLess(job.index(build), job.index(capture))
                self.assertLess(job.index(capture), job.index(scan))
                self.assertLess(job.index(scan), job.index(upload))
                self.assertIn('if-no-files-found: error', job)
                self.assertIn('include-hidden-files: false', job)
                self.assertIn('retention-days: 7', job)
                path_block = job.split('          path: |\n', 1)[1].split('          if-no-files-found:', 1)[0]
                lines = [line.strip() for line in path_block.splitlines() if line.strip()]
                self.assertEqual(set(lines), {
                    '${{ runner.temp }}/native-evidence-' + platform + '/' + name
                    for name in evidence.OUTPUT_NAMES[platform]
                })
                self.assertEqual(len(lines), 4 if platform == 'android' else 5)

    def test_capture_is_postbuild_offline_and_scoped(self):
        script = (ROOT / 'scripts/capture_native_dependency_evidence.sh').read_text()
        self.assertIn('set -euo pipefail', script)
        self.assertIn('umask 077', script)
        self.assertIn('"$GRADLE_USER_HOME/init.d/flutter-plugin-repositories.init.gradle"', script)
        self.assertIn(':app:dependencies --configuration debugRuntimeClasspath', script)
        self.assertIn(':app:dependencyInsight --configuration debugRuntimeClasspath', script)
        self.assertIn('--dependency com.google.crypto.tink:tink-android', script)
        self.assertEqual(script.count('./gradlew --offline --no-daemon --console=plain'), 3)
        self.assertNotIn('flutter build', script)
        self.assertNotIn('set -x', script)
        self.assertNotIn('--debug', script)
        self.assertNotIn('--scan', script)
        self.assertNotIn('upload-artifact', script)
        result = subprocess.run(['bash', '-n', str(ROOT / 'scripts/capture_native_dependency_evidence.sh')],
                                capture_output=True, check=False)
        self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
