from __future__ import annotations

import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_release_sbom import generate_sbom


class ReleaseSBOMTests(unittest.TestCase):
    def test_generates_built_artifact_spdx_and_cyclonedx_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "NetVplayer.app"
            contents = app / "Contents"
            executable = contents / "MacOS/NetVplayerApp"
            dylib = contents / "Frameworks/libmpv.dylib"
            node = contents / "Resources/NodeRuntime/bin/node"
            node_manifest = contents / "Resources/NodeRuntime/runtime-manifest.json"
            quickjs_manifest = contents / "Resources/QuickJSRuntime/runtime-manifest.json"
            torrent = contents / "Resources/TorrentBridge/package-lock.json"
            licenses = contents / "Resources/ThirdPartyLicenses/libmpv-runtime.json"
            for path in (executable, dylib, node, node_manifest, quickjs_manifest, torrent, licenses):
                path.parent.mkdir(parents=True, exist_ok=True)
            executable.write_bytes(b"\xcf\xfa\xed\xfe" + b"app")
            dylib.write_bytes(b"\xcf\xfa\xed\xfe" + b"mpv")
            node.write_bytes(b"\xcf\xfa\xed\xfe" + b"node")
            with (contents / "Info.plist").open("wb") as handle:
                plistlib.dump({
                    "CFBundleName": "NetVplayer",
                    "CFBundleIdentifier": "com.netvplayer.app",
                    "CFBundleShortVersionString": "1.2.3",
                }, handle)
            torrent.write_text(json.dumps({
                "packages": {
                    "": {"name": "bridge", "version": "1.0.0"},
                    "node_modules/webtorrent": {
                        "name": "webtorrent",
                        "version": "2.0.0",
                        "license": "MIT",
                        "resolved": "https://registry.npmjs.org/webtorrent/-/webtorrent-2.0.0.tgz",
                    },
                }
            }), encoding="utf-8")
            licenses.write_text(json.dumps({
                "components": [{
                    "formula": "mpv",
                    "version": "0.40.0",
                    "license": "GPL-2.0-or-later",
                    "source": {"url": "https://mpv.io"},
                }]
            }), encoding="utf-8")
            node_manifest.write_text(json.dumps({
                "schema_version": 1,
                "name": "Node.js",
                "version": "22.20.0",
                "architecture": "arm64",
                "source": "https://nodejs.org/dist/v22.20.0/node-v22.20.0-darwin-arm64.tar.gz",
                "artifact_sha256": "a" * 64,
                "license": "MIT",
            }), encoding="utf-8")
            quickjs_manifest.write_text(json.dumps({
                "schema_version": 1,
                "name": "QuickJS",
                "version": "2026-06-04",
                "architecture": "arm64",
                "source": "https://bellard.org/quickjs/binary_releases/quickjs-cosmo-2026-06-04.zip",
                "artifact_sha256": "b" * 64,
                "license": "MIT",
            }), encoding="utf-8")
            resolved = root / "Package.resolved"
            resolved.write_text(json.dumps({
                "pins": [{
                    "identity": "swift-nio",
                    "location": "https://github.com/apple/swift-nio.git",
                    "state": {"version": "2.101.0", "revision": "a" * 40},
                }]
            }), encoding="utf-8")

            outputs = generate_sbom(app, resolved, root / "sbom")
            evidence = json.loads(outputs["evidence"].read_text(encoding="utf-8"))
            spdx = json.loads(outputs["spdx"].read_text(encoding="utf-8"))
            cyclonedx = json.loads(outputs["cyclonedx"].read_text(encoding="utf-8"))

            self.assertEqual(evidence["mach_o_path_set"], [
                "Contents/Frameworks/libmpv.dylib",
                "Contents/MacOS/NetVplayerApp",
                "Contents/Resources/NodeRuntime/bin/node",
            ])
            self.assertEqual(
                evidence["mach_o_files"][0]["sha256"],
                hashlib.sha256(dylib.read_bytes()).hexdigest(),
            )
            self.assertEqual(spdx["spdxVersion"], "SPDX-2.3")
            self.assertEqual(len(spdx["files"]), 3)
            self.assertTrue(any(package["name"] == "swift-nio" for package in spdx["packages"]))
            self.assertEqual(cyclonedx["specVersion"], "1.6")
            self.assertTrue(any(component["name"] == "webtorrent" for component in cyclonedx["components"]))
            self.assertTrue(any(
                component["name"] == "Node.js" and component["version"] == "22.20.0"
                for component in cyclonedx["components"]
            ))
            self.assertTrue(any(
                component["name"] == "QuickJS" and component["version"] == "2026-06-04"
                for component in cyclonedx["components"]
            ))
            self.assertIsNotNone(evidence["inputs"]["node_runtime_manifest_sha256"])
            self.assertIsNotNone(evidence["inputs"]["quickjs_runtime_manifest_sha256"])
            self.assertNotIn(str(root), json.dumps(evidence))


if __name__ == "__main__":
    unittest.main()
