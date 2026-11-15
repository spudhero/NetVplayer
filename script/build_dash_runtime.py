#!/usr/bin/env python3
"""Build the shared DASH runtime from pinned FFmpeg source, retaining baseline codecs.

No source fallback/download, global package install, trust override or provider
rewrite. Requires Xcode, Python 3.12+, and the baseline's OpenSSL installation.
The small pkg-config probe below exposes only those two explicit dependencies;
versions come from installed headers/.pc metadata and configure compile checks.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from verify_playback_runtime import capabilities, require_capabilities, verify_bundle, verify_dash_bundle

SOURCE_SHA = 'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635'

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def output(*args):
    return subprocess.check_output(args, text=True).strip()

def probe(args):
    modules = json.loads(Path(os.environ['NETVPLAYER_DASH_DEPENDENCIES']).read_text())
    if args == ['--version']:
        print('1.0.0')  # Version of this deliberately scoped probe, not pkgconf.
        return
    if any(a.startswith('--atleast-pkgconfig-version') for a in args):
        return
    expression = ' '.join(a for a in args if not a.startswith('--')).strip()
    match = re.fullmatch(r'(libxml-2\.0|openssl)(?:\s*>=\s*([0-9.]+))?', expression)
    if not match:
        raise SystemExit(1)
    module = modules[match[1]]
    if match[2] and tuple(map(int, module['version'].split('.'))) < tuple(map(int, match[2].split('.'))):
        raise SystemExit(1)
    if '--modversion' in args:
        print(module['version'])
    if any(a.startswith('--cflags') for a in args):
        print(module['cflags'])
    if any(a.startswith('--libs') for a in args):
        print(module['libs'])

def finalize_provenance(baseline, destination):
    """Preserve an existing Dolby recipe, or verify the pre-Dolby intermediate."""
    source = baseline/'Contents/Resources/dolby-runtime-build.json'
    if not source.exists():
        verify_dash_bundle(destination)
        return
    binary = destination/'Contents/Frameworks/libavformat.63.dylib'
    resources = destination/'Contents/Resources'
    dolby = json.loads(source.read_text())
    dolby['binaries'][binary.name] = sha(binary)
    dolby['deployment'][binary.name] = ['14.0']
    dolby['dashRuntimeBuildSHA256'] = sha(resources/'dash-runtime-build.json')
    (resources/'dolby-runtime-build.json').write_text(json.dumps(dolby,indent=2)+'\n')
    verify_bundle(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-archive', required=True, type=Path)
    parser.add_argument('--baseline-app', required=True, type=Path)
    parser.add_argument('--openssl', required=True, type=Path)
    parser.add_argument('--work', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not args.source_archive.is_file():
        parser.error('Pinned source archive is missing; supply the audited local FFmpeg 9.0.1 tarball. This command never downloads it.')
    if sha(args.source_archive) != SOURCE_SHA:
        raise SystemExit('Pinned FFmpeg 9.0.1 archive SHA mismatch')
    if args.work.exists() or args.output.exists():
        raise SystemExit('Choose fresh work/output directories; existing evidence is never overwritten')
    baseline_manifest = json.loads((args.baseline_app/'Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json').read_text())
    baseline_ffmpeg = next(c for c in baseline_manifest['components'] if c['formula'] == 'ffmpeg')
    if baseline_ffmpeg['source'].get('sha256') != SOURCE_SHA:
        raise SystemExit('Baseline runtime does not use the pinned FFmpeg source')
    before = capabilities(args.baseline_app/'Contents/Frameworks/libavformat.63.dylib')
    if before['avformat_major'] != 63:
        raise SystemExit('Baseline runtime does not use libavformat 63')
    args.work.mkdir(parents=True)
    with tarfile.open(args.source_archive) as archive:
        archive.extractall(args.work, filter='data')
    src = args.work / 'ffmpeg-9.0.1'
    patch_path = Path(__file__).resolve().parent/'patches/ffmpeg-9.0.1-dash-eof-seek.patch'
    with patch_path.open('rb') as patch_file:
        subprocess.run(['patch', '-p1', '--batch', '--forward'], cwd=src,
                       stdin=patch_file, check=True)
    sdk = Path(output('xcrun', '--show-sdk-path'))
    xml_header = (sdk / 'usr/include/libxml2/libxml/xmlversion.h').read_text()
    xml_version = re.search(r'#define LIBXML_DOTTED_VERSION "([0-9.]+)"', xml_header)[1]
    openssl_version = re.search(r'^Version:\s*([0-9.]+)', (args.openssl/'lib/pkgconfig/libssl.pc').read_text(), re.M)[1]
    dependency = args.work / 'dependencies.json'
    dependency.write_text(json.dumps({
        'libxml-2.0': {'version':xml_version, 'cflags':f'-I{sdk}/usr/include -I{sdk}/usr/include/libxml2', 'libs':'-lxml2'},
        'openssl': {'version':openssl_version, 'cflags':f'-I{args.openssl}/include', 'libs':f'-L{args.openssl}/lib -lssl -lcrypto'}
    }))
    # All paths are passed as argv or shell-quoted inside this tiny launcher.
    import shlex
    wrapper = args.work/'dependency-probe'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(Path(__file__).resolve()), '--probe-pkg-config']) + ' "$@"\n')
    wrapper.chmod(0o755)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='14.0', NETVPLAYER_DASH_DEPENDENCIES=str(dependency))
    configure = ['./configure', '--pkg-config='+str(wrapper), '--prefix='+str(args.work/'prefix'),
        '--disable-autodetect','--enable-shared','--disable-static','--enable-gpl','--enable-version3',
        '--enable-openssl','--enable-libxml2','--enable-pthreads','--disable-programs','--disable-doc',
        '--cc=clang','--extra-cflags=-mmacosx-version-min=14.0','--extra-ldflags=-mmacosx-version-min=14.0',
        '--enable-videotoolbox','--enable-audiotoolbox']
    for name, command in [('configure', configure), ('make', ['make','-j6','libavformat/libavformat.63.dylib'])]:
        with (args.work/(name+'.log')).open('w') as log:
            subprocess.run(command, cwd=src, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    framework = args.output/'Contents/Frameworks'
    framework.mkdir(parents=True)
    # A baseline may be a complete App, with Sparkle, SMB and transfer
    # frameworks owned by other packagers. Only the top-level playback dylibs
    # belong to this runtime; copying framework trees breaks versioned links
    # when the normal Release assembles its own Sparkle.framework.
    for binary in sorted((args.baseline_app/'Contents/Frameworks').glob('*.dylib')):
        shutil.copy2(binary, framework/binary.name)
    resources = args.output/'Contents/Resources'
    resources.mkdir()
    shutil.copytree(args.baseline_app/'Contents/Resources/ThirdPartyLicenses', resources/'ThirdPartyLicenses')
    target = framework/'libavformat.63.dylib'
    old_sha = sha(target)
    target.chmod(0o755)
    shutil.copyfile(src/'libavformat/libavformat.63.dylib', target)
    raw_sha = sha(target)
    subprocess.run(['install_name_tool','-id','@rpath/'+target.name,str(target)],check=True)
    for line in output('otool','-L',str(target)).splitlines()[1:]:
        dep = line.strip().split(' (')[0]
        if dep.startswith(('/usr/lib/','/System/Library/','@rpath/')):
            continue
        name = Path(dep).name
        if not (framework/name).is_file():
            raise SystemExit('Unbundled dependency: '+name)
        subprocess.run(['install_name_tool','-change',dep,'@loader_path/'+name,str(target)],check=True)
    subprocess.run(['install_name_tool','-add_rpath','@loader_path',str(target)],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(target)],check=True)
    assert re.findall(r'\bminos ([0-9.]+)',output('otool','-l',str(target))) == ['14.0']
    after = capabilities(target)
    require_capabilities(after, baseline=before)
    patch_relative = Path('Contents/Resources/ThirdPartyLicenses/libmpv/ffmpeg')/patch_path.name
    shutil.copyfile(patch_path, args.output/patch_relative)
    receipt = {'schema':1,'source_sha256':SOURCE_SHA,
        'patches':[{'name':patch_path.name,'path':patch_relative.as_posix(),'sha256':sha(patch_path)}],'build_libavformat_sha256':raw_sha,
        'original_libavformat_sha256':old_sha,'packaged_libavformat_sha256':sha(target),
        'minimum_macos':'14.0','added_dependency':'/usr/lib/libxml2.2.dylib',
        'dependencies':{'libxml2':xml_version,'openssl':openssl_version},
        'capabilities':{key:{'added':sorted(set(after[key])-set(before[key])), 'removed':[]} for key in ('demuxers','protocols')},
        'recipe_sha256':sha(__file__),'configure_flags':configure[3:]}
    # Do not serialize build-host temporary paths in the distributable receipt.
    receipt['configure_flags'] = [flag for flag in receipt['configure_flags'] if not flag.startswith('--prefix=')]
    (resources/'dash-runtime-build.json').write_text(json.dumps(receipt,indent=2)+'\n')
    license_path = resources/'ThirdPartyLicenses/libmpv-runtime.json'
    license_data = json.loads(license_path.read_text())
    component = next(c for c in license_data['components'] if c['formula']=='ffmpeg')
    component['local_dash_build'] = receipt
    for binary in component['dylibs']:
        if binary['name']==target.name:
            binary.update(source_sha256=raw_sha,packaged_sha256=sha(target),origin='pinned-source-local-dash-build')
    license_path.write_text(json.dumps(license_data,indent=2)+'\n')
    with (resources/'ThirdPartyLicenses/libmpv-runtime.md').open('a') as f:
        f.write('\nFFmpeg 9.0.1 libavformat rebuilt from the pinned source archive with system libxml2 for DASH; baseline codec libraries retained. Local DASH patch preserves track selection across EOF and resets exhausted representations on seek. See dash-runtime-build.json for hashes, flags and capabilities.\n')
    # A stock licensed base precedes the Dolby build. Do not invent its future
    # receipt; the final Dolby assembler writes and verifies that provenance.
    finalize_provenance(args.baseline_app, args.output)
    print(json.dumps(receipt,indent=2))

if __name__ == '__main__':
    if sys.argv[1:2] == ['--probe-pkg-config']:
        probe(sys.argv[2:])
    else:
        main()
