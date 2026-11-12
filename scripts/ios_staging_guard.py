#!/usr/bin/env python3
"""Fail-closed, read-only gate for the INERT iOS staging example.

Remote evidence is fetched live; a JSON file/boolean is not environment proof.
No signing, credentials provisioning, writes to GitHub, or Apple requests here.
"""
from datetime import datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / 'docs/examples/ios-staging/config.json'
REPO = 'dukkanai/sudan-birds'
JOBS = {
    '.github/workflows/ci.yml': ['flutter', 'database', 'edge', 'repository-security'],
    '.github/workflows/native-checks.yml': ['android-debug', 'ios-simulator', 'ios-native-storage'],
    '.github/workflows/codec-resource.yml': ['local-edge-probe'],
}
SHA = re.compile(r'[a-f0-9]{40}')


class Blocked(Exception):
    """Only static, nonsecret messages may be attached to this exception."""


def require(condition, message):
    if not condition:
        raise Blocked(message)


def full(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def validate_uploader(c):
    require(c.get('uploader_role') == 'DEVELOPER' and c.get('uploader_access_reviewed') is True,
            'Developer uploader role, ownership and scope must be reviewed.')
    kind = c.get('uploader_kind')
    require(kind in ('individual', 'team'), 'Uploader credential kind is unsupported.')
    if kind == 'individual':
        require(c.get('uploader_scope') == 'single_app' and 'uploader_issuer_id' in c
                and c['uploader_issuer_id'] is None,
                'Individual uploader needs reviewed single-app access and no issuer.')
    else:
        require(c.get('uploader_scope') == 'all_apps'
                and full(c.get('uploader_issuer_id'), r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}')
                and c['uploader_issuer_id'] != '00000000-0000-0000-0000-000000000000',
                'Team uploader needs explicitly reviewed all-app authority and a nonzero issuer UUID.')


def validate_config(c):
    require(c.get('schema_version') == 1 and c.get('enabled') is True,
            'Template is disabled or schema is unsupported.')
    require((c.get('repository'), c.get('pull_request'), c.get('source_branch'), c.get('base_branch')) ==
            (REPO, 1, 'build/foundation', 'main'), 'Repository/branch/PR allowlist changed.')
    require(full(c.get('environment'), r'[a-zA-Z0-9_-]{1,64}'), 'Protected environment is unconfigured.')
    require(c.get('owner_reviewer') == 'dukkanai' and type(c.get('prevent_self_review')) is bool,
            'Owner reviewer/self-review policy is unconfigured.')
    for key, pattern in {
        'approved_team_id': r'[A-Z0-9]{10}', 'bundle_id': r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}',
        'asc_app_id': r'[1-9][0-9]{5,19}', 'profile_uuid': r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}',
        'certificate_sha1': r'[A-F0-9]{40}', 'uploader_key_id': r'[A-Z0-9]{10}',
        'build_version': r'[0-9]{1,4}\.[0-9]{1,2}\.[0-9]{1,2}',
        'build_number': r'[1-9][0-9]{0,3}(?:\.[0-9]{1,2}){0,2}',
    }.items():
        require(full(c.get(key), pattern), 'Approved signing/app/build configuration is incomplete.')
    require(c['bundle_id'] not in {'dev.sudanbirds.sudanBirds', 'dev.sudanbirds.sudan_birds'},
            'Temporary source app identifiers are not approved signing identifiers.')
    validate_uploader(c)
    require(c.get('staging_limitations_acknowledged') is True,
            'Staging limitations and intended synthetic-only use must be reviewed.')
    require((c.get('runner'), c.get('xcode_version'), c.get('xcode_build'), c.get('ios_sdk')) ==
            ('macos-15', '26.3', '17C529', '26.2'), 'Toolchain differs from the reviewed example.')
    require((c.get('supabase_url'), c.get('auth_redirect')) ==
            ('https://tkfhcjdxovivsrmoxpjm.supabase.co', 'dev.sudanbirds.staging://auth/callback'),
            'Staging endpoint/callback differs from this reviewed example.')
    workflows = c.get('ci_workflows', [])
    require(isinstance(workflows, list) and len(workflows) == len(JOBS), 'Required CI definitions missing.')
    require({w.get('path') for w in workflows} == set(JOBS), 'Required CI workflow allowlist differs.')
    for w in workflows:
        require(w.get('jobs') == JOBS[w['path']] and full(w.get('sha256'), r'[a-f0-9]{64}'),
                'Required CI jobs/hash missing or changed.')
        require(hashlib.sha256((ROOT / w['path']).read_bytes()).hexdigest() == w['sha256'],
                'CI definition changed; review its new source before updating its digest.')


