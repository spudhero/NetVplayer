#!/usr/bin/env python3
"""Build an isolated AppKit host from the current production danmaku sources."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--probe", type=Path, default=Path("script/danmaku_native_probe.swift"))
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result = output / "native-validation.json"
    if result.exists():
        parser.error("use a fresh output directory; existing native evidence is preserved")
    repo = Path(__file__).resolve().parent.parent
    sources = repo / "NetVplayer/Sources"
    engine = sources / "DanmakuEngine"
    views = sources / "NetVplayerApp/Views"
    with tempfile.TemporaryDirectory(prefix="ov87-06-native-") as temp:
        work = Path(temp)
        bundle = work / "DanmakuNativeProbe.app"
        contents = bundle / "Contents"
        frameworks = contents / "Frameworks"
        binary = contents / "MacOS/DanmakuNativeProbe"
        frameworks.mkdir(parents=True)
        binary.parent.mkdir()
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.netvplayer.danmaku-native-probe",
            "CFBundleName": "DanmakuNativeProbe", "CFBundleExecutable": binary.name,
            "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0",
            "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
        }))
        # Extract the entire existing policy verbatim, with balanced braces.
        # No replacement policy, production flags, or AppState initialization.
        source = (views / "PlayerView.swift").read_text()
        start = source.index("enum DanmakuOverlayPolicy {")
        end = source.index("{", start) + 1
        depth = 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        policy = work / "DanmakuOverlayPolicy.swift"
        policy.write_text("import Foundation\nimport DanmakuEngine\n" + source[start:end] + "\n")
        engine_files = [engine / name for name in (
            "DanmakuModels.swift", "DanmakuCueParser.swift", "DanmakuLaneLayout.swift", "DanmakuPlaybackClock.swift")]
        run("xcrun", "swiftc", "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", "DanmakuEngine",
            "-emit-module-path", work / "DanmakuEngine.swiftmodule", "-o", frameworks / "libDanmakuEngine.dylib",
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/libDanmakuEngine.dylib", *engine_files)
        probe = repo / args.probe
        run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-I", work, "-L", frameworks,
            "-lDanmakuEngine", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            views / "DanmakuCanvas.swift", views / "DanmakuGlyphPreparation.swift", policy, probe, "-o", binary)
        run("codesign", "--force", "--deep", "--sign", "-", bundle)
        run("codesign", "--verify", "--deep", "--strict", bundle)
        subprocess.run(["/usr/bin/open", "-n", "-W", str(bundle), "--args", str(output)], check=True, timeout=45)
        record = json.loads(result.read_text())  # Exit 0 alone cannot prove execution.
        if record.get("status") != "passed":
            raise SystemExit(json.dumps(record))
        record["sourceSHA256"] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in [*engine_files, views / "DanmakuCanvas.swift", views / "DanmakuGlyphPreparation.swift", views / "PlayerView.swift", probe]}
        record["policyExtractionSHA256"] = hashlib.sha256(policy.read_bytes()).hexdigest()
        result.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"status": record["status"], "backingScale": record["backingScale"],
                          "scrollDelta": record["scrollDelta"]}))


if __name__ == "__main__":
    main()
