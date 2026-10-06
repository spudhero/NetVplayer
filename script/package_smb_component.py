#!/usr/bin/env python3
"""Ship the pinned SMB licenses and complete source used by the dynamically linked component."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

AMSMB_REVISION = '1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0'
LIBSMB_REVISION = 'aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03'


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def package(checkout, app):
    checkout = Path(checkout)
    libsmb = checkout / 'Dependencies/libsmb2'
    if git(checkout, 'rev-parse', 'HEAD').decode().strip() != AMSMB_REVISION or git(libsmb, 'rev-parse', 'HEAD').decode().strip() != LIBSMB_REVISION:
        raise ValueError('SMB checkout does not match the fixed release source')
    for root in (checkout, libsmb):
        subprocess.run(['git', '-C', str(root), 'diff', '--exit-code', '--quiet', 'HEAD', '--'], check=True)
    notices = Path(app) / 'Contents/Resources/ThirdPartyLicenses'
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(checkout / 'LICENSE', notices / 'AMSMB2.LGPL-2.1.txt')
    shutil.copyfile(libsmb / 'LICENCE-LGPL-2.1.txt', notices / 'libsmb2.LGPL-2.1.txt')
    archive = notices / 'SMB-SOURCE.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        for root, prefix in ((checkout, 'AMSMB2-4.0.3'), (libsmb, 'AMSMB2-4.0.3/Dependencies/libsmb2')):
            for raw in git(root, 'ls-files', '-z').split(b'\0'):
                if not raw: continue
                relative = Path(raw.decode())
                source = root / relative
                if source.is_file() or source.is_symlink(): tar.add(source, arcname=str(Path(prefix) / relative), recursive=False)
    (notices / 'SMB-SOURCE.txt').write_text(
        'AMSMB2 4.0.3 (LGPL-2.1): https://github.com/amosavian/AMSMB2/tree/' + AMSMB_REVISION + '\n'
        'libsmb2 (LGPL-2.1): https://github.com/sahlberg/libsmb2/tree/' + LIBSMB_REVISION + '\n'
        'Complete corresponding source is included in SMB-SOURCE.tar.gz.\n'
        'Build a compatible dynamic library with swift build --configuration release --product AMSMB2.\n'
        'The component is in Contents/Frameworks/SMB/libAMSMB2.dylib and can be replaced by a compatible build; re-sign the bundle after replacement.\n'
    )
    manifest = {'license_sha256': {name: hashlib.sha256((notices / name).read_bytes()).hexdigest() for name in ('AMSMB2.LGPL-2.1.txt', 'libsmb2.LGPL-2.1.txt', 'SMB-SOURCE.txt')}, 'source_archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'components': [
        {'name': 'AMSMB2', 'version': '4.0.3', 'source': 'https://github.com/amosavian/AMSMB2', 'revision': AMSMB_REVISION, 'license': 'LGPL-2.1-or-later'},
        {'name': 'libsmb2', 'version': LIBSMB_REVISION, 'source': 'https://github.com/sahlberg/libsmb2', 'revision': LIBSMB_REVISION, 'license': 'LGPL-2.1-or-later'}]}
    (notices / 'smb-runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
    audit(app)


def audit(app):
    libraries = Path(app) / 'Contents/Frameworks/SMB'
    if {path.name for path in libraries.glob('*.dylib')} != {'libAMSMB2.dylib'}:
        raise ValueError('SMB dynamic library coverage is incomplete')
    if (libraries / 'libAMSMB2.dylib').stat().st_size == 0:
        raise ValueError('SMB dynamic library is empty')
    notices = Path(app) / 'Contents/Resources/ThirdPartyLicenses'
    manifest = json.loads((notices / 'smb-runtime.json').read_text())
    components = manifest.get('components', [])
    if [(c.get('name'), c.get('revision'), c.get('license')) for c in components] != [
        ('AMSMB2', AMSMB_REVISION, 'LGPL-2.1-or-later'),
        ('libsmb2', LIBSMB_REVISION, 'LGPL-2.1-or-later'),
    ]:
        raise ValueError('SMB component provenance is invalid')
    hashes = manifest.get('license_sha256', {})
    if set(hashes) != {'AMSMB2.LGPL-2.1.txt', 'libsmb2.LGPL-2.1.txt', 'SMB-SOURCE.txt'}:
        raise ValueError('SMB license coverage is incomplete')
    hashes = dict(hashes, **{'SMB-SOURCE.tar.gz': manifest.get('source_archive_sha256')})
    for name, expected in hashes.items():
        path = notices / name
        if not path.is_file() or path.stat().st_size == 0 or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f'SMB license or source hash mismatch: {name}')
    return {'components': len(components), 'license_files': 2, 'source_archive': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--checkout')
    parser.add_argument('--app-bundle', required=True)
    parser.add_argument('--audit-only', action='store_true')
    args = parser.parse_args()
    if args.audit_only:
        if args.checkout:
            parser.error('--audit-only cannot be combined with --checkout')
        print(json.dumps(audit(args.app_bundle), sort_keys=True))
    else:
        if not args.checkout:
            parser.error('--checkout is required for packaging')
        package(args.checkout, args.app_bundle)
