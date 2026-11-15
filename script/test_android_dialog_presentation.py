#!/usr/bin/env python3
"""Offline dialog regressions using the shipped presentation JAR and original runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--gallery', action='store_true')
    parser.add_argument('--theme-file', type=Path)
    parser.add_argument('--render-directory', type=Path, help='Export realized fixture component pixels, not OS screenshots')
    parser.add_argument('--baseline', action='store_true', help='Render with the unchanged component UI first on classpath')
    parser.add_argument('--cases', nargs='+', choices=['authorization', 'theme', 'normal', 'disabled', 'headless', 'playback', 'layout'],
                        help='Run selected cases while a live app owns the fixed playback-context port')
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    runtime = args.runtime.resolve(strict=True)
    archive = ROOT / 'NetVplayer/Sources/NetVplayerApp/Resources/AndroidPresentation/android-presentation.jar'
    tests = ROOT / 'android-presentation/src/test/java/com/netvplayer/provider/android/test'
    dependencies = [archive, *sorted((runtime / 'lib').glob('*.jar')), *sorted((runtime / 'compat').glob('*.jar'))]
    if args.baseline:
        if not args.render_directory: parser.error('--baseline requires --render-directory')
        adapter = runtime / 'lib/android-adapter.jar'
        dependencies = [adapter, archive, *[p for p in dependencies[1:] if p != adapter]]
    sources = [tests / p for p in ('AndroidDialogContract.java', 'AndroidDialogMacSmoke.java', 'DesktopAndroidThemeSmoke.java', 'AndroidPlaybackContextSmoke.java', 'AndroidDialogLayoutSmoke.java', 'AndroidCloudAuthorizationSmoke.java')]
    classes = out / 'classes'; classes.mkdir()
    cp = os.pathsep.join(map(str, dependencies))
    subprocess.run([str(runtime / 'jdk/bin/javac'), '--release', '21', '-encoding', 'UTF-8', '-cp', cp,
                    '-d', str(classes), *map(str, sources)], check=True)
    theme = args.theme_file if args.gallery and args.theme_file else out / 'theme.properties'
    command = [str(runtime / 'jdk/bin/java'), '-Xverify:all', '-Dnetvplayer.android.backend=emulated',
               '-Dnetvplayer.android.desktopUI=true', '-Dnetvplayer.android.dataDir=' + str(out / 'state'),
               '-Dnetvplayer.android.package=com.netvplayer.platformfixture',
               '-Dnetvplayer.android.layoutOutput=' + str(out / 'layout-images'),
               '-Dnetvplayer.android.themeFile=' + str(theme), '-cp', str(classes) + os.pathsep + cp]
    if args.gallery:
        subprocess.run([*command, 'com.netvplayer.provider.android.test.DesktopAndroidThemeSmoke', 'gallery'], check=True)
        return
    if args.render_directory:
        subprocess.run([*command, 'com.netvplayer.provider.android.test.DesktopAndroidThemeSmoke',
                        'export', str(args.render_directory.resolve())], check=True)
        return
    rows = []
    for name, target, extra in [('authorization', 'AndroidCloudAuthorizationSmoke', []), ('theme', 'DesktopAndroidThemeSmoke', []), ('normal', 'AndroidDialogMacSmoke', ['normal']),
                                ('disabled', 'AndroidDialogMacSmoke', ['disabled']), ('headless', 'AndroidDialogMacSmoke', ['headless']),
                                ('playback', 'AndroidPlaybackContextSmoke', []), ('layout', 'AndroidDialogLayoutSmoke', [])]:
        if args.cases and name not in args.cases: continue
        options = ['-Dnetvplayer.android.desktopUI=false'] if name == 'disabled' else ['-Djava.awt.headless=true'] if name == 'headless' else []
        log = out / (name + '.log')
        # JVM options precede the application class. The last duplicate property wins.
        with log.open('w') as f:
            p = subprocess.run([*command, *options, 'com.netvplayer.provider.android.test.' + target, *extra],
                               stdout=f, stderr=subprocess.STDOUT, timeout=80)
        lines = log.read_text().splitlines()
        assertions = [line for line in lines if line.startswith(('DIALOG_CASE ', 'DIALOG_HOST_CASE ', 'THEME_CASE ', 'PLAYBACK_CONTEXT_CASE ', 'LAYOUT_CASE ', 'AUTHORIZATION_CASE '))]
        passed = p.returncode == 0 and any(line.startswith(('THEME_CONTRACT_OK', 'DIALOG_MAC_CONTRACT_OK', 'PLAYBACK_CONTEXT_OK', 'LAYOUT_CONTRACT_OK', 'AUTHORIZATION_CONTRACT_OK')) for line in lines)
        rows.append(dict(case=name, passed=passed, exitCode=p.returncode, assertions=assertions,
                         logSHA256=hashlib.sha256(log.read_bytes()).hexdigest()))
        print(name, 'passed' if passed else 'FAILED', len(assertions), flush=True)
        if not passed: print('\n'.join(lines[-15:]), flush=True)
    receipt = dict(archiveSHA256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                   sources={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                   passed=all(row['passed'] for row in rows), runs=rows)
    (out / 'report.json').write_text(json.dumps(receipt, indent=2) + '\n')
    raise SystemExit(0 if receipt['passed'] else 1)


if __name__ == '__main__':
    main()
