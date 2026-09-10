from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_torrent_bridge_replacements import TorrentReplacementError, apply_replacement


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
REAL_REPLACEMENT = (
    REPOSITORY_ROOT
    / "NetVplayer/Resources/TorrentBridge/replacements/compact-peer-address"
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture(root: Path) -> Path:
    package_root = root / "node_modules/compact2string"
    package_root.mkdir(parents=True)
    original = {
        "name": "compact2string",
        "version": "1.4.1",
        "license": "BSD",
    }
    package_json = json.dumps(original, sort_keys=True).encode()
    (package_root / "package.json").write_bytes(package_json)
    (package_root / "index.js").write_text("module.exports = null\n", encoding="utf-8")
    (root / "package-lock.json").write_text(
        json.dumps(
            {
                "lockfileVersion": 3,
                "packages": {
                    "node_modules/compact2string": {
                        "version": "1.4.1",
                        "license": "BSD",
                        "integrity": "sha512-fixture",
                    }
                },
            }
        ),
        encoding="utf-8",
    )
    replacement = root / "replacement"
    replacement.mkdir()
    (replacement / "index.cjs").write_text("module.exports = value => value\n", encoding="utf-8")
    (replacement / "package.json").write_text(
        json.dumps(
            {
                "name": "@netvplayer/compact-peer-address",
                "version": "1.0.0",
                "license": "MIT",
                "main": "index.cjs",
            }
        ),
        encoding="utf-8",
    )
    (replacement / "LICENSE").write_text("Permission is hereby granted.\n", encoding="utf-8")
    files = {
        name: digest(replacement / name)
        for name in ("LICENSE", "index.cjs", "package.json")
    }
    (replacement / "PROVENANCE.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "installed_path": "node_modules/compact2string",
                "original": {
                    **original,
                    "integrity": "sha512-fixture",
                    "package_json_sha256": hashlib.sha256(package_json).hexdigest(),
                },
                "replacement": {
                    "name": "@netvplayer/compact-peer-address",
                    "version": "1.0.0",
                    "license": "MIT",
                    "files": files,
                },
                "reason": "fixture",
            }
        ),
        encoding="utf-8",
    )
    return replacement


class TorrentBridgeReplacementTests(unittest.TestCase):
    def test_applies_reviewed_replacement_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            replacement = fixture(root)

            self.assertEqual(apply_replacement(root, replacement), "applied")
            self.assertEqual(apply_replacement(root, replacement), "already-applied")
            installed = json.loads(
                (root / "node_modules/compact2string/package.json").read_text()
            )
            self.assertEqual(installed["name"], "@netvplayer/compact-peer-address")
            self.assertFalse((root / "node_modules/compact2string/index.js").exists())

    def test_rejects_original_metadata_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            replacement = fixture(root)
            (root / "node_modules/compact2string/package.json").write_text(
                json.dumps(
                    {"name": "compact2string", "version": "1.4.1", "license": "BSD"},
                    indent=2,
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(TorrentReplacementError, "metadata hash mismatch"):
                apply_replacement(root, replacement)

    def test_replacement_matches_compact_peer_address_contract(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is unavailable")
        script = """
const decode = require(process.argv[1])
const ipv4 = Buffer.from('0A0A0A05FF80', 'hex')
const ipv6 = Buffer.from('2a03288021109f07faceb00c000000010050', 'hex')
const multi = Buffer.from('0A0A0A05008064383a636f6d', 'hex')
const result = [decode(ipv4), decode(ipv6), decode.multi(multi)]
process.stdout.write(JSON.stringify(result))
"""
        result = subprocess.run(
            [node, "-e", script, str(REAL_REPLACEMENT / "index.cjs")],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            json.loads(result.stdout),
            [
                "10.10.10.5:65408",
                "[2a03:2880:2110:9f07:face:b00c::1]:80",
                ["10.10.10.5:128", "100.56.58.99:28525"],
            ],
        )


if __name__ == "__main__":
    unittest.main()
