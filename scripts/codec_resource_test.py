import copy
import json
import unittest
import urllib.request
import urllib.error
from codec_resource import local_entrypoint, require_sdk_import_marker, endpoint, metrics, NoRedirect, TOKEN, require_verified_gateway, safe_failure, diagnostic_error, diagnostic_details


class Boundaries(unittest.TestCase):
    def test_local_sdk_import_entrypoint(self):
        source = local_entrypoint('2026-11-08T00:20:00.000Z')
        self.assertIn('import * as r2 from "../_shared/r2.ts";', source)
        self.assertIn('import * as auth from "../_shared/auth.ts";', source)
        self.assertIn('Object.values(r2)', source)
        self.assertIn('Object.values(auth)', source)
        self.assertIn('r2Exports.length !== 5', source)
        self.assertIn('authExports.length !== 7', source)
        self.assertIn('await diagnostic(req)', source)
        self.assertIn('"2026-11-08T00:20:00.000Z"', source)
        self.assertIn(json.dumps(TOKEN), source)
        for forbidden in ('Deno.env', 'fetch(', 'r2.', 'auth.', 'Date.now('):
            # Module specifiers contain r2.ts/auth.ts, so inspect after imports.
            self.assertNotIn(forbidden, source[source.index('const diagnostic'):])

    def test_sdk_import_marker_required(self):
        require_sdk_import_marker('r2-5-auth-7')
        for value in (None, '', 'true', 'r2-5-auth-7-extra'):
            with self.assertRaises(ValueError):
                require_sdk_import_marker(value)

    def test_failure_memory_is_numeric_and_allowlisted(self):
        payload = {'error': 'diagnostic_unavailable', 'calls': 3, 'secret': 'hidden',
                   'memory': {'rss': 300000000, 'heapUsed': 120000000,
                              'heapTotal': 160000000, 'external': 20000000,
                              'secret': 'hidden'}}
        details = diagnostic_details(json.dumps(payload).encode())
        error = urllib.error.HTTPError('http://127.0.0.1', 503, 'hidden', {}, None)
        result = safe_failure({'phase': 'request', **details}, error)
        self.assertEqual(result['diagnostic_calls'], 3)
        self.assertEqual(result['diagnostic_memory']['heapUsed'], 120000000)
        self.assertNotIn('hidden', json.dumps(result))
        for value in (True, -1, 2**53, 'hidden'):
            payload['memory']['external'] = value
            self.assertNotIn('diagnostic_memory', diagnostic_details(json.dumps(payload).encode()))
        payload['error'] = 'empty_post_required'
        self.assertNotIn('diagnostic_calls', diagnostic_details(json.dumps(payload).encode()))

    def test_verify_gateway_required(self):
        require_verified_gateway('[functions.codec-diagnostic]\nverify_jwt = true')
        for text in ('', '[functions.codec-diagnostic]\nverify_jwt = false',
                     '[functions.codec-diagnostic]\nverify_jwt = "true"'):
            with self.assertRaises(ValueError):
                require_verified_gateway(text)

    def test_safe_failure(self):
        error = urllib.error.HTTPError('https://secret.example', 546, 'secret', {}, None)
        self.assertEqual(safe_failure({'phase': 'request', 'request': 7}, error),
                         dict(error='LOCAL_EDGE_PROBE_FAILED', phase='request',
                              request=7, http_status=546))
        result = safe_failure({'phase': 'secret', 'request': 'secret', 'status': 'secret'},
                              ValueError('secret'))
        self.assertEqual(result, dict(error='LOCAL_EDGE_PROBE_FAILED', phase='setup'))
        self.assertEqual(safe_failure({'phase': 'response_validation', 'status': 200},
                                      ValueError('secret'))['http_status'], 200)

    def test_diagnostic_error_allowlist(self):
        self.assertEqual(diagnostic_error(b'{"error":"empty_post_required","secret":"hidden"}'),
                         'empty_post_required')
        for raw in (b'{"error":"secret"}', b'[]', b'{"error":[]}', b'invalid', b'x' * 4097):
            self.assertIsNone(diagnostic_error(raw))
        failure = safe_failure({'phase': 'request', 'diagnostic_error': 'diagnostic_unavailable'},
                               ValueError('secret'))
        self.assertEqual(failure['diagnostic_error'], 'diagnostic_unavailable')
        self.assertNotIn('diagnostic_error', safe_failure({'diagnostic_error': 'secret'}, ValueError()))

    def test_loopback(self):
        self.assertEqual(endpoint('http://127.0.0.1:54321'),
                         'http://127.0.0.1:54321/functions/v1/codec-diagnostic')
        for value in ('https://example.com', 'http://localhost:54321',
                      'http://127.0.0.1.evil:80', 'http://user@127.0.0.1:80',
                      'http://127.0.0.1:80/?x=1', 'http://127.0.0.1:80/#x',
                      'http://127.0.0.1:80/other', 'http://127.0.0.1'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                endpoint(value)

    def test_redirect_denied(self):
        with self.assertRaises(ValueError):
            NoRedirect().redirect_request(None, None, None, None, None)

    def test_metrics(self):
        data = dict(expires_at='fixed', calls=2, width=640, height=640,
                    output_bytes=100000, elapsed_ms=150,
                    before=dict(rss=300_000_000, heapUsed=1000, heapTotal=2000, external=100),
                    after=dict(rss=300_000_000, heapUsed=1000, heapTotal=2000, external=100),
                    secret='must not pass through')
        self.assertNotIn('secret', metrics(data, 'fixed'))
        for key, value in [('calls', 0), ('calls', True), ('width', 641),
                           ('output_bytes', 2_097_153), ('elapsed_ms', -1),
                           ('expires_at', 'different'), ('after', {})]:
            bad = copy.deepcopy(data)
            bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                metrics(bad, 'fixed')

    def test_synthetic_token_and_bodyless_post(self):
        self.assertEqual(len(TOKEN), 43)
        self.assertIsNone(urllib.request.Request('http://127.0.0.1:1', method='POST').data)


if __name__ == '__main__':
    unittest.main()
