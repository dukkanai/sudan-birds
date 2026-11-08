import copy
import unittest
import urllib.request
import urllib.error
from codec_resource import endpoint, metrics, NoRedirect, TOKEN, require_verified_gateway, safe_failure


class Boundaries(unittest.TestCase):
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
