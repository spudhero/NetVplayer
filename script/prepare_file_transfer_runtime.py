#!/usr/bin/env python3
"""Build libssh2 for macOS 14 using the already verified player OpenSSL runtime."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'NetVplayer/.build'
OUTPUT = BUILD / 'file-transfer-runtime'
VERSION = '1.11.1'
SOURCE_SHA256 = 'd9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def prepare():
    player = Path(os.environ.get('NETVPLAYER_LIBMPV_RUNTIME_BUNDLE', BUILD / 'dolby-runtime/runtime.app'))
    frameworks = player / 'Contents/Frameworks'
    license_root = player / 'Contents/Resources/ThirdPartyLicenses'
    manifest = json.loads((license_root / 'libmpv-runtime.json').read_text())
    openssl = next(c for c in manifest['components'] if c['formula'] == 'openssl@3')
    header_root = Path(os.environ.get('NETVPLAYER_OPENSSL_HEADERS', '/opt/homebrew/opt/openssl@3/include'))
    receipt = {'version': VERSION, 'sourceSHA256': SOURCE_SHA256, 'deploymentTarget': '14.0',
        'recipeSHA256': digest(Path(__file__)), 'openssl': openssl,
        'headersVersionSHA256': digest(header_root / 'openssl/opensslv.h'),
        'cryptoSHA256': digest(frameworks / 'libcrypto.3.dylib'), 'sslSHA256': digest(frameworks / 'libssl.3.dylib')}
    stamp = OUTPUT / 'receipt.json'
    if stamp.exists():
        saved = json.loads(stamp.read_text())
        if saved.get('inputs') == receipt and all((OUTPUT / 'lib' / name).is_file() and digest(OUTPUT / 'lib' / name) == sha for name, sha in saved['binaries'].items()):
            print('FTP/SFTP runtime verified:', VERSION)
            return
    for name in ['libcrypto.3.dylib', 'libssl.3.dylib']:
        info = subprocess.check_output(['otool', '-l', str(frameworks / name)], text=True)
        for line in info.splitlines():
            if line.strip().startswith('minos ') and int(line.split()[1].split('.')[0]) > 14:
                raise RuntimeError(name + ' is incompatible with macOS 14')
    work = BUILD / 'file-transfer-source'
    work.mkdir(parents=True, exist_ok=True)
    archive = work / ('libssh2-' + VERSION + '.tar.gz')
    if not archive.exists():
        run('curl', '-fL', '--retry', '2', '--max-time', '120', 'https://www.libssh2.org/download/' + archive.name, '-o', archive)
    if digest(archive) != SOURCE_SHA256:
        raise RuntimeError('libssh2 source checksum mismatch')
    source = work / ('libssh2-' + VERSION)
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(work, filter='data')
    (OUTPUT / 'lib').mkdir(parents=True, exist_ok=True)
    shutil.copytree(header_root / 'openssl', OUTPUT / 'include/openssl', dirs_exist_ok=True)
    for name in ['libcrypto.3.dylib', 'libssl.3.dylib']:
        target = OUTPUT / 'lib' / name
        shutil.copyfile(frameworks / name, target); target.chmod(0o755)
        run('install_name_tool', '-id', target, target)
        if name == 'libssl.3.dylib':
            run('install_name_tool', '-change', '@rpath/libcrypto.3.dylib', OUTPUT / 'lib/libcrypto.3.dylib', target)
        run('codesign', '--force', '--sign', '-', target)
        link = OUTPUT / 'lib' / name.replace('.3', '')
        if not link.exists(): link.symlink_to(name)
    environment = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='14.0',
        CFLAGS='-O2 -mmacosx-version-min=14.0', CPPFLAGS='-I' + str(OUTPUT / 'include'), LDFLAGS='-L' + str(OUTPUT / 'lib'))
    run(source / 'configure', '--prefix=' + str(OUTPUT), '--with-crypto=openssl', '--with-libssl-prefix=' + str(OUTPUT),
        '--disable-examples-build', '--disable-tests', '--disable-static', '--without-libz', cwd=source, env=environment)
    run('make', '-j4', cwd=source, env=environment)
    run('make', 'install', cwd=source, env=environment)
    licenses = OUTPUT / 'licenses'
    licenses.mkdir(exist_ok=True)
    shutil.copyfile(source / 'COPYING', licenses / 'libssh2.COPYING')
    shutil.copyfile(license_root / 'libmpv/openssl@3/LICENSE.txt', licenses / 'OpenSSL.LICENSE.txt')
    stamp.write_text(json.dumps({'inputs': receipt, 'binaries': {p.name: digest(p) for p in (OUTPUT / 'lib').glob('*.dylib') if not p.is_symlink()}}, indent=2) + '\n')


if __name__ == '__main__':
    prepare()
