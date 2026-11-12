"""Offline fixtures only; no GitHub credential or network access."""
import contextlib
from copy import deepcopy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ios_staging_access_probe as p


def fixtures():
    env = {'name': p.ENVIRONMENT, 'can_admins_bypass': False,
           'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': False,
                                 'reviewers': [{'type': 'User', 'reviewer': {'login': 'dukkanai'}}]}],
           'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True}}
    branches = {'total_count': 1, 'branch_policies': [{'name': 'refs/pull/1/merge', 'type': 'branch'}]}
    job = {'id': p.JOB_ID, 'run_id': p.RUN_ID, 'name': 'repository-security',
           'status': 'completed', 'conclusion': 'success', 'steps': [{
               'name': 'Run actions/checkout@11d5960a326750d5838078e36cf38b85af677262',
               'conclusion': 'success', 'started_at': '2026-11-12T14:00:00Z',
               'completed_at': '2026-11-12T14:00:02Z'}]}
    log = ('2026-11-12T14:00:01Z [command]/usr/bin/git log -1 --format=%H\n'
           '2026-11-12T14:00:01Z ' + p.CHECKOUT + '\n')
    return [env, branches, job, log]


class API:
    def __init__(self, values):
        self.values, self.calls = values, []

    def get(self, path, log=False):
        self.calls.append((path, log))
        result = self.values[len(self.calls) - 1]
        if isinstance(result, Exception):
            raise result
        return result


class ProbeTests(unittest.TestCase):
    def run_probe(self, values):
        report = {key: 'not_run' for key in p.FIELDS}
        report['context'] = 'passed'
        api = API(values)
        p.probe(api, report)
        return report, api

    def test_success_and_exact_four_read_endpoints(self):
        report, api = self.run_probe(fixtures())
        self.assertTrue(all(report[k] == 'passed' for k in p.FIELDS))
        self.assertTrue(report['bypass_field_present'])
        self.assertEqual(api.calls, [
            (p.PREFIX + '/environments/' + p.ENVIRONMENT, False),
            (p.PREFIX + '/environments/' + p.ENVIRONMENT + '/deployment-branch-policies?per_page=100', False),
            (p.PREFIX + '/actions/jobs/' + str(p.JOB_ID), False),
            (p.PREFIX + '/actions/jobs/' + str(p.JOB_ID) + '/logs', True)])

    def test_missing_bypass_field_blocks_without_guessing(self):
        values = fixtures()
        del values[0]['can_admins_bypass']
        report, _ = self.run_probe(values)
        self.assertFalse(report['bypass_field_present'])
        self.assertEqual(report['environment_policy'], 'blocked')
        self.assertEqual(report['checkout_evidence'], 'passed')

    def test_policy_changes_block(self):
        for change in [lambda x: x[0].update(can_admins_bypass=True),
                       lambda x: x[1]['branch_policies'][0].update(name='*'),
                       lambda x: x[0]['protection_rules'][0].update(prevent_self_review=True)]:
            values = fixtures()
            change(values)
            with self.subTest(change=change):
                self.assertEqual(self.run_probe(values)[0]['environment_policy'], 'blocked')

    def test_denied_reads_are_fixed_statuses_without_raw_details(self):
        for i in range(4):
            values = fixtures()
            values[i] = RuntimeError('sensitive-fixture-never-echo')
            report, _ = self.run_probe(values)
            self.assertNotIn('sensitive-fixture', json.dumps(report))
            self.assertFalse(all(report[k] == 'passed' for k in p.FIELDS))

    def test_wrong_job_is_not_followed_to_logs(self):
        values = fixtures()
        values[2]['run_id'] += 1
        report, api = self.run_probe(values)
        self.assertEqual(len(api.calls), 3)
        self.assertEqual(report['job_identity'], 'blocked')
        self.assertEqual(report['log_read'], 'not_run')

    def test_malformed_or_wrong_checkout_blocks(self):
        for log in ['private-response', fixtures()[3].replace(p.CHECKOUT, 'b' * 40)]:
            values = fixtures()
            values[3] = log
            self.assertEqual(self.run_probe(values)[0]['checkout_evidence'], 'blocked')

    def context(self):
        env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': p.REPO,
               'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REF': 'refs/pull/1/merge',
               'GITHUB_ACTOR': 'dukkanai', 'GITHUB_TRIGGERING_ACTOR': 'dukkanai',
               'GITHUB_RUN_ATTEMPT': '1', 'RUNNER_ENVIRONMENT': 'github-hosted',
               'BIRDS_ENABLE_ACCESS_PROBE': 'true', 'BIRDS_ACCESS_PROBE_HEAD_SHA': 'a' * 40}
        repo = {'full_name': p.REPO, 'fork': False}
        event = {'action': 'labeled', 'label': {'name': 'question'}, 'repository': repo,
                 'pull_request': {'number': 1, 'state': 'open',
                                  'head': {'sha': 'a' * 40, 'ref': 'build/foundation', 'repo': repo},
                                  'base': {'ref': 'main', 'repo': repo}}}
        return env, event

    def test_context_owner_head_attempt_and_gate(self):
        env, event = self.context()
        self.assertTrue(p.valid_context(env, event))
        for key in env:
            bad = dict(env, **{key: 'wrong'})
            with self.subTest(key=key):
                self.assertFalse(p.valid_context(bad, event))
        for change in [lambda x: x.update(action='synchronize'),
                       lambda x: x['label'].update(name='enhancement'),
                       lambda x: x['pull_request'].update(number=True),
                       lambda x: x['pull_request']['head']['repo'].update(fork=True),
                       lambda x: x['pull_request']['head'].update(sha='b' * 40)]:
            bad = deepcopy(event)
            change(bad)
            self.assertFalse(p.valid_context(env, bad))

    def test_main_fail_closed_before_network_and_sanitizes_errors(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(p, 'GitHub') as client:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(p.main(), 1)
            client.assert_not_called()
            self.assertEqual(json.loads(out.getvalue())['context'], 'blocked')

    def test_main_success_with_fake_api_and_bounded_event_file(self):
        env, event = self.context()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'event.json'
            path.write_text(json.dumps(event))
            env.update(GITHUB_EVENT_PATH=str(path), GH_TOKEN='synthetic-not-a-real-token')
            with patch.dict(os.environ, env, clear=True), patch.object(p, 'GitHub', return_value=API(fixtures())):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(p.main(), 0)
                self.assertNotIn('synthetic', out.getvalue())
            path.write_bytes(b'x' * 2_000_001)
            with patch.dict(os.environ, env, clear=True), patch.object(p, 'GitHub') as client:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(p.main(), 1)
                client.assert_not_called()

    def test_workflow_never_has_environment_secrets_or_writes(self):
        text = (Path(__file__).resolve().parents[1] / '.github/workflows/staging-access-probe.yml').read_text()
        for prohibited in ['${{ secrets.', 'environment:', 'write', 'upload-artifact', 'workflow_dispatch', 'pull_request_target']:
            self.assertNotIn(prohibited, text)
        self.assertIn('persist-credentials: false', text)
        self.assertIn('BIRDS_ENABLE_ACCESS_PROBE', text)


if __name__ == '__main__':
    unittest.main()
