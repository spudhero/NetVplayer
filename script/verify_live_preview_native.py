#!/usr/bin/env python3
"""Verify live cached frames, clipped demand and cancellation in an isolated AppKit host."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import select
import threading
import time


class StalledMediaFixture:
    def __init__(self):
        self.lock = threading.Lock()
        self.active = 0
        self.peak = 0
        self.started = 0
        self.finished = 0
        self.headers_valid = True
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                if self.path == '/status':
                    data = json.dumps(fixture.snapshot()).encode()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if self.path != '/stall.ts':
                    self.send_error(404)
                    return
                valid = self.headers.get('X-Preview-Token') == 'fixture-only'
                with fixture.lock:
                    fixture.active += 1
                    fixture.started += 1
                    fixture.peak = max(fixture.peak, fixture.active)
                    fixture.headers_valid &= valid
                try:
                    self.send_response(200 if valid else 403)
                    self.send_header('Content-Type', 'video/mp2t')
                    self.send_header('Content-Length', '1048576')
                    self.end_headers()
                    # No media bytes. Observe the real decoder closing its socket.
                    deadline = time.monotonic() + 15
                    while time.monotonic() < deadline:
                        if select.select([self.connection], [], [], 0.05)[0]:
                            if not self.connection.recv(1):
                                break
                except (ConnectionError, OSError):
                    pass
                finally:
                    with fixture.lock:
                        fixture.active -= 1
                        fixture.finished += 1

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def snapshot(self):
        with self.lock:
            return dict(active=self.active, peak=self.peak, started=self.started,
                        finished=self.finished, headersValid=self.headers_valid)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error('use a fresh directory; previous evidence must be preserved')
    output.mkdir(parents=True)
    repo = Path(__file__).resolve().parents[1]
    package = repo / 'NetVplayer'
    subprocess.run(['swift', 'build', '--package-path', str(package), '--disable-sandbox', '--product', 'NetVplayerApp'], check=True)
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
    source = repo / 'script/fixtures/live_preview_native.swift'
    with tempfile.TemporaryDirectory(prefix='ov91-10-native-') as directory:
        bundle = Path(directory) / 'LivePreviewProbe.app'
        contents = bundle / 'Contents'
        binary = contents / 'MacOS/LivePreviewProbe'
        binary.parent.mkdir(parents=True)
        frameworks = contents / 'Frameworks'
        frameworks.mkdir()
        for name in ('Sparkle.framework', 'Sentry.framework'):
            shutil.copytree(build / name, frameworks / name, symlinks=True)
        shutil.copy2(build / 'libAMSMB2.dylib', frameworks)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'test.netvplayer.live-preview', 'CFBundleName': binary.name,
            'CFBundleExecutable': binary.name, 'CFBundlePackageType': 'APPL',
            'LSMinimumSystemVersion': '14.0', 'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True}))
        links = ['-lAMSMB2', '-lcurl', '-lc++', '-L', str(package / '.build/file-transfer-runtime/lib'), '-lssh2']
        for framework in ('Sparkle', 'Sentry', 'WebKit', 'OpenGL', 'Metal', 'QuartzCore', 'IOSurface',
                          'ColorSync', 'CoreFoundation', 'ImageIO', 'CoreAudio', 'AppKit', 'Security'):
            links += ['-framework', framework]
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-enable-testing', '-D', 'DEBUG',
                        '-I', str(build / 'Modules'), '-L', str(build), '-F', str(build),
                        '-module-cache-path', str(output / 'ModuleCache'), *compile_args,
                        str(source), '@' + str(build / 'NetVplayerApp.product/Objects.LinkFileList'), *links,
                        '-Xlinker', '-dead_strip', '-Xlinker', '-dead_strip_dylibs',
                        '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
                        '-Xlinker', '-rpath', '-Xlinker', str(build), '-o', str(binary)], cwd=package, check=True)
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(bundle)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
        # This manually linked diagnostic host owns an explicit NSApplication event loop.
        # LaunchServices assessment timed out before main in the recorded attempts.
        # Run only the isolated fixture binary; never launch the product application here.
        network = StalledMediaFixture()
        try:
            with (output / 'host.log').open('w') as log:
                subprocess.run([str(binary), str(output)], stdin=subprocess.DEVNULL,
                    stdout=log, stderr=log, check=True, timeout=110,
                    env={**os.environ, "CFFIXED_USER_HOME": str(output / "home"),
                         "XCTestConfigurationFilePath": "live-preview-isolated-host",
                         "NETVPLAYER_PREVIEW_STALL_ORIGIN": f"http://127.0.0.1:{network.server.server_port}",
                         "NETVPLAYER_LIBMPV_PATH": str(package / ".build/dolby-runtime/runtime.app/Contents/Frameworks/libmpv.2.dylib")})
            snapshot = network.snapshot()
            if snapshot != dict(active=0, peak=1, started=4, finished=4, headersValid=True):
                raise SystemExit(f'HTTP fixture did not retire: {snapshot}')
        finally:
            (output / 'network-validation.json').write_text(json.dumps(network.snapshot(), indent=2) + '\n')
            network.close()
        result = output / 'native-validation.json'
        record = json.loads(result.read_text())
        if record.get('status') != 'passed':
            raise SystemExit(json.dumps(record, ensure_ascii=False))
        paths = [source, Path(__file__).resolve()]
        paths += [repo / 'NetVplayer/Sources' / name for name in (
            'NetVplayerApp/LiveChannelPreviewStore.swift', 'NetVplayerApp/AppState.swift',
            'NetVplayerApp/AppState+LivePreview.swift', 'NetVplayerApp/Views/LiveChannelPreviewView.swift',
            'NetVplayerApp/Views/LiveStreamView.swift', 'PlayerEngine/PlayerChapterThumbnailDecoder.swift',
            'SpiderEngine/XtreamSiteProvider.swift', 'NetVplayerApp/AppState+LiveCatchup.swift',
            'Models/XtreamConfiguration.swift', 'Models/LivePreviewError.swift')]
        record['sourceSHA256'] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
        result.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(record, ensure_ascii=False))


if __name__ == '__main__':
    main()
