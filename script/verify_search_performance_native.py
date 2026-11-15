#!/usr/bin/env python3
"""Measure the actual SearchView with isolated storage, intercepted HTTP and synthetic Providers."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


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
    source = repo / 'script/fixtures/search_performance_native.swift'
    with tempfile.TemporaryDirectory(prefix='ov91-06-native-') as directory:
        bundle = Path(directory) / 'SearchPerformanceProbe.app'
        contents = bundle / 'Contents'
        binary = contents / 'MacOS/SearchPerformanceProbe'
        binary.parent.mkdir(parents=True)
        frameworks = contents / 'Frameworks'
        frameworks.mkdir()
        for name in ('Sparkle.framework', 'Sentry.framework'):
            shutil.copytree(build / name, frameworks / name, symlinks=True)
        shutil.copy2(build / 'libAMSMB2.dylib', frameworks)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'test.netvplayer.search-performance', 'CFBundleName': binary.name,
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
        with (output / 'host.log').open('w') as log:
            subprocess.run([str(binary), str(output)], stdin=subprocess.DEVNULL,
                           stdout=log, stderr=log, check=True, timeout=45)
        result = output / 'native-validation.json'
        record = json.loads(result.read_text())
        if record.get('status') != 'passed':
            raise SystemExit(json.dumps(record, ensure_ascii=False))
        paths = [source, Path(__file__).resolve()]
        paths += [repo / p for p in (
            'NetVplayer/Sources/NetVplayerApp/AppState.swift', 'NetVplayer/Sources/NetVplayerApp/Views/SearchView.swift',
            'NetVplayer/Sources/SearchEngine/SearchEngine.swift', 'NetVplayer/Sources/SearchEngine/SearchPerformanceMeasurement.swift',
            'NetVplayer/Sources/Storage/SearchPerformanceStore.swift', 'NetVplayer/Sources/Models/SearchPerformance.swift')]
        record['sourceSHA256'] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
        result.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(record, ensure_ascii=False))


if __name__ == '__main__':
    main()
