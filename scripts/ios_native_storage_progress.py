"""Bounded diagnostic-only Flutter machine progress; never retain raw output."""
import json
import os
import re
import select
import threading

TEST_NAME = 'real native storage and restore fence smoke'
MAX_LINE = 8192
MAX_INPUT = 2_000_000
# Pinned Flutter 3.38.5 SummaryStatus/mac.dart messages. No substring matching,
# ANSI removal, paths or arbitrary tool text. Durations are discarded.
TOOL_STARTS = {
    b'Running pod install...': 'pod_started',
    b'Running Xcode build...': 'xcode_started',
}
TOOL_PADDING = rb' {0,128}'
TOOL_DURATION = rb'[0-9]{1,6}(?:\.[0-9]{1,3})? ?(?:ms|s)'


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate key')
        result[key] = value
    return result


class MachineProgress:
    """Observe documented events, never infer success or safe cleanup.

    Flutter 3.38.5 EventPrinter emits test.startedProcess in a one-element
    array. Dart's JSON reporter emits testStart/testDone objects. Three pinned
    native tool messages yield fixed observations. Raw output, URIs, errors
    and arbitrary test names are discarded.
    """
    def __init__(self):
        self.buffer = bytearray()
        self.total = 0
        self.dropping = False
        self.incomplete = False
        self.device = False
        self.fixture_id = None
        self.finished = False
        self.ambiguous = False
        self.input_limit = False
        self.line_limit = False
        self.partial_line = False
        self.pod_started = False
        self.xcode_started = False
        self.xcode_returned = False

    def feed(self, chunk):
        self.total = min(MAX_INPUT + 1, self.total + len(chunk))
        if self.total > MAX_INPUT:
            self.buffer.clear()
            self.incomplete = True
            self.input_limit = True
            return
        for byte in chunk:
            if byte == 10:
                if not self.dropping:
                    self.line(bytes(self.buffer))
                self.buffer.clear()
                self.dropping = False
            elif not self.dropping:
                if len(self.buffer) >= MAX_LINE:
                    self.buffer.clear()
                    self.dropping = True
                    self.incomplete = True
                    self.line_limit = True
                else:
                    self.buffer.append(byte)

    def line(self, raw):
        self.tool_line(raw)
        # No ANSI stripping or substring search: decorated/partial lines are
        # not machine events. A valid later line can still be observed.
        try:
            event = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object)
        except (ValueError, UnicodeError, RecursionError):
            return
        if isinstance(event, list) and len(event) == 1:
            item = event[0]
            if (isinstance(item, dict) and item.get('event') == 'test.startedProcess'
                    and isinstance(item.get('params'), dict)
                    and isinstance(item['params'].get('vmServiceUri'), str)
                    and item['params']['vmServiceUri']):
                self.device = True
            return
        if not isinstance(event, dict):
            return
        if event.get('type') == 'testStart':
            test = event.get('test')
            if (isinstance(test, dict) and test.get('name') == TEST_NAME
                    and type(test.get('id')) is int and 0 <= test['id'] <= 2**31 - 1):
                if self.fixture_id is not None:
                    self.ambiguous = True
                else:
                    self.fixture_id = test['id']
        elif (event.get('type') == 'testDone' and self.fixture_id is not None
              and type(event.get('testID')) is int
              and event['testID'] == self.fixture_id):
            if (self.finished or event.get('skipped') is not False
                    or event.get('hidden') is not False
                    or not isinstance(event.get('result'), str)
                    or event['result'] not in {'success', 'failure', 'error'}
                    or event.get('retried', False) is not False):
                self.ambiguous = True
            else:
                self.finished = True

    def tool_line(self, raw, partial=False):
        # SummaryStatus writes the complete static start message and spaces
        # without a newline until completion/cancellation. At reader shutdown,
        # allow exactly that unterminated form, never a partial JSON event.
        for message, attribute in TOOL_STARTS.items():
            suffix = TOOL_PADDING
            if not partial:
                suffix += rb'(?:' + TOOL_DURATION + rb')?'
            if re.fullmatch(re.escape(message) + suffix, raw):
                setattr(self, attribute, True)
        if not partial and re.fullmatch(
                rb'Xcode build done\.' + TOOL_PADDING + TOOL_DURATION, raw):
            # Flutter emits this before checking buildResult.success. Never
            # describe this as build success, installation or test execution.
            self.xcode_returned = True

    def finish(self):
        if self.buffer or self.dropping:
            self.incomplete = True
            self.partial_line = True
        if self.buffer and not self.dropping and not self.input_limit:
            self.tool_line(bytes(self.buffer), partial=True)
        self.buffer.clear()

    def tool_summary(self, unavailable=False):
        def observed(value):
            return 'observed' if value and not unavailable else 'unknown'
        def limit(value):
            return 'unknown' if unavailable else ('yes' if value else 'no')
        return ('TOOL_PROGRESS: pod_start=' + observed(self.pod_started)
                + ' xcode_start=' + observed(self.xcode_started)
                + ' xcode_return=' + observed(self.xcode_returned)
                + ' input_limit=' + limit(self.input_limit)
                + ' line_limit=' + limit(self.line_limit)
                + ' partial_line=' + limit(self.partial_line))

    def summary(self, unavailable=False):
        device = 'observed' if self.device and not unavailable else 'unknown'
        fixture = 'unknown'
        if not unavailable and not self.ambiguous and self.fixture_id is not None:
            fixture = 'finish-observed' if self.finished else 'start-observed'
        stream = 'incomplete' if self.incomplete or unavailable else 'bounded'
        return f'PROGRESS: device_process={device} storage_test={fixture} stream={stream}'


class ProgressPipe:
    """Drain stdout alongside the unchanged bounded process wait.

    No raw spool/log. Memory is one 8 KiB chunk/line plus bounded JSON parsing.
    After 2 MB all bytes are discarded. Retained descendant pipes cannot make
    teardown unbounded. Reader exceptions never print arbitrary text.
    """
    def __init__(self):
        self.progress = MachineProgress()
        self.stop = threading.Event()
        self.failed = False
        self.reader, writer = os.pipe()
        self.writer = os.fdopen(writer, 'wb', buffering=0)
        self.thread = threading.Thread(target=self.drain, daemon=True)

    def __enter__(self):
        try:
            self.thread.start()
        except Exception:
            self.writer.close()
            os.close(self.reader)
            raise RuntimeError('Progress reader unavailable') from None
        return self

    def close_writer(self):
        self.writer.close()

    def drain(self):
        try:
            os.set_blocking(self.reader, False)
            while True:
                ready, _, _ = select.select([self.reader], [], [], 0.05)
                if ready:
                    chunk = os.read(self.reader, MAX_LINE)
                    if not chunk:
                        break
                    self.progress.feed(chunk)
                if self.stop.is_set():
                    self.progress.incomplete = True
                    break
        except Exception:
            self.failed = True
        finally:
            self.progress.finish()
            os.close(self.reader)

    def __exit__(self, *_):
        # A diagnostic fault must not replace the original process failure.
        try:
            self.close_writer()
            self.thread.join(timeout=0.2)
            if self.thread.is_alive():
                self.stop.set()
                self.thread.join(timeout=0.2)
            unavailable = self.failed or self.thread.is_alive()
            print(self.progress.tool_summary(unavailable), flush=True)
            print(self.progress.summary(unavailable), flush=True)
        except Exception:
            try:
                print('PROGRESS: device_process=unknown storage_test=unknown stream=incomplete', flush=True)
            except Exception:
                pass
        return False
