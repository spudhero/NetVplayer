#!/usr/bin/env python3
"""Start isolated real protocol services on loopback. Never connects to the user's NAS.

python3 script/file_service_acceptance.py prepare
NETVPLAYER_FILE_SERVICE_TEST_CONFIG=<printed path> swift test --filter realConfiguredProtocols
python3 script/file_service_acceptance.py cleanup <printed path>
"""
import argparse
import json
import pathlib
import shutil
import struct
import subprocess
import tempfile
import time
import urllib.request
import uuid

IMAGES = {
    'alist': 'xhofe/alist@sha256:30a8e42c7dc899477e6fee99fc858833a1ec159b43f81782932c04fe127d7c1f',
    'openList': 'openlistteam/openlist@sha256:c555c6e1c8af2aead38ed12ec761ac077fdf046d19cf033414be8e056aec6b64',
    'smb': 'ghcr.io/servercontainers/samba@sha256:ac7c406702a3bf4137fcd04ce031d87adbda1b819f698fe89a89b5ee46618dfb',
    'webDAV': 'bytemark/webdav@sha256:21eed0df1238d17766080425f9ef46da2c1130e3e3aa9eaf36794d2a72e7c616',
}
def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()

def request(port, endpoint, payload, token=''):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(f'http://127.0.0.1:{port}{endpoint}', data=data,
        headers={'Content-Type': 'application/json', 'Authorization': token})
    with urllib.request.urlopen(req, timeout=10) as response:
        result = json.load(response)
    if result.get('code') != 200:
        raise RuntimeError(f'{endpoint}: {result.get("code")} {result.get("message")}')
    return result.get('data')

def playback_fixtures(media):
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        raise RuntimeError('--playback-fixtures requires ffmpeg')
    movie = media / '播放测试.mp4'
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi',
        '-i', 'testsrc2=size=320x180:rate=24', '-t', '12', '-c:v', 'libx264',
        '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(movie)], check=True)
    (media / '播放测试.srt').write_text('1\n00:00:03,000 --> 00:00:05,000\n中文播放验收字幕\n', encoding='utf-8')
    large = media / '大文件播放.mp4'
    shutil.copyfile(movie, large)
    # A valid ISO BMFF free box creates a sparse, playable large-file fixture.
    total = 5_000_000_000
    with large.open('ab') as file:
        file.write(struct.pack('>I4sQ', 1, b'free', total - file.tell()))
        file.truncate(total)

def prepare(with_playback=False):
    root = pathlib.Path(tempfile.mkdtemp(prefix='netvplayer-files-'))
    media = root / 'media'; media.mkdir()
    with (media / '中文大文件.mkv').open('wb') as file:
        file.truncate(5_000_000_000)
    for index in range(451):
        (media / f'影片{index:04d}.mp4').write_bytes(b'fixture')
    (media / '中文大文件.srt').write_text('1\n00:00:00,000 --> 00:00:01,000\n测试字幕\n')
    if with_playback:
        playback_fixtures(media)
    configs, containers = [], []
    (root / 'containers.json').write_text('[]')
    for kind, port in [('webDAV', 18781), ('alist', 18782), ('openList', 18783), ('smb', 18445)]:
        name = root.name + '-' + kind.lower()
        options = ['run', '-d', '--name', name, '--label', 'netvplayer.file-service-test=true', '-p', f'127.0.0.1:{port}:' + ('445' if kind == 'smb' else ('80' if kind == 'webDAV' else '5244'))]
        if kind == 'webDAV':
            # This image chowns its isolated fixture directory during startup.
            options += ['-e', 'AUTH_TYPE=Basic', '-e', 'USERNAME=tester', '-e', 'PASSWORD=fixture-password', '-v', f'{media}:/var/lib/dav/data']
        elif kind == 'smb':
            options += ['-e', 'ACCOUNT_tester=fixture-password', '-e', 'UID_tester=1000', '-e', 'AVAHI_DISABLE=1', '-e', 'WSDD2_DISABLE=1', '-e', 'NETBIOS_DISABLE=1',
                        '-e', 'SAMBA_VOLUME_CONFIG_movies=[Movies]; path=/media; valid users=tester; guest ok=no; read only=yes; browseable=yes',
                        '-e', 'SAMBA_VOLUME_CONFIG_public=[Public]; path=/media; guest ok=yes; force user=tester; read only=yes; browseable=yes',
                        '-v', f'{media}:/media:ro']
        else:
            state = root / kind; state.mkdir()
            app = 'alist' if kind == 'alist' else 'openlist'
            options += ['--user', '0:0', '-e', 'PUID=0', '-e', 'PGID=0', '-v', f'{state}:/opt/{app}/data', '-v', f'{media}:/media:ro']
        docker(*options, IMAGES[kind]); containers.append(name)
        (root / 'containers.json').write_text(json.dumps(containers))
        if kind in ('alist', 'openList'):
            app = 'alist' if kind == 'alist' else 'openlist'
            token = None
            for attempt in range(30):
                try:
                    docker('exec', name, f'/opt/{app}/{app}', 'admin', 'set', 'fixture-password')
                    token = request(port, '/api/auth/login', {'username': 'admin', 'password': 'fixture-password'})['token']
                    break
                except Exception:
                    time.sleep(1)
            if token is None:
                raise RuntimeError(f'{kind} failed to start; fixtures retained at {root}')
            request(port, '/api/admin/storage/create', {'mount_path': '/库', 'driver': 'Local', 'order': 0, 'disabled': False,
                'addition': json.dumps({'root_folder_path': '/media', 'thumbnail': False}), 'remark': 'NetVplayer acceptance', 'cache_expiration': 0}, token)
        service = {'id': str(uuid.uuid4()), 'name': kind, 'kind': kind, 'address': ('smb' if kind == 'smb' else 'http') + f'://127.0.0.1:{port}',
                   'port': port, 'rootPath': '/库' if kind in ('alist', 'openList') else '/', 'share': 'Movies' if kind == 'smb' else '', 'domain': '', 'guest': False}
        configs.append({'service': service, 'credentials': {'username': 'admin' if kind in ('alist', 'openList') else 'tester', 'password': 'fixture-password', 'directoryPasswords': {}}})
    path = root / 'protocols.json'; path.write_text(json.dumps(configs, ensure_ascii=False))
    print(path)

def cleanup(path):
    root = pathlib.Path(path).parent
    for name in json.loads((root / 'containers.json').read_text()):
        if name.startswith(root.name + '-') and root.name.startswith('netvplayer-files-'):
            docker('rm', '-f', name)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('mode', choices=['prepare', 'cleanup']); parser.add_argument('path', nargs='?')
    parser.add_argument('--playback-fixtures', action='store_true', help='Generate a valid MP4, subtitles, and a 5 GB sparse playable MP4; requires ffmpeg')
    args = parser.parse_args()
    if args.mode == 'prepare': prepare(args.playback_fixtures)
    else: cleanup(args.path)
