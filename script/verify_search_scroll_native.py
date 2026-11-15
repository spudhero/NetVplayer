#!/usr/bin/env python3
"""Exercise production search input admission in an isolated native AppKit event loop."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device-input", action="store_true", help="wait for a real input driver at the final monitor check")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    result = output / "native-validation.json"
    if result.exists():
        parser.error("use a fresh output directory so stale evidence cannot pass")
    repo = Path(__file__).resolve().parents[1]
    sources = [repo / "NetVplayer/Sources/NetVplayerApp/Views/SearchScrollDemandProbe.swift",
               repo / "script/fixtures/search_scroll_demand.swift"]
    with tempfile.TemporaryDirectory(prefix="netvplayer-search-scroll-") as directory:
        bundle = Path(directory) / "SearchScrollProbe.app"
        contents = bundle / "Contents"
        binary = contents / "MacOS/SearchScrollProbe"
        binary.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": binary.name, "CFBundleIdentifier": "test.netvplayer.search-scroll",
            "CFBundleName": "SearchScrollProbe", "CFBundlePackageType": "APPL",
            "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "14.0"}))
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                        *map(str, sources), "-o", str(binary)], check=True)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(bundle)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
        try:
            subprocess.run(["/usr/bin/open", "-n", "-W", str(bundle), "--args", str(output),
                            *(["--device-input"] if args.device_input else [])], check=True, timeout=75)
        finally:
            # open -W timing out does not terminate the launched app. Match this unique binary only.
            subprocess.run(["pkill", "-TERM", "-f", "^" + re.escape(str(binary.resolve())) + "( |$)"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        record = json.loads(result.read_text())
        if record.get("status") != "passed":
            raise SystemExit(json.dumps(record))
        record["sourceSHA256"] = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sources}
        result.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"status": record["status"], "demands": record["demands"]}))


if __name__ == "__main__":
    main()
