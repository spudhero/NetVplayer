#!/usr/bin/env python3
"""Inject publisher-owned application credentials without echoing them or checking them into git."""
import argparse
import json
import os
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener


def credential(environ, require=False):
    key = environ.get('NETVPLAYER_TMDB_API_KEY', '').strip()
    token = environ.get('NETVPLAYER_TMDB_READ_ACCESS_TOKEN', '').strip()
    if key and token:
        raise ValueError('Configure one TMDB application credential type')
    value = token or key
    if not value:
        if require:
            raise ValueError('Public releases require a NetVplayer-owned TMDB application credential')
        return None
    if len(value.encode()) > 4096 or '\n' in value or '\r' in value:
        raise ValueError('Invalid TMDB application credential')
    return {'kind': 'readAccessToken' if token else 'apiKey', 'value': value}


def inject(app_bundle, environ, require=False):
    value = credential(environ, require)
    target = Path(app_bundle) / 'Contents' / 'Resources' / 'TMDB.json'
    if value is None:
        target.unlink(missing_ok=True)
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(value))
    return True


def audit(app_bundle, environ, require=False):
    expected = credential(environ, require)
    target = Path(app_bundle) / 'Contents' / 'Resources' / 'TMDB.json'
    if not target.is_file():
        if expected or require:
            raise ValueError('Packaged application is missing its TMDB credential')
        return None
    try:
        stored = json.loads(target.read_text())
    except (ValueError, OSError):
        raise ValueError('Packaged TMDB credential is unreadable') from None
    if not expected or stored != expected:
        raise ValueError('Packaged TMDB credential does not match the release configuration')
    return stored


class _NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


def verify_online(value, open_request=None):
    """Read-only acceptance against TMDB; never emit URLs, credentials or response bodies."""
    if value is None:
        raise ValueError('Online TMDB verification requires an application credential')
    open_request = open_request or build_opener(_NoRedirects()).open
    checks = (
        ('movie search', 'search/movie', {'query': '肖申克的救赎', 'year': '1994'}, 278, 'results'),
        ('movie detail', 'movie/278', {}, 278, 'title'),
        ('TV search', 'search/tv', {'query': '权力的游戏', 'first_air_date_year': '2011'}, 1399, 'results'),
        ('TV detail', 'tv/1399', {}, 1399, 'name'),
    )
    for stage, path, params, expected_id, field in checks:
        query = dict(params, language='zh-CN')
        headers = {'Accept': 'application/json'}
        if value['kind'] == 'apiKey':
            query['api_key'] = value['value']
        else:
            headers['Authorization'] = 'Bearer ' + value['value']
        request = Request('https://api.themoviedb.org/3/' + path + '?' + urlencode(query), headers=headers)
        try:
            with open_request(request, timeout=20) as response:
                if response.status != 200:
                    raise ValueError(f'TMDB {stage} failed (HTTP {response.status})')
                data = response.read(2 * 1024 * 1024 + 1)
                if len(data) > 2 * 1024 * 1024:
                    raise ValueError(f'TMDB {stage} response exceeded the size limit')
                result = json.loads(data)
        except HTTPError as error:
            raise ValueError(f'TMDB {stage} failed (HTTP {error.code})') from None
        except (URLError, OSError):
            raise ValueError(f'TMDB {stage} could not connect; check network access') from None
        except (UnicodeError, json.JSONDecodeError):
            raise ValueError(f'TMDB {stage} returned an invalid response') from None
        if not isinstance(result, dict):
            raise ValueError(f'TMDB {stage} returned an invalid response')
        if field == 'results':
            candidates = result.get('results')
            valid = isinstance(candidates, list) and any(isinstance(item, dict) and item.get('id') == expected_id for item in candidates)
        else:
            valid = result.get('id') == expected_id and isinstance(result.get(field), str) and bool(result[field])
            valid = valid and isinstance(result.get('poster_path'), str) and result['poster_path'].startswith('/')
            valid = valid and isinstance(result.get('vote_average'), (int, float))
        if not valid:
            raise ValueError(f'TMDB {stage} did not return the expected metadata')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app-bundle'); parser.add_argument('--require', action='store_true')
    parser.add_argument('--validate-only', action='store_true')
    parser.add_argument('--audit-only', action='store_true')
    parser.add_argument('--verify-online', action='store_true')
    args = parser.parse_args()
    try:
        if args.audit_only:
            if not args.app_bundle: parser.error('--app-bundle is required')
            value = audit(args.app_bundle, os.environ, args.require)
            configured = value is not None
        elif args.validate_only:
            value = credential(os.environ, args.require)
            configured = value is not None
        else:
            if not args.app_bundle: parser.error('--app-bundle is required')
            if args.verify_online: parser.error('--verify-online requires --validate-only or --audit-only')
            configured = inject(args.app_bundle, os.environ, args.require)
        if args.verify_online:
            verify_online(value)
            print('TMDB Chinese movie and TV search, details, ratings and poster metadata verified')
    except ValueError as error:
        parser.exit(1, str(error) + '\n')
    print('TMDB application credential configured' if configured else 'TMDB application credential absent; local/Douban metadata remain available')
