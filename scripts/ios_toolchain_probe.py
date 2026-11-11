"""Read-only, nonsecret signing-preparation probe; never signs or uploads."""
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time

DEVELOPER_DIR = '/Applications/Xcode_26.3.app/Contents/Developer'
COMMANDS = (
    ('/usr/bin/xcodebuild', '-version'),
    ('/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-version'),
    ('/usr/bin/xcrun', 'altool', '--help'),
)
TIMEOUT = 30
OUTPUT_LIMIT = 256 * 1024


class ProbeFailure(Exception):
    """Contains no child output or environment values."""


def query(command):
    """Only fixed help/version queries; bounded memory, duration and output."""
    if command not in COMMANDS:
        raise ProbeFailure('query_not_allowed')
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
           'DEVELOPER_DIR': DEVELOPER_DIR, 'LC_ALL': 'C'}
    child = None
    try:
        child = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        output = bytearray()
        deadline = time.monotonic() + TIMEOUT
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise ProbeFailure('query_timeout')
                chunk = os.read(child.stdout.fileno(), 8192)
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > OUTPUT_LIMIT:
                    raise ProbeFailure('query_output_limit')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProbeFailure('query_timeout')
        if child.wait(timeout=remaining) != 0:
            raise ProbeFailure('query_failed')
        return output.decode('utf-8', errors='strict')
    except (OSError, UnicodeError, subprocess.SubprocessError):
        raise ProbeFailure('query_failed') from None
    finally:
        if child is not None:
            # The leader may have exited while descendants retain its pipe.
            # Never use Popen's context manager: its implicit wait is unbounded.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                raise ProbeFailure('query_cleanup_failed') from None
            finally:
                try:
                    child.wait(timeout=2)
                except (OSError, subprocess.SubprocessError):
                    raise ProbeFailure('query_cleanup_failed') from None
                finally:
                    child.stdout.close()


def empty_result():
    return {
        'purpose': 'signing_preparation_only',
        'status': 'signing_preparation_blocked',
        'toolchain_present': False,
        'xcode_version': None, 'xcode_build': None, 'ios_sdk_version': None,
        'exact_toolchain': False, 'api_key_subject': False,
        'upload_package': False, 'wait': False,
        'queries_succeeded': False,
    }


def probe():
    result = empty_result()
    result['toolchain_present'] = Path(DEVELOPER_DIR).is_dir()
    if not result['toolchain_present']:
        return result
    try:
        version = query(COMMANDS[0])
        # Only syntactically constrained version fields reach public output.
        match = re.fullmatch(r'Xcode ([0-9]{1,3}(?:\.[0-9]{1,3}){1,2})\n'
                             r'Build version ([A-Za-z0-9]{1,16})\s*', version)
        if match:
            result['xcode_version'], result['xcode_build'] = match.groups()
        sdk = query(COMMANDS[1]).strip()
        if re.fullmatch(r'[0-9]{1,3}(?:\.[0-9]{1,3}){1,2}', sdk):
            result['ios_sdk_version'] = sdk
        result['exact_toolchain'] = (
            result['xcode_version'] == '26.3'
            and result['xcode_build'] == '17C529'
            and result['ios_sdk_version'] == '26.2')
        help_text = query(COMMANDS[2])
        for field, option in [('api_key_subject', '--api-key-subject'),
                              ('upload_package', '--upload-package'),
                              ('wait', '--wait')]:
            result[field] = bool(re.search(
                r'(?<![\w-])' + re.escape(option) + r'(?![\w-])', help_text))
        result['queries_succeeded'] = True
    except ProbeFailure:
        return result
    if all(result[field] for field in (
            'exact_toolchain', 'api_key_subject', 'upload_package', 'wait',
            'queries_succeeded')):
        result['status'] = 'signing_preparation_capabilities_present'
    return result


def main():
    try:
        result = probe()
    except Exception:
        # Do not expose dependency exceptions, paths or environment values.
        result = empty_result()
    print(json.dumps(result, sort_keys=True))
    return 0 if result['status'] == 'signing_preparation_capabilities_present' else 1


if __name__ == '__main__':
    raise SystemExit(main())
