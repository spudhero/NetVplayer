#!/usr/bin/env python3
"""Reproducibly build the app-owned Android dialog renderer; never modify a component."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile
from android_presentation import validate_presentation

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / 'android-presentation/src/main/java/com/netvplayer/provider/android' / name
           for name in ('DesktopAndroidUI.java', 'DesktopAndroidTheme.java', 'DesktopPlaybackContext.java')]
DESTINATION = ROOT / 'NetVplayer/Sources/NetVplayerApp/Resources/AndroidPresentation'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, help='Verified Android runtime with JDK 21 and desktop UI framework')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    jar = DESTINATION / 'android-presentation.jar'
    manifest = DESTINATION / 'provenance.json'
    source_hashes = {p.relative_to(ROOT).as_posix(): sha(p) for p in SOURCES}
    if args.verify:
        errors = validate_presentation(DESTINATION, repo=ROOT)
        if errors:
            raise SystemExit('Android presentation verification failed: ' + ', '.join(errors))
        print('Android presentation source and archive digests verified')
        return
    if not args.runtime:
        parser.error('--runtime is required to build')
    runtime = args.runtime.resolve(strict=True)
    framework = runtime / 'lib/android-framework.jar'
    adapter = runtime / 'lib/android-adapter.jar'
    if not (runtime / 'desktop-ui-framework-provenance.json').is_file():
        parser.error('Runtime must have the inspected desktop UI framework')
    dependencies = {'android-framework.jar': sha(framework), 'android-adapter.jar': sha(adapter)}
    expected = json.loads(manifest.read_text())['compileDependencies']
    if dependencies != expected:
        parser.error('Compile dependency digests differ from the reviewed provenance')
    with tempfile.TemporaryDirectory(prefix='netvplayer-dialog-') as temporary:
        classes = Path(temporary)
        subprocess.run([str(runtime / 'jdk/bin/javac'), '--release', '21', '-encoding', 'UTF-8',
                        '-cp', str(framework) + ':' + str(adapter), '-d', str(classes),
                        *map(str, SOURCES)], check=True)
        DESTINATION.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(jar, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(classes.rglob('*.class')):
                info = zipfile.ZipInfo(path.relative_to(classes).as_posix(), (1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes())
    manifest.write_text(json.dumps(dict(schema=1, javaRelease=21, sources=source_hashes,
        compileDependencies={'android-framework.jar': sha(framework), 'android-adapter.jar': sha(adapter)},
        archiveSHA256=sha(jar)), indent=2) + '\n')
    print(sha(jar))


if __name__ == '__main__':
    main()
