from __future__ import annotations

import json
import hashlib
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_torrent_bridge_licenses import (
    TorrentLicenseAuditError,
    build_report,
    main,
    serialized,
)


def package_fixture(
    root: Path,
    name: str,
    version: str = "1.0.0",
    license_value: str | None = "MIT",
    license_text: str | None = "Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS.\n",
    readme: str | None = None,
    legacy: bool = False,
    author: object = "Fixture Author",
) -> None:
    package_root = root / "node_modules" / name
    package_root.mkdir(parents=True)
    package: dict[str, object] = {"name": name, "version": version, "author": author}
    if license_value is not None:
        if legacy:
            package["licenses"] = [{"type": license_value}]
        else:
            package["license"] = license_value
    (package_root / "package.json").write_text(json.dumps(package), encoding="utf-8")
    if license_text is not None:
        (package_root / "LICENSE").write_text(license_text, encoding="utf-8")
    if readme is not None:
        (package_root / "README.md").write_text(readme, encoding="utf-8")


def lock_fixture(root: Path, records: list[tuple[str, str, str | None]]) -> None:
    packages: dict[str, object] = {"": {"name": "fixture", "version": "1.0.0"}}
    for name, version, license_value in records:
        record: dict[str, object] = {
            "version": version,
            "integrity": "sha512-fixture",
            "resolved": f"https://registry.npmjs.org/{name}/-/{name}-{version}.tgz",
        }
        if license_value is not None:
            record["license"] = license_value
        packages[f"node_modules/{name}"] = record
    (root / "package-lock.json").write_text(
        json.dumps({"lockfileVersion": 3, "packages": packages}),
        encoding="utf-8",
    )


