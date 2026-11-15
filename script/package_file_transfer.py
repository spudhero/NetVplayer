#!/usr/bin/env python3
"""Bundle libssh2 and its dependencies privately; never require Homebrew at runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(path):
    return [line.strip().split(' (', 1)[0] for line in run('otool', '-L', str(path)).splitlines()[1:]]


def package(app):
    binary = app / 'Contents/MacOS/NetVplayerApp'
    roots = [Path(p) for p in dependencies(binary) if Path(p).name == 'libssh2.1.dylib']
    if len(roots) != 1 or not roots[0].is_file():
        raise RuntimeError('Missing linked libssh2.1.dylib; install libssh2 before building.')
    destination = app / 'Contents/Frameworks/FileTransfer'
    destination.mkdir(parents=True, exist_ok=True)
    licenses = app / 'Contents/Resources/ThirdPartyLicenses/FileTransfer'
    licenses.mkdir(parents=True, exist_ok=True)
    copied = {}
    runtime = roots[0].parent.parent
    receipt = json.loads((runtime / "receipt.json").read_text())
    shutil.copytree(runtime / "licenses", licenses, dirs_exist_ok=True)
    shutil.copyfile(runtime / "receipt.json", licenses / "build-receipt.json")

    def copy(source):
        resolved = source.resolve(strict=True)
        if source.name in copied:
            if copied[source.name] != resolved:
                raise RuntimeError('Conflicting dependency: ' + source.name)
            return
        expected = receipt["binaries"].get(source.name)
        if expected != hashlib.sha256(resolved.read_bytes()).hexdigest():
            raise RuntimeError("Runtime hash mismatch: " + source.name)
        copied[source.name] = resolved
        target = destination / source.name
        shutil.copyfile(resolved, target)
        target.chmod(0o755)
        run('install_name_tool', '-id', '@rpath/FileTransfer/' + source.name, str(target))
        for value in dependencies(resolved):
            if value.startswith(('/usr/lib/', '/System/Library/')):
                continue
            dependency = Path(value)
            if not dependency.is_absolute():
                raise RuntimeError('Unresolved dependency: ' + value)
            if dependency.resolve() != resolved:
                copy(dependency)
            run('install_name_tool', '-change', value, '@loader_path/' + dependency.name, str(target))
        run('codesign', '--force', '--sign', '-', str(target))

    copy(roots[0])
    run('install_name_tool', '-change', str(roots[0]), '@rpath/FileTransfer/' + roots[0].name, str(binary))
    manifest = {'build': receipt['inputs'], 'binaries': {name: {'sourceSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'bundledSHA256': hashlib.sha256((destination / name).read_bytes()).hexdigest()} for name, path in copied.items()}}
    (licenses / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Bundled FTP/SFTP runtime:', ', '.join(copied))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app-bundle', type=Path, required=True)
    package(parser.parse_args().app_bundle)
