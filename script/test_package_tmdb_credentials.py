import json
from io import BytesIO
import tempfile
import unittest
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit

from script.package_tmdb_credentials import audit, credential, inject, verify_online


class Response(BytesIO):
    status = 200


RESPONSES = (
    {'results': [{'id': 278}]},
    {'id': 278, 'title': '肖申克的救赎', 'poster_path': '/movie.jpg', 'vote_average': 8.7},
    {'results': [{'id': 1399}]},
    {'id': 1399, 'name': '权力的游戏', 'poster_path': '/tv.jpg', 'vote_average': 8.5},
)

class TMDBPackagingTests(unittest.TestCase):
    def test_injection_and_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Test.app'
            target = app / 'Contents/Resources/TMDB.json'
            self.assertFalse(inject(app, {}))
            self.assertTrue(inject(app, {'NETVPLAYER_TMDB_API_KEY': 'fixture-app-key'}))
            self.assertEqual(json.loads(target.read_text()), {'kind': 'apiKey', 'value': 'fixture-app-key'})
            self.assertTrue(inject(app, {'NETVPLAYER_TMDB_READ_ACCESS_TOKEN': 'fixture-app-token'}))
            self.assertEqual(json.loads(target.read_text())['kind'], 'readAccessToken')
            self.assertFalse(inject(app, {})); self.assertFalse(target.exists())

    def test_invalid_configuration(self):
        with self.assertRaises(ValueError): credential({}, require=True)
        with tempfile.TemporaryDirectory() as directory:
            for environ in ({'NETVPLAYER_TMDB_API_KEY': 'a', 'NETVPLAYER_TMDB_READ_ACCESS_TOKEN': 'b'},
                            {'NETVPLAYER_TMDB_API_KEY': 'a\nb'}, {'NETVPLAYER_TMDB_API_KEY': 'a' * 4097}):
                with self.assertRaises(ValueError): inject(directory, environ)

    def test_bundle_audit_rejects_missing_changed_and_corrupt_credentials(self):
        environ = {'NETVPLAYER_TMDB_READ_ACCESS_TOKEN': 'fixture-release-token'}
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Test.app'
            target = app / 'Contents/Resources/TMDB.json'
            with self.assertRaisesRegex(ValueError, 'missing'):
                audit(app, environ, require=True)
            inject(app, environ, require=True)
            self.assertEqual(audit(app, environ, require=True), credential(environ))
            with self.assertRaisesRegex(ValueError, 'does not match'):
                audit(app, {'NETVPLAYER_TMDB_API_KEY': 'fixture-other-key'}, require=True)
            target.write_text('invalid fixture-release-token')
            with self.assertRaisesRegex(ValueError, '^Packaged TMDB credential is unreadable$'):
                audit(app, environ, require=True)

    def test_optional_bundle_cannot_keep_a_stale_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(audit(directory, {}))
            inject(directory, {'NETVPLAYER_TMDB_API_KEY': 'fixture-key'})
            with self.assertRaisesRegex(ValueError, 'does not match'):
                audit(directory, {})


class TMDBOnlineVerificationTests(unittest.TestCase):
    def test_movie_and_tv_queries_use_chinese_and_application_authentication(self):
        for kind in ('apiKey', 'readAccessToken'):
            with self.subTest(kind=kind):
                requests = []

                def open_request(request, timeout):
                    requests.append(request)
                    self.assertEqual(timeout, 20)
                    return Response(json.dumps(RESPONSES[len(requests) - 1]).encode())

                verify_online({'kind': kind, 'value': 'fixture-secret'}, open_request)
                self.assertEqual(len(requests), 4)
                self.assertEqual([urlsplit(r.full_url).path for r in requests],
                                 ['/3/search/movie', '/3/movie/278', '/3/search/tv', '/3/tv/1399'])
                for request in requests:
                    url = urlsplit(request.full_url)
                    self.assertEqual((url.scheme, url.netloc), ('https', 'api.themoviedb.org'))
                    query = parse_qs(url.query)
                    self.assertEqual(query['language'], ['zh-CN'])
                    if kind == 'apiKey':
                        self.assertEqual(query['api_key'], ['fixture-secret'])
                        self.assertIsNone(request.get_header('Authorization'))
                    else:
                        self.assertNotIn('api_key', query)
                        self.assertNotIn('fixture-secret', request.full_url)
                        self.assertEqual(request.get_header('Authorization'), 'Bearer fixture-secret')
                self.assertEqual(parse_qs(urlsplit(requests[0].full_url).query)['query'], ['肖申克的救赎'])
                self.assertEqual(parse_qs(urlsplit(requests[2].full_url).query)['query'], ['权力的游戏'])

    def test_errors_hide_credentials_and_response_bodies(self):
        errors = (
            (HTTPError('https://api.themoviedb.org/3?api_key=fixture-secret', 401,
                       'fixture-secret', {}, BytesIO(b'fixture-secret')), 'HTTP 401'),
            (HTTPError('https://other.example/fixture-secret', 302, 'fixture-secret', {}, None), 'HTTP 302'),
            (URLError('fixture-secret'), 'could not connect'),
        )
        for error, message in errors:
            with self.subTest(message=message):
                def open_request(request, timeout):
                    raise error
                with self.assertRaisesRegex(ValueError, message) as caught:
                    verify_online({'kind': 'apiKey', 'value': 'fixture-secret'}, open_request)
                self.assertNotIn('fixture-secret', str(caught.exception))
                self.assertNotIn('https://', str(caught.exception))

    def test_missing_credential_cannot_skip_online_verification(self):
        with self.assertRaisesRegex(ValueError, 'requires an application credential'):
            verify_online(None)

    def test_success_status_with_invalid_or_oversized_data_is_rejected(self):
        for payload in (b'fixture-secret', b'\xff', b'[]', b'x' * (2 * 1024 * 1024 + 1)):
            with self.subTest(payload_size=len(payload)):
                with self.assertRaises(ValueError) as caught:
                    verify_online({'kind': 'readAccessToken', 'value': 'fixture-secret'},
                                  lambda request, timeout: Response(payload))
                self.assertNotIn('fixture-secret', str(caught.exception))

    def test_acceptance_requires_expected_title_poster_and_rating(self):
        for index, result in (
            (0, {'results': [{'id': 1}]}),
            (1, dict(RESPONSES[1], title='')),
            (1, dict(RESPONSES[1], poster_path=None)),
            (3, dict(RESPONSES[3], vote_average='8.5')),
        ):
            with self.subTest(index=index, result=result):
                responses = iter(RESPONSES[:index] + (result,) + RESPONSES[index + 1:])
                with self.assertRaisesRegex(ValueError, 'expected metadata'):
                    verify_online({'kind': 'apiKey', 'value': 'fixture-secret'},
                                  lambda request, timeout: Response(json.dumps(next(responses)).encode()))

if __name__ == '__main__': unittest.main()
