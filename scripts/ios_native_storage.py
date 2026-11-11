#!/usr/bin/env python3
"""Disposable, installed-runtime-only iOS storage smoke. Never retain tool output."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import tempfile
import time
import uuid


class Failure(Exception):
    pass


DEVICE_PHASES = frozenset({'inventory-created', 'inventory-pre-boot',
                           'inventory-pre-test', 'cleanup-inventory-owned',
                           'cleanup-inventory-stopped', 'cleanup-inventory-absent'})
STAGES = DEVICE_PHASES | frozenset({'inventory-initial', 'create', 'boot',
                                  'boot-wait', 'test', 'cleanup-shutdown',
                                  'cleanup-delete'})


def command_failure(stage, reason, code=None, *, cleanup_failed=False):
    # Neither command arguments nor exception text can enter this message.
    if stage not in STAGES or reason not in {'exit', 'timeout', 'interrupted', 'launch', 'cleanup'}:
        return Failure('Invalid command diagnostic label')
    bounded = str(code) if type(code) is int and -255 <= code <= 255 else 'unknown'
    cleanup = ' cleanup=failed' if cleanup_failed else ''
    return Failure(f'stage={stage} reason={reason} exit={bounded}{cleanup}; output suppressed')


def terminate_owned_group(process):
    # This PGID comes only from our own Popen(start_new_session=True), never an
    # inventory, persisted PID, simctl service, or discovered external process.
    # No success-path kill: CoreSimulator/launchd services are not ours to stop.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    # The leader may have failed/exited while descendants remain in its group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=10)


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            # Never include an untrusted key/value in diagnostic text.
            raise ValueError('Duplicate JSON key')
        result[key] = value
    return result


def run(args, seconds=10, capture=False, *, stage):
    if stage not in STAGES:
        raise Failure('Invalid command diagnostic label')
    started = time.monotonic()
    try:
        return _run(args, seconds, capture, stage=stage)
    finally:
        # Bounded duration includes owned-process cleanup on failure. Never log
        # command arguments, inventory contents, exception text, or native logs.
        elapsed_ms = min(86_400_000, max(0, int((time.monotonic() - started) * 1000)))
        print(f'TIMING: stage={stage} elapsed_ms={elapsed_ms}')


def _run(args, seconds, capture, *, stage):
    # No native/plugin logs reach CI or survive this invocation. JSON inventories
    # are bounded and returned only for validation, never printed.
    with tempfile.TemporaryFile() as output:
        try:
            process = subprocess.Popen(args, stdout=output, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
        except Exception:
            raise command_failure(stage, 'launch') from None
        try:
            code = process.wait(timeout=seconds)
        except BaseException as error:
            reason = 'timeout' if isinstance(error, subprocess.TimeoutExpired) else 'interrupted'
            cleanup_failed = False
            try:
                terminate_owned_group(process)
            except Exception:
                cleanup_failed = True
            raise command_failure(stage, reason, cleanup_failed=cleanup_failed) from None
        if code:
            try:
                terminate_owned_group(process)
            except Exception:
                raise command_failure(stage, 'exit', code, cleanup_failed=True) from None
            raise command_failure(stage, 'exit', code) from None
        if capture:
            if output.tell() > 2_000_000:
                raise Failure(f'stage={stage} inventory exceeds limit')
            output.seek(0)
            try:
                return json.load(output, object_pairs_hook=unique_json_object)
            except (ValueError, UnicodeError):
                raise Failure(f'stage={stage} invalid inventory JSON') from None


def inventory(*, stage, cold=False):
    if stage == 'inventory-initial' and cold is True:
        command = ['xcrun', 'simctl', 'list', '--json']
        seconds = 240
    elif stage in DEVICE_PHASES and cold is False:
        # Keep all devices/runtime grouping to verify uniqueness and exact owned
        # identity, but avoid repeatedly enumerating runtimes/types/device pairs.
        command = ['xcrun', 'simctl', 'list', 'devices', '--json']
        # Post-boot inventory exceeded 60 seconds in run 43012583526.
        # Keep one bounded read and all ownership/cleanup guards; never retry.
        seconds = {'inventory-pre-test': 180, 'cleanup-inventory-owned': 60}.get(stage, 10)
    else:
        raise Failure('Invalid inventory phase/bound')
    result = run(command, capture=True, stage=stage, seconds=seconds)
    if not isinstance(result, dict) or not isinstance(result.get('devices'), dict):
        raise Failure(f'stage={stage} invalid device inventory shape')
    # Missing/malformed devices must never turn into proof of absence at cleanup.
    for runtime, devices in result['devices'].items():
        if not isinstance(runtime, str) or not isinstance(devices, list):
            raise Failure(f'stage={stage} invalid device inventory shape')
        for device in devices:
            if not isinstance(device, dict) or not isinstance(device.get('udid'), str):
                raise Failure(f'stage={stage} invalid device inventory shape')
            try:
                if str(uuid.UUID(device['udid'])).upper() != device['udid']:
                    raise ValueError('Noncanonical UUID')
            except ValueError:
                raise Failure(f'stage={stage} invalid device inventory identity') from None
    return result


def select(data):
    candidates = []
    for runtime in data.get('runtimes', []):
        identifier = runtime.get('identifier', '')
        version = runtime.get('version', '')
        if (runtime.get('isAvailable') is not True or
                not re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+', identifier) or
                not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', version)):
            continue
        parts = tuple(map(int, version.split('.')))
        parts += (0,) * (3 - len(parts))
        if parts[0] < 13 or any(p > 255 for p in parts):
            continue
        encoded = parts[0] * 65536 + parts[1] * 256 + parts[2]
        for device in data.get('devicetypes', []):
            device_id = device.get('identifier', '')
            minimum, maximum = device.get('minRuntimeVersion'), device.get('maxRuntimeVersion')
            if (not re.fullmatch(r'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-[A-Za-z0-9-]+', device_id) or
                    type(minimum) is not int or type(maximum) is not int or
                    not minimum <= encoded <= maximum):
                continue
            candidates.append((parts, device_id, identifier))
    if not candidates:
        raise Failure('No installed available iOS runtime with proven compatible iPhone type')
    _, device, runtime = sorted(candidates)[-1]
    return runtime, device


def records(data):
    for runtime, devices in data.get('devices', {}).items():
        for device in devices:
            yield runtime, device


def owned(data, state, absent_ok=False):
    matches = [(r, d) for r, d in records(data) if d.get('udid') == state['uuid']]
    if not matches and absent_ok:
        return None
    if len(matches) != 1:
        raise Failure('Owned simulator identity missing or ambiguous')
    runtime, device = matches[0]
    if (runtime != state['runtime'] or device.get('name') != state['name'] or
            device.get('deviceTypeIdentifier') != state['device'] or
            device.get('isAvailable') is not True):
        raise Failure('Simulator ownership mismatch')
    return device


def save(path, state):
    # The caller gives us a fresh mktemp directory, not a global simulator name.
    with path.open('x') as stream:
        json.dump(state, stream)


def load(path):
    if not stat.S_ISREG(path.lstat().st_mode) or path.is_symlink():
        raise Failure('Invalid ownership record')
    state = json.loads(path.read_text(), object_pairs_hook=unique_json_object)
    if (set(state) != {'name', 'uuid', 'runtime', 'device'} or
            not re.fullmatch(r'birds-storage-[0-9a-f]{32}', state['name']) or
            str(uuid.UUID(state['uuid'])).upper() != state['uuid'] or
            not re.fullmatch(r'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+', state['runtime']) or
            not re.fullmatch(r'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-[A-Za-z0-9-]+', state['device'])):
        raise Failure('Invalid ownership identity')
    return state


def execute(directory):
    path = directory / 'owned.json'
    pending = directory / 'creation-attempted'
    if path.exists() or pending.exists():
        raise Failure('Invocation directory already used')
    # A cold CoreSimulator service may need startup time. Exactly this first
    # pre-creation inventory gets 240 seconds; no retry or fallback is permitted.
    # CoreSimulator may spend over 150 seconds mounting installed runtime images:
    # https://github.com/actions/runner-images/issues/15247
    data = inventory(cold=True, stage='inventory-initial')
    runtime, device = select(data)
    name = 'birds-storage-' + uuid.uuid4().hex
    if any(d.get('name') == name for _, d in records(data)):
        raise Failure('Simulator name already exists')
    pending.touch(exist_ok=False)
    # simctl create returns text, so use subsequent inventory rather than trusting
    # stdout. A failed/uncertain create is never permission to adopt/delete.
    run(['xcrun', 'simctl', 'create', name, device, runtime], seconds=60, stage='create')
    matches = [(r, d) for r, d in records(inventory(stage='inventory-created')) if d.get('name') == name]
    if len(matches) != 1:
        raise Failure('Created simulator identity uncertain')
    state = {'name': name, 'uuid': matches[0][1].get('udid'),
             'runtime': runtime, 'device': device}
    owned({'devices': {matches[0][0]: [matches[0][1]]}}, state)
    # Validate schema before writing the authoritative ownership record.
    if not isinstance(state['uuid'], str) or str(uuid.UUID(state['uuid'])).upper() != state['uuid']:
        raise Failure('Invalid created simulator UUID')
    if any(d.get('udid') == state['uuid'] for _, d in records(data)):
        raise Failure('Created UUID existed before invocation')
    save(path, state)
    pending.unlink()
    if owned(inventory(stage='inventory-pre-boot'), state).get('state') != 'Shutdown':
        raise Failure('Fresh simulator not shutdown')
    run(['xcrun', 'simctl', 'boot', state['uuid']], seconds=30, stage='boot')
    run(['xcrun', 'simctl', 'bootstatus', state['uuid'], '-b'], seconds=180, stage='boot-wait')
    if owned(inventory(stage='inventory-pre-test'), state).get('state') != 'Booted':
        raise Failure('Owned simulator did not boot')
    run(['flutter', '--no-version-check', 'test', '--no-pub',
         'integration_test/native_storage_test.dart', '-d', state['uuid'],
         '--dart-define=NATIVE_STORAGE_SMOKE=true', '--reporter', 'expanded'], seconds=600, stage='test')
    print('PASS: native storage smoke on owned disposable iOS simulator')


def cleanup(directory):
    path = directory / 'owned.json'
    if not path.exists():
        if (directory / 'creation-attempted').exists():
            raise Failure('Creation uncertain; no simulator adopted or deleted')
        print('Cleanup: no owned simulator was created')
        return
    state = load(path)
    device = owned(inventory(stage='cleanup-inventory-owned'), state, absent_ok=True)
    if device is None:
        print('Cleanup: owned simulator already absent')
        return
    if device.get('state') == 'Booted':
        run(['xcrun', 'simctl', 'shutdown', state['uuid']], seconds=30, stage='cleanup-shutdown')
    elif device.get('state') != 'Shutdown':
        raise Failure('Simulator state uncertain; no destructive cleanup attempted')
    if owned(inventory(stage='cleanup-inventory-stopped'), state).get('state') != 'Shutdown':
        raise Failure('Simulator shutdown unconfirmed')
    run(['xcrun', 'simctl', 'delete', state['uuid']], seconds=30, stage='cleanup-delete')
    if owned(inventory(stage='cleanup-inventory-absent'), state, absent_ok=True) is not None:
        raise Failure('Simulator deletion unconfirmed')
    print('Cleanup: owned simulator deletion verified')


def interrupted(_signum, _frame):
    raise Failure('Invocation interrupted')


def main():
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['run', 'cleanup'])
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.directory.is_symlink() or not args.directory.is_dir():
        raise Failure('Private invocation directory required')
    (execute if args.mode == 'run' else cleanup)(args.directory)


if __name__ == '__main__':
    try:
        main()
    except Failure as error:
        print(f'FAIL: {error}')
        raise SystemExit(1) from None
    except Exception:
        print('FAIL: iOS storage smoke/cleanup failed; native output suppressed')
        raise SystemExit(1) from None
