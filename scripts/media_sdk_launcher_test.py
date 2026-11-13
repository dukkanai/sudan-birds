"""Offline launcher drift checks; never executes Deno or modifies production files."""
from pathlib import Path
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PINS = (
    'supabase/functions/_shared/r2.ts',
    'supabase/functions/_shared/presign.ts',
    'supabase/functions/_shared/image_stream.ts',
    'supabase/functions/_shared/stream_cleanup.ts',
    'supabase/functions/_shared/diagnostics.ts',
    'supabase/functions/_shared/auth.ts',
    'supabase/functions/_shared/backend_fetch.ts',
    'supabase/functions/_shared/http.ts',
    'supabase/functions/_shared/media_service.ts',
    'supabase/functions/_shared/media_trial.ts',
    'supabase/functions/_shared/codec_capacity.ts',
    'supabase/functions/_shared/images.ts',
    'supabase/functions/_shared/bounded_jpeg_encoder.ts',
    'supabase/functions/_shared/upload_input.ts',
    'supabase/functions/media/handler.ts',
    'supabase/functions/codec-diagnostic/fixture.ts',
    'supabase/functions/deno.json',
    'supabase/functions/package.json',
    'supabase/functions/package-lock.json',
    'scripts/media_sdk_fixture.ts',
    'scripts/media_sdk_resource.ts',
)


class LauncherTests(unittest.TestCase):
    def test_reviewed_source_pins_match_without_executing_launcher(self):
        launcher = (ROOT / 'scripts/media_sdk_resource.sh').read_text()
        blocks = re.findall(r"<<'PINS'\n(.*?)\nPINS", launcher, re.DOTALL)
        self.assertEqual(len(blocks), 1)
        entries = []
        for line in blocks[0].splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  (.+)', line)
            self.assertIsNotNone(match)
            entries.append((match.group(2), match.group(1)))
        self.assertEqual(len(entries), len(PINS))
        self.assertEqual({path for path, _ in entries}, set(PINS))
        # Resolve only the fixed repository paths above, never arbitrary paths
        # from a modified launcher. No subprocess, Deno or resource run occurs.
        expected = dict(entries)
        for path in PINS:
            with self.subTest(path=path):
                digest = hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                self.assertEqual(digest, expected[path])

    def test_each_reviewed_pin_rejects_drift_before_execution(self):
        for changed in PINS:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / 'scripts').mkdir()
                shutil.copy(ROOT / 'scripts/media_sdk_resource.sh', root / 'scripts')
                for source in PINS:
                    target = root / source
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy(ROOT / source, target)
                with (root / changed).open('a') as target:
                    target.write('\n// synthetic drift\n')
                result = subprocess.run(
                    ['bash', str(root / 'scripts/media_sdk_resource.sh'), '--run-local', 'burst'],
                    env={**os.environ, 'DENO_BIN': '/nonexistent-deno-test-only',
                         'DENO_DIR': '/nonexistent-cache-test-only'},
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn('pin changed', result.stderr)
                self.assertEqual(result.stdout, '')

    def test_argument_guards_run_before_source_checks(self):
        for args in ([], ['--run-local', 'https://example.com'], ['--run-hosted', 'burst']):
            result = subprocess.run(['bash', str(ROOT / 'scripts/media_sdk_resource.sh'), *args],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b'')


if __name__ == '__main__':
    unittest.main()
