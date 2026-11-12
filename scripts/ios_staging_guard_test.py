#!/usr/bin/env python3
"""Offline policy, evidence, signing-shape and failure-boundary tests; no real keys/accounts."""
import base64
import contextlib
import ctypes
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import urllib.error
import zipfile

import ios_staging_guard as gate
import ios_staging_sign as sign

SHA = 'a' * 40
MERGE = 'b' * 40
TREE = 'c' * 40


def config():
    c = json.loads(gate.CONFIG.read_text())
    c.update(enabled=True, environment='fixture-staging', prevent_self_review=False,
             approved_team_id='ABCDE12345', bundle_id='invalid.fixture.sudanbirds', asc_app_id='1234567890',
             profile_uuid='11111111-1111-4111-8111-111111111111', certificate_sha1='D' * 40,
             uploader_key_id='ABC1234567', uploader_access_reviewed=True,
             uploader_kind='individual', uploader_scope='single_app', uploader_issuer_id=None,
             build_version='0.1.0', build_number='1', staging_limitations_acknowledged=True)
    return c


def team_config():
    c = config()
    c.update(uploader_kind='team', uploader_scope='all_apps',
             uploader_issuer_id='11111111-2222-4333-8444-555555555555')
    return c


def repository():
    return {'full_name': gate.REPO, 'fork': False}


def pull():
    return {'number': 1, 'state': 'open', 'merged': False, 'user': {'login': 'dukkanai'},
            'head': {'sha': SHA, 'ref': 'build/foundation', 'repo': repository()},
            'base': {'sha': '0' * 40, 'ref': 'main', 'repo': repository()}}


def event():
    return {'action': 'labeled', 'repository': repository(), 'pull_request': pull(), 'sender': {'login': 'dukkanai'}}


def env():
    return {'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REPOSITORY': gate.REPO,
            'GITHUB_REF': 'refs/pull/1/merge', 'GITHUB_ACTOR': 'dukkanai', 'GITHUB_TRIGGERING_ACTOR': 'dukkanai',
            'BIRDS_APPROVED_HEAD_SHA': SHA, 'GITHUB_RUN_ATTEMPT': '1'}


def environment():
    return {'name': 'fixture-staging', 'can_admins_bypass': False,
            'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': False,
                                  'reviewers': [{'type': 'User', 'reviewer': {'login': 'dukkanai'}}]}],
            'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True}}


def branches():
    return {'total_count': 1, 'branch_policies': [{'type': 'branch', 'name': 'refs/pull/1/merge'}]}


def run(workflow, id=42):
    return {'id': id, 'run_attempt': 1, 'event': 'pull_request', 'status': 'completed', 'conclusion': 'success',
            'head_sha': SHA, 'head_branch': 'build/foundation', 'head_repository': repository(),
            'repository': repository(), 'path': workflow['path'], 'pull_requests': [{'number': 1}]}


def jobs(workflow):
    return {'total_count': len(workflow['jobs']), 'jobs': [
        {'id': 100 + i, 'name': name, 'status': 'completed', 'conclusion': 'success',
         'steps': [{'name': 'Run actions/checkout@11d5960a326750d5838078e36cf38b85af677262', 'conclusion': 'success',
                    'started_at': '2026-11-11T12:01:00Z', 'completed_at': '2026-11-11T12:02:00Z'}]}
        for i, name in enumerate(workflow['jobs'])]}


def log(sha=MERGE):
    return '2026-11-11T12:01:22.003Z [command]/usr/bin/git log -1 --format=%H\n2026-11-11T12:01:22.004Z ' + sha + '\n'


