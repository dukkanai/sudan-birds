"""Bounded LOCAL Edge Runtime experiment. Never accepts a hosted URL or user image."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

TOKEN = 'LOCAL_SYNTHETIC_CODEC_TEST_ONLY_'.ljust(43, 'x')
PROJECT = 'birds-codec-resource'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('redirect forbidden')


def endpoint(api_url):
    parsed = urllib.parse.urlsplit(api_url)
    if (parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or
            parsed.username or parsed.password or parsed.query or parsed.fragment or
            parsed.path not in ('', '/') or not parsed.port):
        raise ValueError('literal loopback required')
    return api_url.rstrip('/') + '/functions/v1/codec-diagnostic'


def metrics(data, deadline):
    if not isinstance(data, dict) or data.get('expires_at') != deadline:
        raise ValueError('invalid deadline')
    for key in ('calls', 'width', 'height', 'output_bytes', 'elapsed_ms'):
        if type(data.get(key)) is not int:
            raise ValueError('invalid numeric metric')
    if (not 1 <= data['calls'] <= 20 or data['width'] != 640 or data['height'] != 640 or
            not 20 <= data['output_bytes'] <= 2_097_152 or not 0 <= data['elapsed_ms'] <= 30_000):
        raise ValueError('invalid result')
    result = {k: data[k] for k in ('calls', 'width', 'height', 'output_bytes', 'elapsed_ms')}
    for phase in ('before', 'after'):
        values = data.get(phase)
        if not isinstance(values, dict):
            raise ValueError('missing memory metrics')
        result[phase] = {}
        for key in ('rss', 'heapUsed', 'heapTotal', 'external'):
            value = values.get(key)
            if type(value) is not int or not 0 <= value < 2**53:
                raise ValueError('invalid memory metric')
            result[phase][key] = value
    return result


def require_verified_gateway(text):
    config = tomllib.loads(text)
    if config.get('functions', {}).get('codec-diagnostic', {}).get('verify_jwt') is not True:
        raise ValueError('verified gateway required')


def safe_failure(progress, error):
    allowed = {'setup', 'startup', 'status', 'runtime_inspection', 'request',
               'response_validation', 'warm_check', 'cleanup'}
    phase = progress.get('phase')
    result = {'error': 'LOCAL_EDGE_PROBE_FAILED',
              'phase': phase if phase in allowed else 'setup'}
    index = progress.get('request')
    if type(index) is int and 1 <= index <= 20:
        result['request'] = index
    status = error.code if isinstance(error, urllib.error.HTTPError) else progress.get('status')
    if type(status) is int and 100 <= status <= 599:
        result['http_status'] = status
    code = progress.get('diagnostic_error')
    if isinstance(code, str) and code in DIAGNOSTIC_ERRORS:
        result['diagnostic_error'] = code
        if code == 'diagnostic_unavailable' and status == 503:
            memory = safe_memory(progress.get('diagnostic_memory'))
            if memory is not None:
                result['diagnostic_memory'] = memory
            calls = progress.get('diagnostic_calls')
            if type(calls) is int and 1 <= calls <= 20:
                result['diagnostic_calls'] = calls
    return result


DIAGNOSTIC_ERRORS = frozenset({'diagnostic_expired', 'diagnostic_unauthorized',
    'empty_post_required', 'diagnostic_limit', 'diagnostic_unavailable'})


def safe_memory(values):
    if not isinstance(values, dict):
        return None
    result = {}
    for key in ('rss', 'heapUsed', 'heapTotal', 'external'):
        value = values.get(key)
        if type(value) is not int or not 0 <= value < 2**53:
            return None
        result[key] = value
    return result


def diagnostic_details(raw):
    try:
        if len(raw) > 4096:
            return {}
        data = json.loads(raw)
        code = data.get('error') if isinstance(data, dict) else None
        if not isinstance(code, str) or code not in DIAGNOSTIC_ERRORS:
            return {}
        result = {'diagnostic_error': code}
        if code == 'diagnostic_unavailable':
            memory = safe_memory(data.get('memory'))
            if memory is not None:
                result['diagnostic_memory'] = memory
            calls = data.get('calls')
            if type(calls) is int and 1 <= calls <= 20:
                result['diagnostic_calls'] = calls
        return result
    except Exception:
        return {}


def diagnostic_error(raw):
    return diagnostic_details(raw).get('diagnostic_error')


def local_entrypoint(deadline):
    """Only written into the disposable LOCAL archive; never a hosted handler."""
    return (
        'import * as r2 from "../_shared/r2.ts";\n'
        'import * as auth from "../_shared/auth.ts";\n'
        'import { createCodecDiagnostic } from "./handler.ts";\n'
        f'const diagnostic = createCodecDiagnostic({json.dumps(deadline)}, {json.dumps(TOKEN)});\n'
        'Deno.serve(async (req: Request) => {\n'
        # Retain actual exported function objects in the request closure. Do not call them.
        '  const r2Exports = Object.values(r2);\n'
        '  const authExports = Object.values(auth);\n'
        '  if (r2Exports.length !== 5 || authExports.length !== 7 ||\n'
        '      ![...r2Exports, ...authExports].every((value) => typeof value === "function")) {\n'
        '    return new Response(null, { status: 503 });\n'
        '  }\n'
        '  const response = await diagnostic(req);\n'
        '  response.headers.set("x-local-sdk-imports", "r2-5-auth-7");\n'
        '  return response;\n'
        '});\n'
    )


def require_sdk_import_marker(value):
    if value != 'r2-5-auth-7':
        raise ValueError('production helper import marker missing')


def run(cli, copy, progress):
    """copy must be a disposable git archive. CLI output is NEVER echoed."""
    progress['phase'] = 'setup'
    os.umask(0o077)
    copy = Path(copy).resolve()
    cli = str(Path(cli).resolve())
    config = copy / 'supabase/config.toml'
    text = config.read_text()
    require_verified_gateway(text)
    if '[edge_runtime]' in text:
        raise ValueError('review changed runtime config before experiment')
    text = re.sub(r'^project_id = .*$', f'project_id = "{PROJECT}"', text, count=1, flags=re.M)
    config.write_text(text + '\n[edge_runtime]\nenabled = true\npolicy = "per_worker"\ndeno_version = 2\n')
    # One literal deadline shared by ALL isolates, never computed inside their code.
    deadline = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=20)).isoformat(
        timespec='milliseconds').replace('+00:00', 'Z')
    (copy / 'supabase/functions/codec-diagnostic/index.ts').write_text(
        local_entrypoint(deadline))
    with tempfile.TemporaryDirectory(prefix='birds-codec-private-', dir=copy) as private:
        log = Path(private) / 'cli.log'
        status_file = Path(private) / 'status.json'

        def command(args, output=None):
            with (output or log).open('wb') as out:
                subprocess.run(args, cwd=copy, stdout=out, stderr=subprocess.DEVNULL,
                               check=True, timeout=480)

        try:
            progress['phase'] = 'startup'
            command([cli, 'start', '-x', 'studio,imgproxy,inbucket,logflare,vector,supavisor'])
            progress['phase'] = 'status'
            command([cli, 'status', '--output', 'json'], status_file)
            if status_file.stat().st_mode & 0o077:
                raise ValueError('status file must be private')
            status = json.loads(status_file.read_text())
            url = endpoint(status['API_URL'])
            key = status['ANON_KEY']
            # Inspect only selected metadata; never emit container env or full inspect.
            def capture(args):
                return subprocess.check_output(args, cwd=copy, stderr=subprocess.DEVNULL,
                                               timeout=30).decode()
            progress['phase'] = 'runtime_inspection'
            container = f'supabase_edge_runtime_{PROJECT}'
            info = json.loads(capture(['docker', 'inspect', '--format',
                '{\"Image\":{{json .Config.Image}},\"Entrypoint\":{{json .Config.Entrypoint}}}', container]))
            image = info['Image']
            if image.rsplit('/', 1)[-1] != 'edge-runtime:v1.69.28':
                raise ValueError('unexpected runtime image')
            entry = info['Entrypoint']
            command_line = entry[2].split('\n', 1)[0] if len(entry) == 3 else ''
            if ('--policy=per_worker' not in command_line or '--inspect' in command_line):
                raise ValueError('unexpected runtime policy/debugger')
            source = capture(['docker', 'exec', container, 'cat', '/root/index.ts'])
            for expected in ('const memoryLimitMb = 256;', 'const cpuTimeSoftLimitMs = 1000;',
                             'const cpuTimeHardLimitMs = 2000;'):
                if expected not in source:
                    raise ValueError('unexpected user-worker limits')
            digest = json.loads(capture(['docker', 'image', 'inspect', '--format',
                '{\"Id\":{{json .Id}},\"RepoDigests\":{{json .RepoDigests}}}', image]))
            image_id = digest['Id']
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', image_id):
                raise ValueError('unexpected image ID')
            repo_digests = [d for d in digest.get('RepoDigests', []) if
                            re.fullmatch(r'[a-zA-Z0-9./_-]+@sha256:[0-9a-f]{64}', d)]
            print(json.dumps({'image': image, 'image_id': image_id, 'repo_digests': repo_digests,
                              'policy': 'per_worker', 'memory_limit_mib': 256,
                              'cpu_soft_ms_per_worker': 1000, 'cpu_hard_ms_per_worker': 2000,
                              'deadline': deadline}), flush=True)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            warm = False
            for i in range(20):
                progress.update(phase='request', request=i + 1, status=None)
                req = urllib.request.Request(url, method='POST', headers={
                    'Authorization': 'Bearer ' + key, 'apikey': key,
                    'x-codec-diagnostic-token': TOKEN})
                try:
                    response = opener.open(req, timeout=30)
                except urllib.error.HTTPError as error:
                    # Only an allowlisted code and bounded numeric metrics may be emitted.
                    try:
                        progress.update(diagnostic_details(error.read(4097)))
                    except Exception:
                        pass  # Preserve the original HTTP status even if error-body read fails.
                    finally:
                        error.close()
                    raise
                with response:
                    progress.update(phase='response_validation', status=response.status)
                    if response.status != 200:
                        raise ValueError('non-200 result')
                    require_sdk_import_marker(response.headers.get('x-local-sdk-imports'))
                    raw = response.read(16385)
                    if len(raw) > 16384:
                        raise ValueError('oversized response')
                    result = metrics(json.loads(raw), deadline)
                warm |= result['calls'] > 1
                print(json.dumps({'request': i + 1, **result}), flush=True)
                time.sleep(.1)
            progress.update(phase='warm_check', request=None, status=None)
            if not warm:
                raise ValueError('no warm-worker evidence')
        finally:
            prior_failure = sys.exc_info()[0] is not None
            try:
                command([cli, 'stop', '--no-backup'])
            except Exception as error:
                print(json.dumps(safe_failure({'phase': 'cleanup'}, error)), file=sys.stderr)
                # Preserve the original failure classification, if one exists.
                if prior_failure:
                    pass
                else:
                    progress.clear()
                    progress['phase'] = 'cleanup'
                    raise

    print('LOCAL_EDGE_PROBE_PASS: 20/20; production helper imports retained; warm worker observed; NOT hosted clearance')


if __name__ == '__main__':
    progress = {'phase': 'setup'}
    try:
        run(sys.argv[1], sys.argv[2], progress)
    except Exception as error:
        # No exception text, URLs, headers, CLI logs or response bodies.
        print(json.dumps(safe_failure(progress, error)), file=sys.stderr)
        sys.exit(1)