class TorrentBridgeLicenseAuditTests(unittest.TestCase):
    def test_complete_locked_package_with_license_file_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_fixture(root, "complete")
            lock_fixture(root, [("complete", "1.0.0", "MIT")])

            report = build_report(root)

            self.assertTrue(report["release_ready"])
            self.assertEqual(report["summary"]["standalone_text_packages"], 1)
            self.assertEqual(report["blockers"], [])

    def test_full_license_in_readme_counts_as_embedded_text(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_fixture(
                root,
                "embedded",
                license_text=None,
                readme="Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS.\n",
            )
            lock_fixture(root, [("embedded", "1.0.0", "MIT")])

            report = build_report(root)

            self.assertTrue(report["release_ready"])
            self.assertEqual(report["summary"]["embedded_text_packages"], 1)

    def test_exact_spdx_supplement_closes_missing_archive_text(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_fixture(root, "supplemented", license_text=None)
            lock_fixture(root, [("supplemented", "1.0.0", "MIT")])
            license_root = root / "THIRD_PARTY_LICENSES"
            license_root.mkdir()
            license_text = "Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS.\n"
            canonical = license_root / "MIT.txt"
            canonical.write_text(license_text, encoding="utf-8")
            package_json = root / "node_modules/supplemented/package.json"
            (license_root / "supplements.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "canonical_licenses": {
                            "MIT": {
                                "path": "THIRD_PARTY_LICENSES/MIT.txt",
                                "sha256": hashlib.sha256(license_text.encode()).hexdigest(),
                                "source": (
                                    "https://github.com/spdx/license-list-data/blob/"
                                    f"{'0' * 40}/text/MIT.txt"
                                ),
                            }
                        },
                        "packages": [
                            {
                                "name": "supplemented",
                                "version": "1.0.0",
                                "license": "MIT",
                                "author": "Fixture Author",
                                "package_json_sha256": hashlib.sha256(
                                    package_json.read_bytes()
                                ).hexdigest(),
                                "integrity": "sha512-fixture",
                                "resolved": (
                                    "https://registry.npmjs.org/supplemented/"
                                    "-/supplemented-1.0.0.tgz"
                                ),
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            report = build_report(root)

            self.assertTrue(report["release_ready"])
            self.assertEqual(report["summary"]["supplemented_text_packages"], 1)
            self.assertEqual(report["summary"]["covered_packages"], 1)
            self.assertEqual(report["packages"][0]["license_evidence"][0]["kind"], "spdx-supplement")

            package = json.loads(package_json.read_text())
            package["author"] = "Unexpected Author"
            package_json.write_text(json.dumps(package), encoding="utf-8")
            with self.assertRaisesRegex(TorrentLicenseAuditError, "package_json_sha256 drifted"):
                build_report(root)

    def test_spdx_supplement_rejects_unpinned_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_fixture(root, "supplemented", license_text=None)
            lock_fixture(root, [("supplemented", "1.0.0", "MIT")])
            license_root = root / "THIRD_PARTY_LICENSES"
            license_root.mkdir()
            canonical = license_root / "MIT.txt"
            canonical.write_text(
                "Permission is hereby granted. THE SOFTWARE IS PROVIDED AS IS.\n",
                encoding="utf-8",
            )
            (license_root / "supplements.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "canonical_licenses": {
                            "MIT": {
                                "path": "THIRD_PARTY_LICENSES/MIT.txt",
                                "sha256": hashlib.sha256(canonical.read_bytes()).hexdigest(),
                                "source": "https://github.com/spdx/license-list-data/blob/main/text/MIT.txt",
                            }
                        },
                        "packages": [],
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(TorrentLicenseAuditError, "untrusted canonical license source"):
                build_report(root)

    def test_missing_text_and_version_drift_are_blockers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_fixture(root, "missing", version="2.0.0", license_text=None)
            lock_fixture(root, [("missing", "1.0.0", "MIT")])

            report = build_report(root)

            self.assertFalse(report["release_ready"])
            self.assertIn("missing-license-text", report["blockers"][0]["reasons"])
            self.assertIn("installed-version-does-not-match-lock", report["blockers"][0]["reasons"])
            snapshot = root / "known.json"
            snapshot.write_text(serialized(report), encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                with mock.patch.object(
                    sys,
                    "argv",
                    ["audit", "--root", str(root), "--check", str(snapshot)],
                ):
                    self.assertEqual(main(), 1)
                with mock.patch.object(
                    sys,
                    "argv",
                    [
                        "audit",
                        "--root",
                        str(root),
                        "--check",
                        str(snapshot),
                        "--allow-known-blockers",
                    ],
                ):
                    self.assertEqual(main(), 0)

    def test_readme_mit_conflicts_with_non_mit_package_declaration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_fixture(
                root,
                "conflict",
                license_value="BSD",
                license_text=None,
                readme="This package is available under the MIT License.\n",
            )
            package_fixture(
                root,
                "multi-license",
                license_value="(BSD-2-Clause OR MIT OR Apache-2.0)",
                readme="This package is also available under the MIT License.\n",
            )
            lock_fixture(
                root,
                [
                    ("conflict", "1.0.0", "BSD"),
                    ("multi-license", "1.0.0", "(BSD-2-Clause OR MIT OR Apache-2.0)"),
                ],
            )

            report = build_report(root)

            self.assertEqual(len(report["blockers"]), 1)
            self.assertIn("conflicting-license-declaration", report["blockers"][0]["reasons"])

    def test_legacy_license_array_and_serialization_are_stable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_fixture(root, "legacy", legacy=True)
            lock_fixture(root, [("legacy", "1.0.0", None)])

            report = build_report(root)

            self.assertTrue(report["release_ready"])
            self.assertEqual(report["summary"]["legacy_license_packages"], 1)
            self.assertEqual(report["packages"][0]["declared_license"], "MIT")
            self.assertEqual(report["packages"][0]["license_evidence"][0]["kind"], "standalone")
            self.assertEqual(json.loads(serialized(report)), report)


if __name__ == "__main__":
    unittest.main()