class ConfigurationTests(unittest.TestCase):
    def test_configured_fixture_passes(self):
        gate.validate_config(config())

    def test_disabled_or_missing_fields_fail(self):
        c = config()
        for field, value in [('enabled', False), ('schema_version', 2), ('environment', None),
                             ('approved_team_id', None), ('bundle_id', 'dev.sudanbirds.sudanBirds'),
                             ('asc_app_id', None), ('uploader_kind', 'team'), ('uploader_role', 'ADMIN'),
                             ('uploader_access_reviewed', False), ('staging_limitations_acknowledged', False),
                             ('xcode_version', '16.4'), ('ios_sdk', '18.5'), ('prevent_self_review', None),
                             ('certificate_sha1', 'D' * 39), ('profile_uuid', '../profile'),
                             ('build_number', '1; env'), ('supabase_url', 'https://example.com'),
                             ('pull_request', 2), ('owner_reviewer', 'someone-else')]:
            with self.subTest(field=field), self.assertRaises(gate.Blocked):
                candidate = deepcopy(c)
                candidate[field] = value
                gate.validate_config(candidate)

    def test_reviewed_team_configuration_passes(self):
        gate.validate_config(team_config())

    def test_credential_scope_and_issuer_combinations_fail_closed(self):
        for c in (config(), team_config()):
            for field, value in [('uploader_kind', None), ('uploader_kind', 'automatic'),
                                 ('uploader_scope', None), ('uploader_scope', 'unrestricted'),
                                 ('uploader_scope', 'single_app' if c['uploader_kind'] == 'team' else 'all_apps'),
                                 ('uploader_access_reviewed', False), ('uploader_role', 'ADMIN'),
                                 ('uploader_issuer_id', ''), ('uploader_issuer_id', 'issuer; env')]:
                with self.subTest(kind=c['uploader_kind'], field=field, value=value), self.assertRaises(gate.Blocked):
                    gate.validate_config(dict(c, **{field: value}))
        for issuer in (None, '00000000-0000-0000-0000-000000000000', 'ABCDE12345',
                       team_config()['uploader_issuer_id'] + '\n'):
            with self.assertRaises(gate.Blocked):
                gate.validate_config(dict(team_config(), uploader_issuer_id=issuer))
        with self.assertRaises(gate.Blocked):
            gate.validate_config(dict(config(), uploader_issuer_id=team_config()['uploader_issuer_id']))
        c = config()
        del c['uploader_issuer_id']
        with self.assertRaises(gate.Blocked):
            gate.validate_config(c)

    def test_changed_ci_definition_is_rejected(self):
        c = config()
        c['ci_workflows'][0]['sha256'] = '0' * 64
        with self.assertRaises(gate.Blocked):
            gate.validate_config(c)

    def test_disabled_guard_performs_no_network(self):
        c = config()
        c['enabled'] = False
        with mock.patch.object(gate.CONFIG.__class__, 'read_text', return_value=json.dumps(c)), mock.patch.object(gate, 'GitHub') as api:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(gate.main(), 1)
            api.assert_not_called()


