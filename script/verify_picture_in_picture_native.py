#!/usr/bin/env python3
"""Serial debug build + isolated AppKit/libmpv/system-PiP verification. Requires completion JSON."""
import argparse
import functools
import hashlib
import http.server
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import threading
import time
import sys


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--interactive-controls', action='store_true',
                        help='Wait for actual floating-window, pin and restore clicks in an isolated PlayerView')
    parser.add_argument('--controls-only', action='store_true', help='Run the interactive window checks without the system PiP matrix')
    parser.add_argument('--model-controls', action='store_true', help='Exercise product window APIs instead of waiting for human input; not a button-click test')
    args = parser.parse_args()
    if args.controls_only:
        args.interactive_controls = True
    if args.model_controls:
        args.interactive_controls = True
    output = args.output.resolve()
    if output.exists():
        parser.error('use a fresh output directory to preserve previous evidence')
    output.mkdir(parents=True)
    repo = Path(__file__).resolve().parent.parent
    package = repo / 'NetVplayer'
    if not args.skip_build:
        run('swift', 'build', '--package-path', package, '--disable-sandbox', '--product', 'NetVplayerApp')
    build = (package / '.build/debug').resolve()
    description = json.loads((build / 'description.json').read_text())
    command = next(v for v in description['swiftCommands'].values() if v['moduleName'] == 'NetVplayerApp')
    compile_args = []
    source_args = command['otherArguments']
    i = 0
    while i < len(source_args):
        if source_args[i] in ('-target', '-sdk', '-I', '-L', '-F', '-Xcc'):
            compile_args.extend(source_args[i:i+2]); i += 2
        else:
            i += 1
    run('/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
        'testsrc2=size=640x360:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
        '-t', '180', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', '24',
        '-c:a', 'aac', '-movflags', '+faststart', output / 'fixture.mp4')
    (output / 'fixture.srt').write_text('1\n00:00:00,000 --> 00:02:59,000\nOV87-09 original subtitle / 单实例字幕\n')
    if args.interactive_controls:
        run('/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
            'testsrc2=size=960x402:rate=24', '-t', '180', '-c:v', 'libx264', '-preset', 'ultrafast',
            '-pix_fmt', 'yuv420p', '-g', '24', '-movflags', '+faststart', output / 'floating-wide.mp4')
        run('/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
            "testsrc2=size=960x540:rate=24,drawbox=x=0:y=0:w=iw:h=70:color=black:t=fill:enable='lt(t,10)',"
            "drawbox=x=0:y=ih-70:w=iw:h=70:color=black:t=fill:enable='lt(t,10)'", '-t', '30', '-c:v', 'libx264',
            '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', '24', output / 'floating-letterbox.mp4')
    run(sys.executable, repo / 'script/generate_playback_hdr_fixtures.py', '--output-dir', output / 'hdr')
    requests = []
    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/request-count':
                payload = str(len(requests)).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(payload)))
                self.end_headers(); self.wfile.write(payload); return
            requests.append({'path': self.path, 'time': time.monotonic()})
            super().do_GET()
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(output)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        bundle = output / 'PictureInPictureProbe.app'
        contents = bundle / 'Contents'
        binary = contents / 'MacOS/PictureInPictureProbe'
        binary.parent.mkdir(parents=True)
        shutil.copytree('/Applications/NetVplayer.app/Contents/Frameworks', contents / 'Frameworks', symlinks=True)
        shutil.copy2(build / 'libAMSMB2.dylib', contents / 'Frameworks/libAMSMB2.dylib')
        resources = contents / 'Resources'
        resources.mkdir()
        for resource in build.glob('*.bundle'):
            shutil.copytree(resource, resources / resource.name, symlinks=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.netvplayer.pip-native-probe.' + hashlib.sha256(str(output).encode()).hexdigest()[:10],
            'CFBundleName': 'PictureInPictureProbe',
            'CFBundleExecutable': binary.name, 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1.0', 'LSMinimumSystemVersion': '14.0',
            'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
        }))
        source = repo / 'script/picture_in_picture_native_probe.swift'
        link_args = ['-lAMSMB2', '-lcurl', '-lc++']
        for framework in ('Sparkle', 'Sentry', 'WebKit', 'OpenGL', 'Metal', 'QuartzCore', 'IOSurface',
                          'ColorSync', 'CoreFoundation', 'ImageIO', 'CoreAudio', 'AppKit', 'Security'):
            link_args += ['-framework', framework]
        run('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-enable-testing', '-D', 'DEBUG',
            '-I', build / 'Modules', '-L', build, '-F', build, '-module-cache-path', output / 'ModuleCache',
            *compile_args, source, '@' + str(build / 'NetVplayerApp.product/Objects.LinkFileList'), *link_args,
            '-Xlinker', '-dead_strip', '-Xlinker', '-dead_strip_dylibs',
            '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
            '-o', binary, cwd=package)
        run('codesign', '--force', '--deep', '--sign', '-', bundle)
        run('codesign', '--verify', '--deep', '--strict', bundle)
        result = output / 'native-validation.json'
        # A deliberately isolated native diagnostic host; not the product launch path.
        with (output / 'native-host.log').open('w') as log:
            environment = dict(os.environ)
            if args.interactive_controls:
                environment['NETVPLAYER_PIP_CONTROL_INTERACTION'] = '1'
            if args.controls_only:
                environment['NETVPLAYER_PIP_CONTROLS_ONLY'] = '1'
            if args.model_controls:
                environment['NETVPLAYER_PIP_MODEL_CONTROLS'] = '1'
            launch = [str(binary), str(output), f'http://127.0.0.1:{server.server_port}']
            host = subprocess.Popen(launch,
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=environment)
            try:
                deadline = time.monotonic() + (480 if args.interactive_controls else 240)
                while not result.exists() and host.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.1)
            finally:
                if host.poll() is None:
                    try: host.wait(timeout=5)
                    except subprocess.TimeoutExpired: host.terminate()
                host.wait(timeout=15)
        if not result.exists():
            raise SystemExit('native host did not produce completion JSON')
        record = json.loads(result.read_text())
        record['loopbackRequests'] = requests
        sources = [source, Path(__file__).resolve(), package / 'Package.swift']
        sources += [package / p for p in ('Sources/NativePIP/NativePIP.m', 'Sources/NativePIP/include/NativePIP.h',
            'Sources/NetVplayerApp/PlayerPictureInPicture.swift', 'Sources/PlayerEngine/MPVPlayerEngine.swift',
            'Sources/PlayerEngine/MPVOpenGLVideoView.swift', 'Sources/NetVplayerApp/Views/PlayerView.swift',
            'Sources/NetVplayerApp/Views/LiveStreamView.swift', 'Sources/NetVplayerApp/Views/MainContainerView.swift',
            'Sources/NetVplayerApp/Views/CompactPlayerControls.swift',
            'Sources/NetVplayerApp/Views/PlayerShortcutMonitor.swift')]
        sources.append(package / 'Sources/NetVplayerApp/Views/PlayerHUDControlLabel.swift')
        sources.append(package / 'Sources/PlayerEngine/PlayerVideoGeometry.swift')
        sources.append(package / 'Sources/PlayerEngine/PlayerFloatingCrop.swift')
        sources.append(package / 'Sources/MPVShim/NVMPVBlackBars.c')
        record['sourceSHA256'] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        result.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({'status': record['status'], 'checks': len(record['checks']), 'error': record.get('error')}))
        if record['status'] != 'passed':
            raise SystemExit(1)
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
