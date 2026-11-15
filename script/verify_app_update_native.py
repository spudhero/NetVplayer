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
    parser.add_argument('--skip-build', action='store_true', help='reuse a just-completed serial debug/test build')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error('use a fresh directory; preserve previous native evidence')
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
        token = source_args[i]
        if token in ('-target', '-sdk', '-I', '-L', '-F', '-Xcc'):
            compile_args.extend(source_args[i:i+2]); i += 2
        else:
            i += 1
    run('/opt/homebrew/bin/ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
        'testsrc2=size=640x360:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
        '-t', '60', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', '24',
        '-c:a', 'aac', '-movflags', '+faststart', output / 'fixture.mp4')
    requests = []
    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            super().do_GET()
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(output)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='ov87-08-native-') as temp:
            bundle = output / 'UpdateNativeProbe.app'
            contents = bundle / 'Contents'
            binary = contents / 'MacOS/UpdateNativeProbe'
            binary.parent.mkdir(parents=True)
            shutil.copytree('/Applications/NetVplayer.app/Contents/Frameworks', contents / 'Frameworks', symlinks=True)
            # Only ephemeral test signing keys, generated in memory. No release key or keychain access.
            feed = output / 'appcast.xml'
            feed.write_text('<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                            '<channel><title>Isolated update fixture</title><item><title>Fixture 2.0</title>'
                            '<sparkle:version>2</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString>'
                            f'<enclosure url="http://127.0.0.1:{server.server_port}/unused.zip" length="1" type="application/octet-stream"/>'
                            '</item></channel></rss>\n')
            signer = output / 'sign-fixture.swift'
            signer.write_text(r'''import Foundation
import CryptoKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: url)
let key = Curve25519.Signing.PrivateKey()
let signature = try key.signature(for: data).base64EncodedString()
let block = "<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(data.count)\n-->\n"
try (data + Data(block.utf8)).write(to: url)
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
            public_key = subprocess.check_output(['xcrun', 'swift', str(signer), str(feed)], text=True).strip()
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.netvplayer.update-native-probe',
                'CFBundleName': 'UpdateNativeProbe', 'CFBundleExecutable': binary.name,
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
                'LSMinimumSystemVersion': '14.0', 'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
                'SUFeedURL': f'http://127.0.0.1:{server.server_port}/appcast.xml', 'SUPublicEDKey': public_key,
                'SUEnableAutomaticChecks': False, 'SUAllowsAutomaticUpdates': True, 'SUAutomaticallyUpdate': True,
                'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True,
                'SUSignedFeedFailureExpirationInterval': 0,
                'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True}, 'CFBundleDevelopmentRegion': 'en',
            }))
            source = repo / 'script/app_update_native_probe.swift'
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
                        try:
                            host.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            host.terminate()
                    host.wait(timeout=15)
            if not result.exists():
                raise SystemExit('native host did not produce completion JSON within 240 seconds')
            record = json.loads(result.read_text())
            record['loopbackRequests'] = requests
            if not any(p.startswith('/appcast.xml') for p in requests) or any('unused.zip' in p for p in requests):
                raise SystemExit('expected signed metadata requests only, with no archive download')
            if record.get('status') != 'passed':
                raise SystemExit(json.dumps(record, ensure_ascii=False))
            sources = [source, repo / 'script/verify_app_update_native.py']
            sources += [repo / p for p in (
                'NetVplayer/Sources/NetVplayerApp/AppUpdateCoordinator.swift',
                'NetVplayer/Sources/NetVplayerApp/AppRestartGate.swift',
                'NetVplayer/Sources/NetVplayerApp/AppRelaunchCoordinator.swift',
                'NetVplayer/Sources/NetVplayerApp/AppUpdatePresentationPolicy.swift',
                'NetVplayer/Sources/NetVplayerApp/NetVplayerApp.swift',
                'NetVplayer/Sources/NetVplayerApp/StartupCoordinator.swift')]
            record['sourceSHA256'] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
            result.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
            print(json.dumps({'status': record['status'], 'checks': len(record['checks'])}))
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