class EvidenceTests(unittest.TestCase):
    def test_exact_event_and_live_pr(self):
        self.assertEqual(gate.validate_event(config(), event(), env()), SHA)
        gate.validate_current_pr(config(), pull(), SHA)

    def test_wrong_trigger_actor_ref_sha_rerun(self):
        for key, value in [('GITHUB_EVENT_NAME', 'pull_request_target'), ('GITHUB_EVENT_NAME', 'workflow_dispatch'),
                           ('GITHUB_REF', 'refs/heads/main'), ('GITHUB_REPOSITORY', 'evil/sudan-birds'),
                           ('GITHUB_ACTOR', 'dependabot[bot]'), ('GITHUB_TRIGGERING_ACTOR', 'github-actions[bot]'),
                           ('BIRDS_APPROVED_HEAD_SHA', MERGE), ('GITHUB_RUN_ATTEMPT', '2')]:
            with self.subTest(key=key, value=value), self.assertRaises(gate.Blocked):
                e = env()
                e[key] = value
                gate.validate_event(config(), event(), e)

    def test_fork_and_bot_author_and_wrong_branch(self):
        for mutation in ('fork', 'repo', 'author', 'branch', 'pr'):
            e = event()
            if mutation == 'fork': e['pull_request']['head']['repo']['fork'] = True
            if mutation == 'repo': e['pull_request']['head']['repo']['full_name'] = 'evil/sudan-birds'
            if mutation == 'author': e['pull_request']['user']['login'] = 'dependabot[bot]'
            if mutation == 'branch': e['pull_request']['head']['ref'] = 'main'
            if mutation == 'pr': e['pull_request']['number'] = 2
            with self.subTest(mutation=mutation), self.assertRaises(gate.Blocked):
                gate.validate_event(config(), e, env())

    def test_stale_or_closed_current_pr(self):
        for key, value in [('state', 'closed'), ('merged', True)]:
            p = pull()
            p[key] = value
            with self.assertRaises(gate.Blocked): gate.validate_current_pr(config(), p, SHA)
        p = pull()
        p['head']['sha'] = MERGE
        with self.assertRaises(gate.Blocked): gate.validate_current_pr(config(), p, SHA)

    def test_exact_owner_environment(self):
        gate.validate_environment(config(), environment(), branches())

    def test_environment_missing_unknown_bypass_or_other_reviewer(self):
        for mutation in ('bypass', 'missing_bypass', 'reviewer', 'extra_reviewer', 'self_review', 'no_review', 'all_branches'):
            e = environment()
            if mutation == 'bypass': e['can_admins_bypass'] = True
            if mutation == 'missing_bypass': e.pop('can_admins_bypass')
            if mutation == 'reviewer': e['protection_rules'][0]['reviewers'][0]['reviewer']['login'] = 'other'
            if mutation == 'extra_reviewer': e['protection_rules'][0]['reviewers'].append({'type': 'Team'})
            if mutation == 'self_review': e['protection_rules'][0]['prevent_self_review'] = True
            if mutation == 'no_review': e['protection_rules'] = []
            if mutation == 'all_branches': e['deployment_branch_policy'] = None
            with self.subTest(mutation=mutation), self.assertRaises(gate.Blocked):
                gate.validate_environment(config(), e, branches())

    def test_no_wildcard_tag_or_extra_branch(self):
        for name in ('refs/pull/*/merge', 'build/foundation', 'main', 'refs/pull/2/merge'):
            b = branches()
            b['branch_policies'][0]['name'] = name
            with self.assertRaises(gate.Blocked): gate.validate_environment(config(), environment(), b)
        for mutation in ('type', 'count'):
            b = branches()
            if mutation == 'type': b['branch_policies'][0]['type'] = 'tag'
            else: b['total_count'] = 2
            with self.assertRaises(gate.Blocked): gate.validate_environment(config(), environment(), b)

    def test_run_binds_sha_attempt_event_path_and_pr(self):
        w = config()['ci_workflows'][0]
        gate.validate_run(run(w), w, SHA, 42, 1)
        for key, value in [('head_sha', MERGE), ('run_attempt', 2), ('event', 'push'), ('conclusion', 'neutral'),
                           ('status', 'in_progress'), ('path', '.github/workflows/fake.yml'), ('pull_requests', [])]:
            r = run(w)
            r[key] = value
            with self.subTest(key=key), self.assertRaises(gate.Blocked): gate.validate_run(r, w, SHA, 42, 1)

    def test_all_jobs_required_and_successful(self):
        w = config()['ci_workflows'][0]
        gate.validate_jobs(jobs(w), w)
        for result in ('skipped', 'neutral', 'cancelled', 'failure', None):
            j = jobs(w)
            j['jobs'][0]['conclusion'] = result
            with self.assertRaises(gate.Blocked): gate.validate_jobs(j, w)
        j = jobs(w)
        j['jobs'].pop()
        with self.assertRaises(gate.Blocked): gate.validate_jobs(j, w)

    def test_checkout_log_not_merely_metadata_or_artifact_name(self):
        self.assertEqual(gate.checkout_sha(log(), jobs(config()['ci_workflows'][0])['jobs'][0]['steps'][0]), MERGE)
        for text in ('artifact-' + MERGE, log() + log(), log().replace(MERGE, 'malformed'),
                     log().replace('git log -1 --format=%H', 'echo ' + MERGE)):
            with self.assertRaises(gate.Blocked): gate.checkout_sha(text, jobs(config()['ci_workflows'][0])['jobs'][0]['steps'][0])

    def test_checkout_sha_must_be_inside_successful_step_window(self):
        step = jobs(config()['ci_workflows'][0])['jobs'][0]['steps'][0]
        later = log().replace('12:01:22', '13:01:22')
        with self.assertRaises(gate.Blocked): gate.checkout_sha(later, step)
        with self.assertRaises(gate.Blocked): gate.checkout_sha(log(), {})
        self.assertEqual(gate.checkout_sha(log() + later, step), MERGE)

    def live_fixture(self, changed_tree=False, late_push=False):
        c = config()
        e = env()
        selections = {w['path']: {'id': i + 1, 'attempt': 1} for i, w in enumerate(c['ci_workflows'])}
        e['BIRDS_CI_RUNS_JSON'] = json.dumps(selections)
        counter = 0
        def get(path, log=False):
            nonlocal counter
            if path.endswith('/pulls/1'):
                counter += 1
                p = pull()
                if late_push and counter == 2: p['head']['sha'] = MERGE
                return p
            if 'deployment-branch-policies' in path: return branches()
            if '/environments/' in path: return environment()
            if '/git/commits/' in path:
                return {'tree': {'sha': 'd' * 40 if changed_tree and path.endswith(MERGE) else TREE}}
            if log: return globals()['log']()
            match = re.search(r'/actions/runs/(\d+)', path)
            w = c['ci_workflows'][int(match[1]) - 1]
            return jobs(w) if '/jobs?' in path else run(w, int(match[1]))
        api = mock.Mock()
        api.get.side_effect = get
        return c, e, api

    @mock.patch.object(gate.subprocess, 'run', return_value=mock.Mock(returncode=0))
    @mock.patch.object(gate.subprocess, 'check_output', return_value=SHA + '\n')
    def test_complete_live_gate_accepts_equal_trees_only(self, *_):
        c, e, api = self.live_fixture()
        self.assertEqual(gate.live_gate(c, event(), e, api), SHA)
        self.assertEqual(sum(call.kwargs.get('log', False) for call in api.get.call_args_list), 8)
        for changed, late in [(True, False), (False, True)]:
            c, e, api = self.live_fixture(changed, late)
            with self.assertRaises(gate.Blocked): gate.live_gate(c, event(), e, api)

    def test_unknown_log_redirect_is_blocked(self):
        api = gate.GitHub('synthetic-token')
        api.opener = mock.Mock()
        api.opener.open.side_effect = urllib.error.HTTPError('https://api.github.com', 302, '',
                                                            {'Location': 'https://attacker.example/log'}, None)
        with self.assertRaises(gate.Blocked): api.get('/repos/' + gate.REPO + '/actions/jobs/1/logs', log=True)
        self.assertEqual(api.opener.open.call_count, 1)

    def test_blob_redirect_does_not_receive_token(self):
        api = gate.GitHub('synthetic-token')
        response = mock.MagicMock()
        response.read.return_value = log().encode()
        api.opener = mock.Mock()
        api.opener.open.side_effect = [urllib.error.HTTPError('https://api.github.com', 302, '',
                                        {'Location': 'https://fixture.blob.core.windows.net/log?fixture=1'}, None), response]
        self.assertEqual(api.get('/repos/' + gate.REPO + '/actions/jobs/1/logs', log=True), log())
        second = api.opener.open.call_args_list[1].args[0]
        self.assertFalse(second.has_header('Authorization'))