def validate_event(c, event, env):
    pr = event.get('pull_request', {})
    require(env.get('GITHUB_ACTIONS') == 'true' and env.get('GITHUB_EVENT_NAME') == 'pull_request',
            'Only a GitHub pull_request run is allowed.')
    require(env.get('GITHUB_REPOSITORY') == REPO and event.get('repository', {}).get('full_name') == REPO,
            'Unexpected repository.')
    require(env.get('GITHUB_REF') == 'refs/pull/1/merge' and pr.get('number') == 1,
            'Unexpected PR number/ref.')
    require(event.get('action') in {'labeled', 'synchronize', 'reopened'}, 'Unsupported PR action.')
    for login in [env.get('GITHUB_ACTOR', ''), env.get('GITHUB_TRIGGERING_ACTOR', ''),
                  pr.get('user', {}).get('login', ''), event.get('sender', {}).get('login', '')]:
        require(login and not login.endswith('[bot]') and 'dependabot' not in login.lower(),
                'Bot/Dependabot actor is not allowed.')
    for side, branch in [('head', c['source_branch']), ('base', c['base_branch'])]:
        obj = pr.get(side, {})
        require(obj.get('ref') == branch and obj.get('repo', {}).get('full_name') == REPO
                and obj.get('repo', {}).get('fork') is False, 'Fork or wrong branch is not allowed.')
    approved = env.get('BIRDS_APPROVED_HEAD_SHA', '')
    require(full(approved, SHA.pattern) and pr.get('head', {}).get('sha') == approved,
            'PR head does not match the separately approved immutable SHA.')
    require(env.get('GITHUB_RUN_ATTEMPT') == '1',
            'Reruns are blocked; reconcile any prior upload before a newly approved run.')
    return approved


def validate_current_pr(c, pr, sha):
    require(pr.get('state') == 'open' and pr.get('merged') is False, 'PR is closed or merged.')
    require(pr.get('head', {}).get('sha') == sha and pr.get('head', {}).get('ref') == c['source_branch']
            and pr.get('head', {}).get('repo', {}).get('full_name') == REPO
            and pr.get('head', {}).get('repo', {}).get('fork') is False,
            'Live PR head changed or is not the approved repository.')
    require(pr.get('base', {}).get('ref') == c['base_branch']
            and pr.get('base', {}).get('repo', {}).get('full_name') == REPO,
            'Live PR base changed.')


def validate_environment(c, environment, branches):
    require(environment.get('name') == c['environment'], 'Protected environment missing.')
    require(environment.get('can_admins_bypass') is False,
            'No-admin-bypass could not be verified. Do not substitute a local attestation.')
    rules = [r for r in environment.get('protection_rules', []) if r.get('type') == 'required_reviewers']
    require(len(rules) == 1, 'Required owner approval is missing or ambiguous.')
    rule = rules[0]
    require(rule.get('prevent_self_review') is c['prevent_self_review'], 'Self-review policy changed.')
    reviewers = rule.get('reviewers', [])
    require(len(reviewers) == 1 and reviewers[0].get('type') == 'User'
            and reviewers[0].get('reviewer', {}).get('login') == c['owner_reviewer'],
            'Only the exact owner may approve this environment.')
    require(environment.get('deployment_branch_policy') ==
            {'protected_branches': False, 'custom_branch_policies': True},
            'Exact custom PR-ref restriction is required.')
    policies = branches.get('branch_policies', [])
    require(branches.get('total_count') == 1 and len(policies) == 1
            and policies[0].get('name') == 'refs/pull/1/merge'
            and policies[0].get('type') == 'branch', 'Environment must allow only refs/pull/1/merge.')


