#!/usr/bin/env python3
"""Build NetVplayer's embedded Dolby renderer and native HDMI audio runtime.

The supplied base bundle owns the dependency ABI and licenses. No newly found
Homebrew dylib is silently added to the output. Source checkouts must be at the
pins below; the overlay and patch live next to this script in runtime/mpv/.
The resulting runtime.app is consumed by the normal build_and_run.sh entrypoint.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import urllib.request
import build_truehd_objects
from verify_playback_runtime import capabilities, require_capabilities, verify_bundle, verify_dash_bundle

MPV_COMMIT = "99b4c12cccb4d8d3f72b41944cb6c640e2156650"
PLACEBO_COMMIT = "0df80ae5229e8e520c0fa4e3d666098a3ffa1cbc"
FFMPEG_SHA256 = "cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
FFMPEG_URL = "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz"
OVERLAY = Path(__file__).resolve().parent / "runtime/mpv"


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def run(command, *, cwd=None, env=None):
    subprocess.run([str(x) for x in command], cwd=cwd, env=env, check=True)


def output(command, cwd=None):
    return subprocess.check_output([str(x) for x in command], cwd=cwd, text=True).strip()


def replace_copy(source, destination):
    destination = Path(destination)
    if destination.is_file():
        destination.chmod(destination.stat().st_mode | 0o200)
    return shutil.copy2(source, destination)


def verify_pin(source, commit):
    if output(["git", "rev-parse", "HEAD"], cwd=source) != commit:
        raise RuntimeError("Source revision does not match the pinned runtime: " + str(source))


def apply_overlay(source):
    patch = OVERLAY / "integration.patch"
    check = subprocess.run(["git", "apply", "--reverse", "--check", str(patch)],
                           cwd=source, capture_output=True)
    if check.returncode:
        run(["git", "apply", "--check", patch], cwd=source)
        run(["git", "apply", patch], cwd=source)
    for relative in ("video/out/libmpv_placebo.c", "video/out/hdr_vivid.h", "audio/out/avfoundation_eac3.h",
                     "audio/out/coreaudio_hdmi.h", "audio/decode/ad_truehd_objects.c", "audio/decode/ad_truehd_objects.h",
                     "audio/decode/atmos_render.c", "audio/decode/atmos_render.h",
                     "audio/decode/atmos_binaural.m", "audio/decode/atmos_binaural.h",
                     "include/mpv/render_placebo.h", "include/mpv/render_netvplayer.h"):
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        # Preserve incremental builds without allowing an older source mtime
        # to leave a stale object behind after changing an overlay checkout.
        if not target.exists() or digest(target) != digest(OVERLAY / relative):
            shutil.copyfile(OVERLAY / relative, target)


def prepare_headers(work, base):
    manifest = json.loads((base / "Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json").read_text())
    component = next(x for x in manifest["components"] if x["formula"] == "ffmpeg")
    if component["source"].get("sha256") != FFMPEG_SHA256:
        raise RuntimeError("This recipe requires the audited FFmpeg 9.0.1 dependency bundle")
    archive = work / "ffmpeg-9.0.1.tar.xz"
    if not archive.exists():
        with urllib.request.urlopen(FFMPEG_URL, timeout=60) as response, archive.open("wb") as dest:
            shutil.copyfileobj(response, dest)
    if digest(archive) != FFMPEG_SHA256:
        raise RuntimeError("FFmpeg source checksum mismatch")
    source = work / "ffmpeg-9.0.1"
    if not source.exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                path = (work / member.name).resolve()
                if work not in path.parents:
                    raise RuntimeError("Unsafe source archive member")
                if member.issym() or member.islnk():
                    target = ((path.parent if member.issym() else work) / member.linkname).resolve()
                    if work not in target.parents:
                        raise RuntimeError("Unsafe source archive link")
            tar.extractall(work)
    prefix = work / "ffmpeg-headers"
    if not (prefix / "include/libavutil/ffversion.h").exists():
        run(["./configure", "--disable-all", "--disable-autodetect", "--disable-programs",
             "--enable-avcodec", "--enable-avformat", "--enable-avfilter", "--enable-swresample",
             "--enable-swscale", "--enable-avdevice", "--prefix=" + str(prefix)], cwd=source)
        run(["make", "install-headers"], cwd=source)
    lib = prefix / "lib"
    for name in ("avcodec", "avformat", "avutil", "avfilter", "avdevice", "swresample", "swscale", "bluray"):
        candidates = list((base / "Contents/Frameworks").glob("lib" + name + ".*.dylib"))
        if len(candidates) != 1:
            raise RuntimeError("Ambiguous base library: " + name)
        link = lib / ("lib" + name + ".dylib")
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            raise RuntimeError("Refusing to overwrite a non-symlink dependency: " + str(link))
        link.symlink_to(candidates[0])
    # Public libbluray headers do not require its private fontconfig dependencies.
    (lib / "pkgconfig/libbluray.pc").write_text(
        "prefix=/opt/homebrew/opt/libbluray\nincludedir=${prefix}/include\nlibdir=" + str(lib) +
        "\nName: libbluray\nDescription: audited dynamic libbluray ABI\nVersion: 1.5.0\n"
        "Libs: -L${libdir} -lbluray\nCflags: -I${includedir}\n")
    return prefix


def patch_library(path, frameworks):
    path.chmod(0o755)
    run(["install_name_tool", "-id", "@rpath/" + path.name, path])
    for line in output(["otool", "-L", path]).splitlines()[1:]:
        dependency = line.strip().split(" (")[0]
        if dependency.startswith(("/System/Library/", "/usr/lib/")) or dependency == "@rpath/" + path.name:
            continue
        name = Path(dependency).name
        if not (frameworks / name).is_file():
            raise RuntimeError("Dependency is outside the audited bundle: " + dependency)
        run(["install_name_tool", "-change", dependency, "@loader_path/" + name, path])
    lines = output(["otool", "-l", path]).splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            value = lines[index + 2].strip().split("path ", 1)[1].split(" (offset")[0]
            if value.startswith(("/opt/", "/private/", "/Users/", "/tmp/")):
                run(["install_name_tool", "-delete_rpath", value, path])
    run(["install_name_tool", "-add_rpath", "@loader_path", path])
    run(["codesign", "--force", "--sign", "-", path])


def assemble(base, destination, mpv, placebo, placebo_source, recipe, truehd_prefix, truehd_provenance):
    frameworks = destination / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    for path in (base / "Contents/Frameworks").glob("*.dylib"):
        replace_copy(path, frameworks / path.name)
    notices = destination / "Contents/Resources/ThirdPartyLicenses"
    shutil.copytree(base / "Contents/Resources/ThirdPartyLicenses", notices,
                    dirs_exist_ok=True, copy_function=replace_copy)
    dash_receipt = base / "Contents/Resources/dash-runtime-build.json"
    if dash_receipt.is_file():
        replace_copy(dash_receipt, destination / "Contents/Resources/dash-runtime-build.json")
        recipe["dashRuntimeBuildSHA256"] = digest(dash_receipt)
    truehd = truehd_prefix / "lib/libtruehd_atmos.dylib"
    for path in (mpv, placebo, truehd):
        shutil.copy2(path, frameworks / path.name)
    for path in (mpv, placebo, truehd):
        patch_library(frameworks / path.name, frameworks)

    # Inspect the assembled binary, rather than infer transport support from
    # source hashes or the base bundle. This pure ABI query opens no device.
    runtime = ctypes.CDLL(str(frameworks / mpv.name))
    query_capabilities = runtime.mpv_netvplayer_runtime_capabilities
    query_capabilities.restype = ctypes.c_uint64
    capabilities = query_capabilities()
    if capabilities >> 32 != 1 or capabilities & (256 | 512) != (256 | 512):
        raise RuntimeError("Assembled runtime lacks the DTS-HD HBR / TrueHD objects contract")
    recipe["runtimeABI"] = capabilities >> 32
    recipe["runtimeCapabilityBits"] = capabilities & 0xffffffff

    deployment = {}
    for path in frameworks.glob("*.dylib"):
        text = output(["otool", "-l", path])
        versions = re.findall(r"\bminos (\d+\.\d+(?:\.\d+)?)", text)
        if not versions or any(tuple(map(int, v.split("."))) > (14, 0, 0) for v in versions):
            raise RuntimeError("Dependency exceeds macOS 14 deployment target: " + path.name)
        deployment[path.name] = versions
        for line in output(["otool", "-L", path]).splitlines()[1:]:
            dep = line.strip().split(" (")[0]
            if not dep.startswith(("@rpath/", "@loader_path/", "/System/Library/", "/usr/lib/")):
                raise RuntimeError("External runtime dependency: " + dep)

    manifest_path = notices / "libmpv-runtime.json"
    manifest = json.loads(manifest_path.read_text())
    component = next(x for x in manifest["components"] if x["formula"] == "mpv")
    component.pop("homebrew_formula", None)
    component.update(version="0.41.0-846-g99b4c12cc-netvplayer", source={
        "url": "https://github.com/mpv-player/mpv/commit/" + MPV_COMMIT,
        "commit": MPV_COMMIT, "overlay_sha256": recipe["overlaySHA256"],
    }, dylibs=[{"name": mpv.name, "source_sha256": digest(mpv)}])
    component["license_files"] = []
    for name in ("Copyright", "LICENSE.GPL", "LICENSE.LGPL"):
        target = notices / "libmpv/mpv" / name
        replace_copy(OVERLAY / name, target)
        component["license_files"].append({"path": target.relative_to(destination).as_posix(),
                                           "sha256": digest(target), "origin": "pinned-source"})
    name = "libplacebo-netvplayer"
    license_root = notices / "libmpv" / name
    license_root.mkdir(parents=True, exist_ok=True)
    license_source = placebo_source / "LICENSE"
    target = license_root / "LICENSE"
    shutil.copy2(license_source, target)
    manifest["components"] = [x for x in manifest["components"] if x["formula"] != name]
    manifest["components"].append({
        "formula": name, "version": "7.376.0", "license": "LGPL-2.1-or-later",
        "homepage": "https://code.videolan.org/videolan/libplacebo",
        "source": {"url": "https://github.com/haasn/libplacebo/commit/" + PLACEBO_COMMIT,
                   "commit": PLACEBO_COMMIT},
        "dylibs": [{"name": placebo.name, "source_sha256": digest(placebo)}],
        "license_files": [{"path": target.relative_to(destination).as_posix(),
                           "sha256": digest(target), "origin": "pinned-source"}],
    })
    manifest["components"] = [x for x in manifest["components"] if x["formula"] != "truehd-atmos"]
    manifest["components"].append(build_truehd_objects.package_licenses(
        truehd_prefix, destination, truehd, truehd_provenance))
    manifest["dylib_count"] = len(deployment)
    manifest["formula_count"] = len(manifest["components"])
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    lines = ["# libmpv Runtime Third-Party Notices", "",
             "This runtime contains the following components; complete source pins and license hashes are in libmpv-runtime.json.", ""]
    lines += ["- " + c["formula"] + " " + c["version"] + ": " + c["license"] for c in manifest["components"]]
    (notices / "libmpv-runtime.md").write_text("\n".join(lines) + "\n")
    recipe["deployment"] = deployment
    recipe["binaries"] = {p.name: digest(p) for p in frameworks.glob("*.dylib")}
    (destination / "Contents/Resources/dolby-runtime-build.json").write_text(json.dumps(recipe, indent=2) + "\n")
    verify_bundle(destination)
    run(["python3", Path(__file__).with_name("package_libmpv_runtime_licenses.py"),
         "--app-bundle", destination, "--audit-only"])


def prepare_dash_runtime(base, work, openssl):
    """Reuse a qualified base, or rebuild only avformat from the cached pin."""
    info = capabilities(base / 'Contents/Frameworks/libavformat.63.dylib')
    if 'dash' in info['demuxers'] and info.get('bytevc2'):
        require_capabilities(info)
        verify_bundle(base)
        return base
    destination = work / 'dash-runtime.app'
    builder = Path(__file__).with_name('build_dash_runtime.py')
    if destination.exists():
        if (destination / 'Contents/Resources/dolby-runtime-build.json').exists():
            verify_bundle(destination)
        else:
            verify_dash_bundle(destination)
        receipt = json.loads((destination / 'Contents/Resources/dash-runtime-build.json').read_text())
        if (not receipt.get('bytevc2') or receipt['recipe_sha256'] != digest(builder) or
                receipt['original_libavformat_sha256'] != digest(base / 'Contents/Frameworks/libavformat.63.dylib')):
            raise RuntimeError('DASH runtime input changed; use a fresh work directory')
        # Reusing a cached rebuild must preserve every other base dependency.
        for binary in (base / 'Contents/Frameworks').glob('*.dylib'):
            if binary.name != 'libavformat.63.dylib' and digest(binary) != digest(destination / 'Contents/Frameworks' / binary.name):
                raise RuntimeError('DASH runtime base changed; use a fresh work directory')
    else:
        run([os.sys.executable, builder, '--source-archive', work / 'ffmpeg-9.0.1.tar.xz',
             '--baseline-app', base, '--openssl', openssl, '--work', work / 'dash-build',
             '--output', destination])
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-runtime", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--mpv-source", type=Path, required=True)
    parser.add_argument("--libplacebo-source", type=Path, required=True)
    parser.add_argument("--libplacebo-prefix", type=Path, help="Reuse a build of the pinned libplacebo source")
    parser.add_argument("--tools-bin", type=Path)
    parser.add_argument("--truehd-source", type=Path, help="Pinned clean LibTrueHD checkout (otherwise fetched in work-dir)")
    parser.add_argument("--openssl", type=Path, default=Path('/opt/homebrew/opt/openssl@3'),
                        help="Matching OpenSSL headers for the DASH libavformat build")
    args = parser.parse_args()
    base, work, source, placebo_source = [p.resolve() for p in
        (args.base_runtime, args.work_dir, args.mpv_source, args.libplacebo_source)]
    work.mkdir(parents=True, exist_ok=True)
    verify_pin(source, MPV_COMMIT)
    verify_pin(placebo_source, PLACEBO_COMMIT)
    apply_overlay(source)
    headers = prepare_headers(work, base)
    base = prepare_dash_runtime(base, work, args.openssl.resolve())
    env = os.environ.copy()
    if args.tools_bin:
        env["PATH"] = str(args.tools_bin.resolve()) + os.pathsep + env.get("PATH", "")
    env["PKG_CONFIG"] = shutil.which("pkgconf", path=env["PATH"]) or "pkg-config"
    sdk = output(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    sdk_pc = work / "sdk-pc"
    sdk_pc.mkdir(exist_ok=True)
    for name, version, library in (("zlib", "1.2.12", "z"), ("bzip2", "1.0.8", "bz2")):
        (sdk_pc / (name + ".pc")).write_text(
            f"prefix={sdk}/usr\nName: {name}\nDescription: Apple SDK {name}\nVersion: {version}\nLibs: -l{library}\n")
    brew_pc = sorted(Path("/opt/homebrew/opt").glob("*/lib/pkgconfig"))
    brew_pc += sorted(Path("/opt/homebrew/opt").glob("*/share/pkgconfig"))
    env.update(SDKROOT=sdk, MACOSX_DEPLOYMENT_TARGET="14.0",
               CLANG_MODULE_CACHE_PATH=str(work / "module-cache"), SWIFT_MODULECACHE_PATH=str(work / "module-cache"),
               PKG_CONFIG_PATH=os.pathsep.join(map(str, [headers / "lib/pkgconfig", sdk_pc] + brew_pc)))
    truehd_prefix, truehd_provenance = build_truehd_objects.build(
        args.truehd_source.resolve() if args.truehd_source else work / "LibTrueHD", work, env)
    env["PKG_CONFIG_PATH"] = str(truehd_prefix / "lib/pkgconfig") + os.pathsep + env["PKG_CONFIG_PATH"]
    prefix = args.libplacebo_prefix.resolve() if args.libplacebo_prefix else work / "placebo-prefix"
    if not args.libplacebo_prefix:
        build = work / "placebo-build"
        if not (build / "build.ninja").exists():
            run(["meson", "setup", build, placebo_source, "--prefix=" + str(prefix), "--buildtype=release",
                 "-Ddemos=false", "-Dtests=false", "-Dvulkan=enabled", "-Dshaderc=enabled", "-Dglslang=disabled",
                 "-Dopengl=enabled", "-Dlcms=enabled", "-Ddovi=enabled", "-Dlibdovi=disabled",
                 "-Dc_args=-mmacosx-version-min=14.0", "-Dcpp_args=-mmacosx-version-min=14.0"], env=env)
        run(["meson", "compile", "-C", build, "-j", "6"], env=env)
        run(["meson", "install", "-C", build], env=env)
    env["PKG_CONFIG_PATH"] = str(prefix / "lib/pkgconfig") + os.pathsep + env["PKG_CONFIG_PATH"]
    build = work / "build-product"
    if not (build / "build.ninja").exists():
        run(["meson", "setup", build, source, "--buildtype=release", "-Dlibmpv=true", "-Dcplayer=true",
             "-Dtests=false", "-Dvulkan=enabled", "-Dgl=enabled", "-Dgl-cocoa=enabled", "-Dswift-build=enabled",
             "-Djavascript=enabled", "-Dlua=enabled", "-Dlibbluray=enabled", "-Dlibcurl=disabled",
             "-Dc_args=-mmacosx-version-min=14.0", "-Dobjc_args=-mmacosx-version-min=14.0",
             "-Dswift-flags=-target " + platform.machine() + "-apple-macos14.0"], env=env)
    run(["meson", "compile", "-C", build, "-j", "6"], env=env)
    files = {p.relative_to(OVERLAY).as_posix(): digest(p) for p in sorted(OVERLAY.rglob("*")) if p.is_file()}
    recipe = {"schema": 1, "mpvCommit": MPV_COMMIT, "libplaceboCommit": PLACEBO_COMMIT,
              "truehdObjects": truehd_provenance,
              "truehdBuilderSHA256": digest(Path(__file__).with_name("build_truehd_objects.py")),
              "ffmpegSourceSHA256": FFMPEG_SHA256, "overlay": files,
              "overlaySHA256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(),
              "baseManifestSHA256": digest(base / "Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json")}
    assemble(base, work / "runtime.app", build / "libmpv.2.dylib",
             prefix / "lib/libplacebo.376.dylib", placebo_source, recipe, truehd_prefix, truehd_provenance)
    print("Runtime prepared:", work / "runtime.app")


if __name__ == "__main__":
    main()
