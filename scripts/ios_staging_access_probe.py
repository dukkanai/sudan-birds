#!/usr/bin/env python3
"""Bounded, read-only API capability diagnostic; no signing or service secrets."""
import json
import os
from pathlib import Path
import re
import sys

from ios_staging_guard import GitHub, REPO, checkout_sha, validate_environment

ENVIRONMENT = 'sudan-birds-ios-staging'
JOB_ID = 131231183815
RUN_ID = 43232491842
CHECKOUT = '542aa22d970e0219fbf329e16c77067e10f2bab8'
PREFIX = '/repos/' + REPO
POLICY = {'environment': ENVIRONMENT, 'owner_reviewer': 'dukkanai',
          'prevent_self_review': False}
FIELDS = ('context', 'environment_read', 'branches_read', 'environment_policy',
          'job_read', 'job_identity', 'log_read', 'checkout_evidence')


def valid_context(env, event):
    expected = {
        'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': REPO,
        'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REF': 'refs/pull/1/merge',
        'GITHUB_ACTOR': 'dukkanai', 'GITHUB_TRIGGERING_ACTOR': 'dukkanai',
        'GITHUB_RUN_ATTEMPT': '1', 'RUNNER_ENVIRONMENT': 'github-hosted',
        'BIRDS_ENABLE_ACCESS_PROBE': 'true',
    }
    if any(env.get(k) != v for k, v in expected.items()):
        return False
    head = env.get('BIRDS_ACCESS_PROBE_HEAD_SHA', '')
    if re.fullmatch(r'[a-f0-9]{40}', head) is None:
        return False
    try:
        pr = event['pull_request']
        return (event['action'] == 'labeled' and event['label']['name'] == 'question'
                and event['repository']['full_name'] == REPO
                and type(pr['number']) is int and pr['number'] == 1
                and pr['state'] == 'open'
                and pr['head']['sha'] == head and pr['head']['ref'] == 'build/foundation'
                and pr['head']['repo']['full_name'] == REPO
                and pr['head']['repo']['fork'] is False
                and pr['base']['ref'] == 'main'
                and pr['base']['repo']['full_name'] == REPO)
    except (KeyError, TypeError):
        return False


def probe(api, report):
    """Only fixed, independently known endpoints; never emit response content."""
    objects = {}
    for key, path in (
        ('environment_read', PREFIX + '/environments/' + ENVIRONMENT),
        ('branches_read', PREFIX + '/environments/' + ENVIRONMENT + '/deployment-branch-policies?per_page=100'),
        ('job_read', PREFIX + '/actions/jobs/' + str(JOB_ID)),
    ):
        try:
            result = api.get(path)
            if not isinstance(result, dict):
                raise ValueError()
            objects[key] = result
            report[key] = 'passed'
        except Exception:
            report[key] = 'blocked'
    environment = objects.get('environment_read', {})
    report['bypass_field_present'] = 'can_admins_bypass' in environment
    if 'environment_read' in objects and 'branches_read' in objects:
        try:
            validate_environment(POLICY, environment, objects['branches_read'])
            report['environment_policy'] = 'passed'
        except Exception:
            report['environment_policy'] = 'blocked'
    job = objects.get('job_read', {})
    try:
        if not (type(job.get('id')) is int and job['id'] == JOB_ID
                and type(job.get('run_id')) is int and job['run_id'] == RUN_ID
                and job.get('name') == 'repository-security'
                and job.get('status') == 'completed' and job.get('conclusion') == 'success'):
            raise ValueError()
        steps = [s for s in job['steps'] if s.get('name') ==
                 'Run actions/checkout@11d5960a326750d5838078e36cf38b85af677262']
        if len(steps) != 1 or steps[0].get('conclusion') != 'success':
            raise ValueError()
        report['job_identity'] = 'passed'
        try:
            log = api.get(PREFIX + '/actions/jobs/' + str(JOB_ID) + '/logs', log=True)
            report['log_read'] = 'passed'
        except Exception:
            report['log_read'] = 'blocked'
            return
        report['checkout_evidence'] = 'passed' if checkout_sha(log, steps[0]) == CHECKOUT else 'blocked'
    except Exception:
        if report['job_identity'] != 'passed':
            report['job_identity'] = 'blocked'
        else:
            report['checkout_evidence'] = 'blocked'


def main():
    report = {key: 'not_run' for key in FIELDS}
    report['bypass_field_present'] = False
    try:
        path = Path(os.environ['GITHUB_EVENT_PATH'])
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 2_000_000:
            raise ValueError()
        event = json.loads(path.read_text())
        if not valid_context(os.environ, event):
            raise ValueError()
        report['context'] = 'passed'
        probe(GitHub(os.environ.get('GH_TOKEN', '')), report)
    except Exception:
        if report['context'] != 'passed':
            report['context'] = 'blocked'
    # Fixed labels only: no raw API objects, logs, exceptions, tokens or redirects.
    print(json.dumps(report, sort_keys=True))
    return 0 if all(report[key] == 'passed' for key in FIELDS) else 1


if __name__ == '__main__':
    sys.exit(main())