def validate_run(run, workflow, sha, run_id, attempt):
    require(run.get('id') == run_id and run.get('run_attempt') == attempt, 'CI run/attempt changed.')
    require(run.get('event') == 'pull_request' and run.get('status') == 'completed'
            and run.get('conclusion') == 'success', 'Required CI run is unfinished or unsuccessful.')
    require(run.get('head_sha') == sha and run.get('head_branch') == 'build/foundation'
            and run.get('head_repository', {}).get('full_name') == REPO
            and run.get('repository', {}).get('full_name') == REPO
            and run.get('path') == workflow['path'], 'CI run source or workflow differs.')
    require([p.get('number') for p in run.get('pull_requests', [])] == [1], 'CI PR association is ambiguous.')


def validate_jobs(body, workflow):
    jobs = body.get('jobs', [])
    require(body.get('total_count') == len(workflow['jobs']) and len(jobs) == len(workflow['jobs']),
            'CI jobs are missing, paginated or ambiguous.')
    require(sorted(j.get('name', '') for j in jobs) == sorted(workflow['jobs']), 'Required CI jobs differ.')
    require(all(j.get('status') == 'completed' and j.get('conclusion') == 'success' for j in jobs),
            'Failed/skipped/cancelled/incomplete required job blocks signing.')
    return jobs


def checkout_sha(log, step):
    # Only the checkout action's command output, never a user-controlled title or summary.
    # A reviewed workflow hash and the unique successful pinned checkout step are also required.
    try:
        start = datetime.fromisoformat(step['started_at'].replace('Z', '+00:00'))
        end = datetime.fromisoformat(step['completed_at'].replace('Z', '+00:00')) + timedelta(seconds=1)
        require(start.utcoffset() is not None and end.utcoffset() is not None and start < end,
                'Checkout step timestamp interval is invalid.')
    except (KeyError, ValueError, TypeError):
        raise Blocked('Checkout step timestamps are unavailable.') from None
    lines = log.splitlines()
    hits = []
    for i, line in enumerate(lines[:-1]):
        if re.fullmatch(r'\d{4}-\d\d-\d\dT\S+ \[command\]/[^\s]+/git log -1 --format=%H', line):
            timestamp = datetime.fromisoformat(line.split(' ', 1)[0].replace('Z', '+00:00'))
            if not start <= timestamp < end:
                continue
            m = re.fullmatch(r'\d{4}-\d\d-\d\dT\S+ ([a-f0-9]{40})', lines[i + 1])
            require(m is not None, 'Checkout evidence is malformed.')
            output_time = datetime.fromisoformat(lines[i + 1].split(' ', 1)[0].replace('Z', '+00:00'))
            require(start <= output_time < end, 'Checkout output is outside its verified step.')
            hits.append(m[1])
    require(len(hits) == 1, 'Unique checkout SHA is unavailable in the CI job log.')
    return hits[0]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, token):
        require(bool(token), 'Read-only GitHub token is missing.')
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def get(self, path, log=False):
        require(path.startswith('/repos/' + REPO + '/'), 'GitHub API target rejected.')
        req = urllib.request.Request('https://api.github.com' + path, headers={
            'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28'})
        limit = 24 * 1024 * 1024 if log else 4 * 1024 * 1024
        try:
            try:
                response = self.opener.open(req, timeout=30)
            except urllib.error.HTTPError as error:
                require(log and error.code == 302, 'Required GitHub evidence is inaccessible.')
                url = error.headers.get('Location', '')
                target = urllib.parse.urlsplit(url)
                require(target.scheme == 'https' and not target.username and not target.password
                        and target.port in {None, 443}
                        and target.hostname is not None
                        and target.hostname.endswith('.blob.core.windows.net'),
                        'Unexpected GitHub log storage redirect; evidence cannot be trusted.')
                # Never forward GITHUB_TOKEN to storage or print its signed redirect URL.
                response = self.opener.open(urllib.request.Request(url), timeout=30)
            with response:
                raw = response.read(limit + 1)
                require(len(raw) <= limit, 'Evidence exceeds the bounded reader; blocked rather than truncated.')
            return raw.decode('utf-8-sig') if log else json.loads(raw)
        except (OSError, ValueError, urllib.error.URLError):
            raise Blocked('Required remote evidence could not be read safely.') from None


