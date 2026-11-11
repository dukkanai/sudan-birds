#!/usr/bin/env python3
"""Private-status launcher. Only owned disposable synthetic users may be deleted."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib
from auth_lifecycle import ROOT, configuration, read_status, require


def validate(status, config):
    origin, _, public, admin, _ = configuration(status)
    require(origin == 'http://127.0.0.1:54321', 'Exact IPv4 local API required')
    require(config.get('project_id') == 'sudan-birds-local' and
            config.get('api', {}).get('port', 54321) == 54321 and
            not config.get('api', {}).get('external_url'), 'Disposable project required')
    return {'API_URL': origin, 'ANON_KEY': public, 'SERVICE_ROLE_KEY': admin}


def relay_result(result):
    """Only fixed labels and bounded decimal counters may cross the log boundary."""
    if result.returncode != 0:
        pattern = (r'FAIL local HTTP phase=(?:setup|contact|deletion|lifecycle_authorization|'
                   r'lifecycle_batching|lifecycle_reconciliation|unrelated_fixture|shutdown)'
                   r' checks=(?:0|[1-9][0-9]{0,4}) requests=(?:0|[1-9][0-9]{0,4})')
        labels = [line for line in result.stderr.split('\n') if re.fullmatch(pattern, line)]
        if len(labels) == 1:
            print(labels[0], file=sys.stderr)
        else:
            print('FAIL remaining handler harness; sensitive details suppressed', file=sys.stderr)
        return 1
    labels = [line for line in result.stdout.split('\n') if re.fullmatch(
        r'PASS [0-9]{1,2} local HTTP checks; real Auth/RPC; simulated storage only', line)]
    require(len(labels) == 1, 'Local HTTP runtime failed')
    print(labels[0])
    return 0


def main():
    try:
        require(len(sys.argv) == 3 and sys.argv[1] == '--local-disposable', 'Explicit disposable mode required')
        status = validate(read_status(sys.argv[2]), tomllib.loads((ROOT / 'supabase/config.toml').read_text()))
        deno = Path(os.environ['DENO_BIN']).resolve(strict=True)
        require(deno.is_file(), 'Deno executable required')
        commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, check=True, text=True, timeout=5).stdout.strip()
        require(re.fullmatch(r'[a-f0-9]{40}', commit), 'Source commit required')
        print('SOURCE commit ' + commit, flush=True)
        paths = [ROOT / p for p in ('scripts/remaining_http_local.ts', 'scripts/remaining_http_local.py',
            'scripts/remaining_http_local_test.py', 'scripts/remaining_http_local_guard_test.ts',
            'scripts/remaining_http_fixture.sql', 'scripts/auth_lifecycle.py', 'docs/local-remaining-http.md', '.github/workflows/ci.yml', 'supabase/config.toml',
            'supabase/functions/deno.json', 'supabase/functions/package-lock.json')]
        paths += sorted((ROOT / 'supabase/functions').glob('_shared/*.ts'))
        paths += [ROOT / f'supabase/functions/{name}/handler.ts' for name in ('contact', 'account-delete', 'lifecycle')]
        paths += sorted((ROOT / 'supabase/migrations').glob('*.sql'))
        for path in paths:
            print('SOURCE SHA256 ' + str(path.relative_to(ROOT)) + ' ' + hashlib.sha256(path.read_bytes()).hexdigest(), flush=True)
        result = subprocess.run([str(deno), 'run', '--cached-only', '--no-remote', '--no-lock', '--no-prompt',
            '--node-modules-dir=manual', '--allow-net=127.0.0.1:54321,127.0.0.1:54329',
            '--allow-env=SMITHY_NEW_RETRIES_2026,AWS_LAMBDA_NODEJS_NO_GLOBAL_AWSLAMBDA,AWS_LAMBDA_BENCHMARK_MODE,AWS_NEW_RETRIES_2026', '--deny-read', '--deny-write', '--deny-run', '--deny-ffi', '--deny-sys',
            '--config', 'supabase/functions/deno.json', 'scripts/remaining_http_local.ts'],
            cwd=ROOT, input=json.dumps(status), text=True, timeout=150,
            env={'DENO_DIR': os.environ['DENO_DIR'], 'PATH': '/usr/bin:/bin'}, capture_output=True)
        return relay_result(result)
    except Exception:
        print('FAIL remaining handler harness; sensitive details suppressed', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
