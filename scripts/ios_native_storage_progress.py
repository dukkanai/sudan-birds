"""Bounded diagnostic-only Flutter machine progress; never retain raw output."""
import json
import os
import select
import threading

TEST_NAME = 'real native storage and restore fence smoke'
MAX_LINE = 8192
MAX_INPUT = 2_000_000


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
    array. Dart's JSON reporter emits testStart/testDone objects. All human
    output, URIs, errors and arbitrary test names are discarded.
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

    def feed(self, chunk):
        self.total = min(MAX_INPUT + 1, self.total + len(chunk))
        if self.total > MAX_INPUT:
            self.buffer.clear()
            self.incomplete = True
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
                else:
                    self.buffer.append(byte)

    def line(self, raw):
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
            if self.progress.buffer or self.progress.dropping:
                self.progress.incomplete = True
            self.progress.buffer.clear()
            os.close(self.reader)

    def __exit__(self, *_):
        # A diagnostic fault must not replace the original process failure.
        try:
            self.close_writer()
            self.thread.join(timeout=0.2)
            if self.thread.is_alive():
                self.stop.set()
                self.thread.join(timeout=0.2)
            print(self.progress.summary(self.failed or self.thread.is_alive()), flush=True)
        except Exception:
            try:
                print('PROGRESS: device_process=unknown storage_test=unknown stream=incomplete', flush=True)
            except Exception:
                pass
        return False