def live_gate(c, event, env, api):
    validate_config(c)
    sha = validate_event(c, event, env)
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() == sha,
            'Checkout is not the approved head SHA.')
    require(subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], cwd=ROOT).returncode == 0,
            'Tracked source changed after checkout.')
    prefix = '/repos/' + REPO
    validate_current_pr(c, api.get(prefix + '/pulls/1'), sha)
    name = urllib.parse.quote(c['environment'], safe='')
    validate_environment(c, api.get(prefix + '/environments/' + name),
                         api.get(prefix + '/environments/' + name + '/deployment-branch-policies?per_page=100'))
    head_tree = api.get(prefix + '/git/commits/' + sha).get('tree', {}).get('sha')
    require(full(head_tree, SHA.pattern), 'Approved source tree is unavailable.')
    try:
        runs = json.loads(env.get('BIRDS_CI_RUNS_JSON', ''))
    except ValueError:
        raise Blocked('Exact CI run/attempt inputs are unconfigured.') from None
    require(isinstance(runs, dict) and set(runs) == set(JOBS), 'Exact CI run inputs are incomplete.')
    trees = {sha: head_tree}
    for workflow in c['ci_workflows']:
        selection = runs[workflow['path']]
        require(isinstance(selection, dict) and set(selection) == {'id', 'attempt'}
                and all(type(selection[k]) is int and selection[k] > 0 for k in selection),
                'CI run IDs/attempts must be positive integers.')
        run_id, attempt = selection['id'], selection['attempt']
        run_path = prefix + '/actions/runs/' + str(run_id)
        run = api.get(run_path)
        validate_run(run, workflow, sha, run_id, attempt)
        jobs = validate_jobs(api.get(run_path + '/attempts/' + str(attempt) + '/jobs?per_page=100'), workflow)
        for job in jobs:
            checkouts = [s for s in job.get('steps', []) if s.get('name') == 'Run actions/checkout@11d5960a326750d5838078e36cf38b85af677262']
            require(len(checkouts) == 1 and checkouts[0].get('conclusion') == 'success',
                    'Successful pinned checkout step could not be established.')
            actual = checkout_sha(api.get(prefix + '/actions/jobs/' + str(job['id']) + '/logs', log=True), checkouts[0])
            if actual not in trees:
                trees[actual] = api.get(prefix + '/git/commits/' + actual).get('tree', {}).get('sha')
            require(trees[actual] == head_tree, 'A required job tested a different complete Git tree.')
    # Detect a new push or a protection change while logs were being checked.
    validate_current_pr(c, api.get(prefix + '/pulls/1'), sha)
    validate_environment(c, api.get(prefix + '/environments/' + name),
                         api.get(prefix + '/environments/' + name + '/deployment-branch-policies?per_page=100'))
    return sha


def main():
    try:
        c = json.loads(CONFIG.read_text())
        # Disabled config must fail before any network call or secret operation.
        validate_config(c)
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        sha = live_gate(c, event, os.environ, GitHub(os.environ.get('GH_TOKEN', '')))
        if len(sys.argv) > 1 and sys.argv[1] == '--outputs':
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write('source_sha=' + sha + '\nenvironment=' + c['environment'] + '\n')
        print('Exact source, eight CI jobs and live environment protections verified.')
        return 0
    except Blocked as error:
        print('BLOCKED: ' + str(error), file=sys.stderr)
    except Exception:
        print('BLOCKED: Evidence validation failed; no private response was logged.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
