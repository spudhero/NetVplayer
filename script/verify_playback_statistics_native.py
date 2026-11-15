#!/usr/bin/env python3
"""Link current debug product objects into an isolated native app; require completion JSON."""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error('use a fresh directory; preserve previous native evidence')
    output.mkdir(parents=True)
    repo = Path(__file__).resolve().parent.parent
    package = repo / 'NetVplayer'
    run('swift', 'build', '--package-path', package, '--disable-sandbox', '--product', 'NetVplayerApp')
    build = (package / '.build/debug').resolve()
    description = json.loads((build / 'description.json').read_text())
    command = next(v for v in description['swiftCommands'].values() if v['moduleName'] == 'NetVplayerApp')
    compile_args = []
    source_args = command['otherArguments']
    i = 0
    while i < len(source_args):
        token = source_args[i]
        if token in ('-target', '-sdk', '-I', '-L', '-F', '-Xcc'):
            compile_args.extend(source_args[i:i+2]); i += 2
        else:
            i += 1
    for filename, size, rate in [('fixture.mp4', '640x360', '24'), ('other.mp4', '854x480', '30')]:
        run('/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
            f'testsrc2=size={size}:rate={rate}', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
            '-t', '40', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', rate,
            '-c:a', 'aac', '-movflags', '+faststart', output / filename)
    run('/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', output / 'fixture.mp4',
        '-c', 'copy', '-f', 'hls', '-hls_time', '2', '-hls_list_size', '0', '-hls_flags', 'omit_endlist', output / 'live.m3u8')
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(output)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='ov87-07-native-') as temp:
            bundle = output / 'StatisticsNativeProbe.app'
            contents = bundle / 'Contents'
            binary = contents / 'MacOS/StatisticsNativeProbe'
            binary.parent.mkdir(parents=True)
            shutil.copytree('/Applications/NetVplayer.app/Contents/Frameworks', contents / 'Frameworks', symlinks=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.netvplayer.statistics-native-probe',
                'CFBundleName': 'StatisticsNativeProbe', 'CFBundleExecutable': binary.name,
                'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0',
                'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
            }))
            source = repo / 'script/playback_statistics_native_probe.swift'
            link_args = ['-lAMSMB2', '-lcurl', '-lc++']
            for framework in ('Sparkle', 'Sentry', 'WebKit', 'OpenGL', 'Metal', 'QuartzCore', 'IOSurface',
                              'ColorSync', 'CoreFoundation', 'ImageIO', 'CoreAudio', 'AppKit', 'Security'):
                link_args += ['-framework', framework]
            run('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-enable-testing',
                '-I', build / 'Modules', '-L', build, '-F', build,
                '-module-cache-path', output / 'ModuleCache', *compile_args,
                source, '@' + str(build / 'NetVplayerApp.product/Objects.LinkFileList'), *link_args,
                '-Xlinker', '-dead_strip', '-Xlinker', '-dead_strip_dylibs',
                '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
                '-Xlinker', '-rpath', '-Xlinker', build, '-o', binary, cwd=package)
            # Only temporary copies are signed; the installed runtime is preserved.
            run('codesign', '--force', '--deep', '--sign', '-', bundle)
            run('codesign', '--verify', '--deep', '--strict', bundle)
            run('file', binary)
            result = output / 'native-validation.json'
            with (output / 'native-host.log').open('w') as log:
                # Launch the isolated NSApplication directly. LaunchServices can
                # spend minutes assessing copied temporary frameworks before main.
                host = subprocess.Popen([str(binary), str(output), f'http://127.0.0.1:{server.server_port}'],
                                        stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 240
                    while not result.exists() and host.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.1)
                finally:
                    if host.poll() is None:
                        host.terminate()
                    host.wait(timeout=15)
            if not result.exists():
                raise SystemExit('native host did not produce completion JSON within 240 seconds')
            record = json.loads(result.read_text())
            if record.get('status') != 'passed':
                raise SystemExit(json.dumps(record, ensure_ascii=False))
            sources = [source, repo / 'script/verify_playback_statistics_native.py']
            sources += [repo / p for p in (
                'NetVplayer/Sources/PlayerEngine/MPVPlayerEngine.swift',
                'NetVplayer/Sources/PlayerEngine/PlaybackStatistics.swift',
                'NetVplayer/Sources/PlayerEngine/PlaybackDiagnostics.swift',
                'NetVplayer/Sources/NetVplayerApp/Views/PlaybackInformationView.swift',
                'NetVplayer/Sources/NetVplayerApp/Views/PlaybackInformationVisibility.swift',
                'NetVplayer/Sources/NetVplayerApp/Views/PlaybackSummaryView.swift')]
            record['sourceSHA256'] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
            result.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
            print(json.dumps({'status': record['status'], 'checks': len(record['checks'])}))
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