class SigningTests(unittest.TestCase):
    def profile(self):
        c = config()
        cert = b'synthetic-public-certificate-bytes'
        c['certificate_sha1'] = hashlib.sha1(cert).hexdigest().upper()
        p = {'UUID': c['profile_uuid'], 'TeamIdentifier': [c['approved_team_id']],
             'ApplicationIdentifierPrefix': [c['approved_team_id']],
             'ExpirationDate': datetime.now(timezone.utc) + timedelta(days=3), 'DeveloperCertificates': [cert],
             'Entitlements': {'application-identifier': c['approved_team_id'] + '.' + c['bundle_id'],
                              'com.apple.developer.team-identifier': c['approved_team_id'], 'get-task-allow': False}}
        return c, p

    def test_profile_exact_match(self):
        c, p = self.profile()
        sign.validate_profile(p, c, time.time())

    def test_profile_wrong_team_app_expiry_certificate_or_kind(self):
        for mutation in ('team', 'app', 'expiry', 'cert', 'devices', 'enterprise', 'debug', 'uuid'):
            c, p = self.profile()
            if mutation == 'team': p['TeamIdentifier'] = ['OTHER12345']
            if mutation == 'app': p['Entitlements']['application-identifier'] = c['approved_team_id'] + '.*'
            if mutation == 'expiry': p['ExpirationDate'] = datetime.now(timezone.utc)
            if mutation == 'cert': p['DeveloperCertificates'] = []
            if mutation == 'devices': p['ProvisionedDevices'] = ['fixture']
            if mutation == 'enterprise': p['ProvisionsAllDevices'] = True
            if mutation == 'debug': p['Entitlements']['get-task-allow'] = True
            if mutation == 'uuid': p['UUID'] = 'other'
            with self.subTest(mutation=mutation), self.assertRaises(gate.Blocked): sign.validate_profile(p, c, time.time())

    def test_uploader_sees_only_exact_app(self):
        c = config()
        body = {'data': [{'type': 'apps', 'id': c['asc_app_id'], 'attributes': {'bundleId': c['bundle_id']}}], 'links': {}}
        sign.validate_apps(body, c)
        for mutation in ('extra', 'next', 'wrong', 'empty'):
            b = deepcopy(body)
            if mutation == 'extra': b['data'] *= 2
            if mutation == 'next': b['links']['next'] = 'more'
            if mutation == 'wrong': b['data'][0]['id'] = '9999999999'
            if mutation == 'empty': b['data'] = []
            with self.assertRaises(gate.Blocked): sign.validate_apps(b, c)

    def test_team_reads_exact_target_without_claiming_single_app_access(self):
        c = team_config()
        self.assertEqual(sign.apps_path(c), '/v1/apps/' + c['asc_app_id'])
        self.assertEqual(sign.apps_path(config()), '/v1/apps?limit=200')
        app = {'type': 'apps', 'id': c['asc_app_id'], 'attributes': {'bundleId': c['bundle_id']}}
        sign.validate_apps({'data': app}, c)
        for wrong in (None, [], [app], dict(app, id='9999999999'), dict(app, type='builds'),
                      dict(app, attributes={'bundleId': 'invalid.other.app'})):
            with self.assertRaises(gate.Blocked):
                sign.validate_apps({'data': wrong}, c)

    def test_auth_flags_are_explicit_and_help_is_exact(self):
        for c in (config(), team_config()):
            auth = sign.uploader_auth(c)
            self.assertEqual(auth[:2], ['--api-key', c['uploader_key_id']])
            self.assertEqual(auth[2:], ['--api-issuer', c['uploader_issuer_id']] if c['uploader_kind'] == 'team'
                             else ['--api-key-subject', 'user'])
            flags = auth[::2] + ['--upload-package', '--wait']
            sign.validate_uploader_help(' '.join(flags), c)
            for flag in flags:
                with self.assertRaises(gate.Blocked):
                    sign.validate_uploader_help(' '.join(flags).replace(flag, flag + '-other'), c)
        with self.assertRaises(gate.Blocked):
            sign.validate_uploader_help('--apiKey --apiIssuer --upload-package --wait', team_config())

    def test_both_paths_upload_only_approved_identity_once_and_reject_existing_build(self):
        for c in (config(), team_config()):
            app = {'type': 'apps', 'id': c['asc_app_id'], 'attributes': {'bundleId': c['bundle_id']}}
            body = {'data': app if c['uploader_kind'] == 'team' else [app]}
            for scenario in ('accepted', 'wrong_app', 'existing', 'paged', 'timeout', 'nonzero'):
                with self.subTest(kind=c['uploader_kind'], scenario=scenario), tempfile.TemporaryDirectory() as folder:
                    invocation = sign.Invocation(c, {'RUNNER_TEMP': folder})
                    invocation.write = mock.Mock(return_value=Path(folder) / 'synthetic.p8')
                    invocation.run = mock.Mock(return_value=b'')
                    if scenario == 'timeout': invocation.run.side_effect = subprocess.TimeoutExpired('private', 1)
                    if scenario == 'nonzero': invocation.run.side_effect = gate.Blocked('Private upload failed.')
                    apps = deepcopy(body)
                    if scenario == 'wrong_app':
                        (apps['data'] if c['uploader_kind'] == 'team' else apps['data'][0])['id'] = '9999999999'
                    before = {'data': []}
                    if scenario == 'existing': before['data'] = [{'type': 'builds'}]
                    if scenario == 'paged': before['links'] = {'next': 'more'}
                    with mock.patch.object(sign, 'make_uploader_jwt', return_value='synthetic'), \
                            mock.patch.object(sign, 'apple_get', side_effect=[apps, before, {'data': []}]) as read:
                        private = {'BIRDS_ASC_P8_BASE64': base64.b64encode(b'synthetic').decode()}
                        if scenario == 'accepted':
                            invocation.upload_verified_ipa(private, Path(folder) / 'verified.ipa')
                        else:
                            with self.assertRaises((gate.Blocked, subprocess.TimeoutExpired)):
                                invocation.upload_verified_ipa(private, Path(folder) / 'verified.ipa')
                    self.assertEqual(read.call_args_list[0].args[0], sign.apps_path(c))
                    if scenario in ('wrong_app', 'existing', 'paged'):
                        invocation.run.assert_not_called()
                        self.assertFalse(invocation.upload_started)
                        self.assertEqual(invocation.status, 'not_uploaded')
                    else:
                        invocation.run.assert_called_once()
                        command = invocation.run.call_args.args[0]
                        for flag, value in [('--apple-id', c['asc_app_id']), ('--bundle-id', c['bundle_id']),
                                            ('--bundle-version', c['build_number']),
                                            ('--bundle-short-version-string', c['build_version'])]:
                            self.assertEqual(command[command.index(flag) + 1], value)
                        self.assertEqual(command[-7:-3], sign.uploader_auth(c))
                        self.assertEqual(invocation.status, 'upload_accepted_processing_unverified' if scenario == 'accepted'
                                         else 'upload_outcome_uncertain')
                    self.assertEqual(invocation.cleanup(), [])

    def test_exported_signature_entitlements_are_exact(self):
        c = config()
        app_id = c['approved_team_id'] + '.' + c['bundle_id']
        ent = {'application-identifier': app_id, 'com.apple.developer.team-identifier': c['approved_team_id'],
               'get-task-allow': False, 'keychain-access-groups': [app_id], 'beta-reports-active': True}
        sign.validate_signed_entitlements(ent, c)
        for key, value in [('get-task-allow', True), ('keychain-access-groups', ['*']),
                           ('com.apple.developer.team-identifier', 'OTHER12345'),
                           ('application-identifier', app_id + '.other'), ('aps-environment', 'production')]:
            changed = deepcopy(ent)
            changed[key] = value
            with self.assertRaises(gate.Blocked): sign.validate_signed_entitlements(changed, c)

    def test_exported_manifest_binds_identity_version_and_sdk(self):
        c = config()
        info = {'CFBundleIdentifier': c['bundle_id'], 'CFBundleVersion': c['build_number'],
                'CFBundleShortVersionString': c['build_version'], 'DTXcodeBuild': c['xcode_build'],
                'DTSDKName': 'iphoneos' + c['ios_sdk']}
        sign.validate_archive_info(info, c)
        for key in info:
            changed = deepcopy(info)
            changed[key] = 'unexpected'
            with self.assertRaises(gate.Blocked): sign.validate_archive_info(changed, c)

    def test_ipa_extraction_rejects_traversal_duplicate_symlink_and_oversize(self):
        safe = zipfile.ZipInfo('Payload/Runner.app/Info.plist')
        sign.validate_zip_members([safe])
        for name in ('../escape', '/absolute', 'Payload/../../escape', 'Payload/evil\\path'):
            with self.assertRaises(gate.Blocked): sign.validate_zip_members([zipfile.ZipInfo(name)])
        with self.assertRaises(gate.Blocked): sign.validate_zip_members([safe, safe])
        symlink = zipfile.ZipInfo('Payload/Runner.app/link')
        symlink.external_attr = 0o120777 << 16
        with self.assertRaises(gate.Blocked): sign.validate_zip_members([symlink])
        huge = zipfile.ZipInfo('Payload/Runner.app/huge')
        huge.file_size = 3 * 1024**3
        with self.assertRaises(gate.Blocked): sign.validate_zip_members([huge])

    def test_child_environment_never_inherits_secret_or_github_token(self):
        source = {'PATH': '/usr/bin', 'HOME': '/tmp', 'GH_TOKEN': 'fixture', 'GITHUB_TOKEN': 'fixture',
                  **{name: 'fixture' for name in sign.SECRET_NAMES}}
        self.assertEqual(sign.child_environment(source), {'PATH': '/usr/bin', 'HOME': '/tmp'})

    def test_decoding_and_safe_summary(self):
        self.assertEqual(sign.decode_secret(base64.b64encode(b'fixture').decode()), b'fixture')
        with self.assertRaises(gate.Blocked): sign.decode_secret('not valid base64!')
        for bad in ('private-key-value', '<html>'):
            with self.assertRaises(gate.Blocked): sign.summarize(bad, None, 'not_uploaded')
        result = sign.summarize(SHA, 'f' * 64, 'upload_outcome_uncertain')
        self.assertFalse(result['production_release'])
        self.assertEqual(result['internal_tester_delivery'], 'not_verified')

    def test_der_parser_rejects_invalid_signatures(self):
        self.assertEqual(sign.der_to_jose(bytes.fromhex('3006020101020102')), bytes(31) + b'\x01' + bytes(31) + b'\x02')
        for value in ('', '3006020100020102', '3006020180020102', '300702020001020102', '300602010102010200'):
            with self.assertRaises(gate.Blocked): sign.der_to_jose(bytes.fromhex(value))

    def test_synthetic_individual_jwt_is_verified_by_openssl(self):
        self.verify_synthetic_jwt(config(), {'sub': 'user'})

    def test_synthetic_team_jwt_is_verified_by_openssl(self):
        self.verify_synthetic_jwt(team_config(), {'iss': team_config()['uploader_issuer_id']})

    def verify_synthetic_jwt(self, c, claims):
        with tempfile.TemporaryDirectory(prefix='birds-jwt-test-') as folder:
            folder = Path(folder)
            key = folder / 'fixture.key'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', str(key)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            def run(command, stage, input_bytes=None):
                command = ['openssl'] + command[1:]
                return subprocess.run(command, input=input_bytes, check=True, capture_output=True).stdout
            jwt = sign.make_uploader_jwt(c, key, run, 1000)
            header, payload, signature = jwt.split('.')
            body = json.loads(base64.urlsafe_b64decode(payload + '=='))
            self.assertEqual(body, dict(claims, iat=1000, exp=1120, aud='appstoreconnect-v1'))
            raw = base64.urlsafe_b64decode(signature + '==')
            def integer(value):
                value = value.lstrip(b'\x00') or b'\x00'
                if value[0] >= 128: value = b'\x00' + value
                return b'\x02' + bytes([len(value)]) + value
            components = integer(raw[:32]) + integer(raw[32:])
            sig = folder / 'signature.der'
            sig.write_bytes(b'\x30' + bytes([len(components)]) + components)
            public = folder / 'fixture.pub'
            public.write_bytes(run(['openssl', 'pkey', '-in', str(key), '-pubout'], 'test'))
            checked = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public), '-signature', str(sig)],
                                     input=(header + '.' + payload).encode(), capture_output=True)
            self.assertEqual(checked.returncode, 0)

    def test_cleanup_attempts_every_owned_resource(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(config(), {'RUNNER_TEMP': folder, 'PATH': '/usr/bin', 'HOME': folder})
            invocation.original_keychains = ['original.keychain']
            invocation.search_changed = invocation.keychain_created = True
            profile = Path(folder) / 'owned.mobileprovision'
            profile.write_text('fixture')
            other = Path(folder) / 'unrelated.mobileprovision'
            other.write_text('keep')
            invocation.profile_path = profile
            invocation.run = mock.Mock(side_effect=gate.Blocked('fixture cleanup error'))
            self.assertEqual(invocation.cleanup(), ['keychain-search', 'temporary-keychain'])
            self.assertEqual(invocation.run.call_count, 2)
            self.assertFalse(profile.exists())
            self.assertTrue(other.exists())
            self.assertFalse(invocation.path.exists())

    def test_primary_failure_and_uncertain_upload_survive_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            e = Path(folder) / 'event.json'
            e.write_text('{}')
            invocation = mock.Mock(status='upload_outcome_uncertain', digest='f' * 64)
            invocation.execute.side_effect = gate.Blocked('fixture primary failure')
            invocation.cleanup.return_value = ['temporary-keychain']
            runtime = {'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_RUN_ID': '123',
                       'BIRDS_APPROVED_UPLOAD_RUN_ID': '123', 'GITHUB_EVENT_PATH': str(e),
                       **{name: 'fixture' for name in sign.SECRET_NAMES}}
            with mock.patch.dict(os.environ, runtime, clear=True), mock.patch.object(sign.sys, 'platform', 'darwin'), \
                    mock.patch.object(sign, 'CONFIG') as cp, mock.patch.object(sign, 'live_gate', return_value=SHA), \
                    mock.patch.object(sign, 'GitHub'), mock.patch.object(sign, 'Invocation', return_value=invocation), \
                    mock.patch.object(sign.signal, 'signal'), contextlib.redirect_stdout(io.StringIO()) as stdout, \
                    contextlib.redirect_stderr(io.StringIO()) as stderr:
                cp.read_text.return_value = json.dumps(config())
                self.assertEqual(sign.main(), 1)
                self.assertIn('fixture primary failure', stderr.getvalue())
                self.assertIn('upload_outcome_uncertain', stdout.getvalue())
                self.assertIn('before any retry', stderr.getvalue())
                invocation.cleanup.assert_called_once()


    def test_cleanup_runs_before_summary_failure_without_erasing_primary_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            e = Path(folder) / 'event.json'
            e.write_text('{}')
            invocation = mock.Mock(status='not_uploaded', digest=None)
            invocation.execute.side_effect = gate.Blocked('primary operation failed')
            invocation.cleanup.return_value = []
            runtime = {'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_RUN_ID': '123',
                       'BIRDS_APPROVED_UPLOAD_RUN_ID': '123', 'GITHUB_EVENT_PATH': str(e),
                       'GITHUB_STEP_SUMMARY': str(Path(folder) / 'absent' / 'summary'),
                       **{name: 'fixture' for name in sign.SECRET_NAMES}}
            with mock.patch.dict(os.environ, runtime, clear=True), mock.patch.object(sign.sys, 'platform', 'darwin'), \
                    mock.patch.object(sign, 'CONFIG') as cp, mock.patch.object(sign, 'live_gate', return_value=SHA), \
                    mock.patch.object(sign, 'GitHub'), mock.patch.object(sign, 'Invocation', return_value=invocation), \
                    mock.patch.object(sign.signal, 'signal') as signals, contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()) as stderr:
                cp.read_text.return_value = json.dumps(config())
                self.assertEqual(sign.main(), 1)
                self.assertIn('primary operation failed', stderr.getvalue())
                self.assertIn('cleanup already ran', stderr.getvalue())
                invocation.cleanup.assert_called_once()
                signals.assert_any_call(sign.signal.SIGTERM, sign.signal.SIG_IGN)

    def test_timeout_preserved_when_group_shutdown_is_unconfirmed(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(config(), {'RUNNER_TEMP': folder, 'PATH': '/usr/bin', 'HOME': folder})
            process = mock.Mock(pid=12345)
            original = subprocess.TimeoutExpired('fixture', 1)
            process.communicate.side_effect = original
            with mock.patch.object(sign.subprocess, 'Popen', return_value=process), \
                    mock.patch.object(sign, 'terminate_process_group', return_value=False) as stop:
                with self.assertRaises(subprocess.TimeoutExpired) as caught:
                    invocation.run(['fixture'], 'fixture', timeout=1)
                self.assertIs(caught.exception, original)
                stop.assert_called_once_with(process)
            self.assertEqual(invocation.cleanup(), ['private-process-group-unconfirmed'])

    def test_nonzero_primary_failure_preserved_if_group_shutdown_is_unconfirmed(self):
        with tempfile.TemporaryDirectory() as folder:
            invocation = sign.Invocation(config(), {'RUNNER_TEMP': folder, 'PATH': '/usr/bin', 'HOME': folder})
            process = mock.Mock(pid=12345, returncode=7)
            with mock.patch.object(sign.subprocess, 'Popen', return_value=process), \
                    mock.patch.object(sign, 'terminate_process_group', return_value=False) as stop:
                with self.assertRaisesRegex(gate.Blocked, 'Private tool failed at fixture'):
                    invocation.run(['fixture'], 'fixture')
                stop.assert_called_once_with(process)
            self.assertEqual(invocation.cleanup(), ['private-process-group-unconfirmed'])

    def test_dead_leader_does_not_suppress_group_sigkill_and_wait_is_bounded(self):
        process = mock.Mock(pid=12345, returncode=7)
        with mock.patch.object(sign.os, 'killpg') as kill, mock.patch.object(sign.signal, 'signal'), \
                mock.patch.object(sign, 'GROUP_TERM_SECONDS', 0), mock.patch.object(sign, 'GROUP_KILL_SECONDS', 0):
            self.assertFalse(sign.terminate_process_group(process))
        kill.assert_any_call(12345, sign.signal.SIGTERM)
        kill.assert_any_call(12345, sign.signal.SIGKILL)
        process.wait.assert_not_called()  # No unbounded wait(), even after SIGKILL.
        self.assertLessEqual(kill.call_count, 8)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Synthetic orphan reaping uses Linux subreaper support')
    def test_real_term_ignoring_child_stops_after_timeout_nonzero_and_success(self):
        # The container's PID 1 need not reap orphan zombies. Act as a subreaper only
        # in this test process and reap the exact fixture child, never unrelated children.
        libc = ctypes.CDLL(None, use_errno=True)
        old = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(old), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        source = """
import os, signal, sys, time
from pathlib import Path
pid_path = Path(sys.argv[1])
child = os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    pid_path.write_text(str(os.getpid()))
    while True:
        time.sleep(1)
while not pid_path.exists():
    time.sleep(0.01)
if sys.argv[2] == 'timeout':
    time.sleep(30)
os._exit(7 if sys.argv[2] == 'nonzero' else 0)
"""
        try:
            for mode in ('timeout', 'nonzero', 'success'):
                with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                    invocation = sign.Invocation(config(), {'RUNNER_TEMP': folder, 'PATH': '/usr/bin', 'HOME': folder})
                    pid_path = Path(folder) / 'child.pid'
                    stop_reaper = threading.Event()
                    reaped = threading.Event()
                    def reap_fixture():
                        while not stop_reaper.is_set():
                            if pid_path.exists():
                                try:
                                    pid = int(pid_path.read_text())
                                    waited, _ = os.waitpid(pid, os.WNOHANG)
                                    if waited == pid:
                                        reaped.set()
                                        return
                                except (ValueError, ChildProcessError):
                                    pass
                            time.sleep(0.01)
                    reaper = threading.Thread(target=reap_fixture, daemon=True)
                    reaper.start()
                    try:
                        with mock.patch.object(sign, 'GROUP_TERM_SECONDS', 0.1), \
                                mock.patch.object(sign, 'GROUP_KILL_SECONDS', 2):
                            command = [sys.executable, '-c', source, str(pid_path), mode]
                            if mode == 'timeout':
                                with self.assertRaises(subprocess.TimeoutExpired): invocation.run(command, 'fixture', timeout=0.3)
                            elif mode == 'nonzero':
                                with self.assertRaisesRegex(gate.Blocked, 'Private tool failed at fixture'):
                                    invocation.run(command, 'fixture', timeout=2)
                            else:
                                self.assertEqual(invocation.run(command, 'fixture', timeout=2), b'')
                        self.assertTrue(reaped.wait(2), 'TERM-ignoring child survived or was not reaped')
                        self.assertEqual(invocation.unconfirmed_process_groups, set())
                        child = int(pid_path.read_text())
                        with self.assertRaises(ProcessLookupError): os.kill(child, 0)
                    finally:
                        # A regression must not strand the synthetic child itself.
                        if pid_path.exists() and not reaped.is_set():
                            try: os.kill(int(pid_path.read_text()), sign.signal.SIGKILL)
                            except ProcessLookupError: pass
                            reaped.wait(2)
                        stop_reaper.set()
                        reaper.join(2)
                        self.assertEqual(invocation.cleanup(), [])
        finally:
            self.assertEqual(libc.prctl(36, old.value, 0, 0, 0), 0)


class TemplateTests(unittest.TestCase):
    def test_inert_template_policy(self):
        p = gate.ROOT / 'docs/examples/ios-staging/workflow.yml.example'
        text = p.read_text()
        self.assertNotIn('.github/workflows', str(p.relative_to(gate.ROOT).parent))
        self.assertNotRegex(text, r'^\s*(?:workflow_dispatch|pull_request_target|push):')
        self.assertNotIn('secrets: inherit', text)
        self.assertNotIn('permissions: write-all', text)
        self.assertNotIn('cancel-in-progress: true', text)
        self.assertNotRegex(text, r'uses: actions/(?:upload-artifact|cache|upload-release-asset)@')
        uses = re.findall(r'uses:\s*([^\s]+)', text)
        self.assertTrue(all(re.fullmatch(r'[\w/-]+@[a-f0-9]{40}', u) for u in uses))
        self.assertEqual(text.count('persist-credentials: false'), 2)
        self.assertEqual(text.count('secrets.'), 4)
        self.assertIn('ref: ${{ needs.preflight.outputs.source_sha }}', text)
        self.assertIn('name: ${{ needs.preflight.outputs.environment }}', text)
        self.assertIn('cache: false', text)

    def test_checked_in_configuration_remains_inert_and_unconfigured(self):
        c = json.loads(gate.CONFIG.read_text())
        self.assertIs(c['enabled'], False)
        self.assertIs(c['uploader_access_reviewed'], False)
        for field in ('environment', 'approved_team_id', 'bundle_id', 'asc_app_id',
                      'profile_uuid', 'certificate_sha1', 'uploader_key_id', 'uploader_kind',
                      'uploader_scope', 'uploader_issuer_id', 'build_version', 'build_number'):
            self.assertIsNone(c[field], field)
        self.assertFalse((gate.ROOT / '.github/workflows/ios-staging.yml').exists())
        self.assertEqual(sign.SECRET_NAMES[-1], 'BIRDS_ASC_P8_BASE64')

    def test_existing_beta_release_remain_fail_closed(self):
        for name in ('beta.yml', 'release.yml'):
            text = (gate.ROOT / '.github/workflows' / name).read_text()
            self.assertIn('exit 1', text)
            self.assertNotIn('secrets.', text)
            self.assertNotIn('ios_staging_sign', text)

    def test_signer_has_no_automatic_provisioning_or_upload_retry(self):
        source = (gate.ROOT / 'scripts/ios_staging_sign.py').read_text()
        self.assertNotIn('-allowProvisioningUpdates', source)
        self.assertNotIn('-allowProvisioningDeviceRegistration', source)
        self.assertEqual(source.count("'--upload-package', str(ipa)"), 1)
        self.assertIn("'testFlightInternalTestingOnly': True", source)
        self.assertIn("'destination': 'export'", source)
        self.assertNotIn('upload_to_app_store', source)
        self.assertNotIn('shell=True', source)


if __name__ == '__main__':
    unittest.main()
