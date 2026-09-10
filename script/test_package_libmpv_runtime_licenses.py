from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_libmpv_runtime_licenses import (
    RuntimeLicenseError,
    audit_runtime,
    load_homebrew_metadata,
    package_runtime,
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def formula_metadata(name: str, version: str, license_expression: str = "MIT") -> dict[str, object]:
    return {
        "name": name,
        "tap": "homebrew/core",
        "license": license_expression,
        "homepage": f"https://example.invalid/{name}",
        "versions": {"stable": version},
        "revision": 0,
        "urls": {
            "stable": {
                "url": f"https://example.invalid/{name}-{version}.tar.xz",
                "checksum": "1" * 64,
            }
        },
        "tap_git_head": "2" * 40,
        "ruby_source_path": f"Formula/{name[0]}/{name}.rb",
        "ruby_source_checksum": {"sha256": "3" * 64},
    }


class Fixture:
    def __init__(self, root: Path, formula: str = "example", version: str = "1.0") -> None:
        self.root = root
        self.formula = formula
        self.version = version
        self.prefix = root / "homebrew/Cellar" / formula / version
        self.source = self.prefix / "lib/libexample.1.dylib"
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b"example dylib")
        self.app = root / "NetVplayer.app"
        self.frameworks = self.app / "Contents/Frameworks"
        self.resources = self.app / "Contents/Resources"
        self.frameworks.mkdir(parents=True)
        self.resources.mkdir(parents=True)
        (self.frameworks / self.source.name).write_bytes(self.source.read_bytes())
        self.mapping = root / "mapping.tsv"
        self.mapping.write_text(f"{self.source.name}\t{self.source}\n", encoding="utf-8")
        self.fallback = root / "fallback"
        self.fallback.mkdir()

    @property
    def metadata(self) -> dict[str, dict[str, object]]:
        return {self.formula: formula_metadata(self.formula, self.version)}


class LibmpvRuntimeLicenseTests(unittest.TestCase):
    def test_reads_metadata_from_exact_installed_formula_archive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory), formula="historical", version="1.5")
            formula_archive = fixture.prefix / ".brew/historical.rb"
            formula_archive.parent.mkdir()
            formula_archive.write_text('class Historical < Formula\nend\n', encoding="utf-8")
            receipt = {
                "source": {
                    "tap": "homebrew/core",
                    "tap_git_head": None,
                    "versions": {"stable": fixture.version},
                }
            }
            receipt_path = fixture.prefix / "INSTALL_RECEIPT.json"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            historical_metadata = formula_metadata(fixture.formula, fixture.version)
            historical_metadata["tap"] = None
            historical_metadata["tap_git_head"] = None
            historical_metadata["ruby_source_path"] = None
            historical_metadata["ruby_source_checksum"] = {"sha256": digest(formula_archive.read_bytes())}
            completed = subprocess.CompletedProcess(
                args=[], returncode=0, stdout=json.dumps(historical_metadata), stderr=""
            )

            with mock.patch("package_libmpv_runtime_licenses.subprocess.run", return_value=completed) as run:
                metadata = load_homebrew_metadata({fixture.formula: fixture.prefix})[fixture.formula]

            self.assertEqual(run.call_args.args[0][:3], ["brew", "ruby", "-e"])
            self.assertEqual(metadata["versions"]["stable"], fixture.version)
            self.assertEqual(metadata["tap"], "homebrew/core")
            self.assertIsNone(metadata["tap_git_head"])
            self.assertEqual(metadata["ruby_source_path"], ".brew/historical.rb")
            self.assertEqual(metadata["_metadata_origin"], "installed-keg-formula-archive")
            self.assertEqual(metadata["_install_receipt_sha256"], digest(receipt_path.read_bytes()))

            (fixture.prefix / "COPYING").write_text("Historical license\n", encoding="utf-8")
            report = package_runtime(
                fixture.app,
                fixture.mapping,
                fixture.fallback,
                {fixture.formula: metadata},
            )
            self.assertEqual(report["formula_count"], 1)
            manifest = json.loads(
                (fixture.app / "Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json").read_text(
                    encoding="utf-8"
                )
            )
            provenance = manifest["components"][0]["homebrew_formula"]
            self.assertEqual(provenance["metadata_origin"], "installed-keg-formula-archive")
            self.assertIsNone(provenance["tap_git_head"])

    def test_packages_bottle_license_and_audits_exact_dylib_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory))
            (fixture.prefix / "COPYING").write_text("Example license\n", encoding="utf-8")

            report = package_runtime(
                fixture.app,
                fixture.mapping,
                fixture.fallback,
                fixture.metadata,
            )

            self.assertEqual(report["dylib_count"], 1)
            self.assertEqual(report["formula_count"], 1)
            self.assertEqual(report["license_file_count"], 1)
            manifest = json.loads(
                (fixture.app / "Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertTrue(manifest["complete"])
            self.assertNotIn(str(fixture.root), json.dumps(manifest))

    def test_uses_versioned_and_hashed_source_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory), formula="fallback", version="2.0")
            license_data = b"Fallback license\n"
            component_root = fixture.fallback / fixture.formula
            component_root.mkdir()
            (component_root / "LICENCE").write_bytes(license_data)
            metadata = fixture.metadata
            source = metadata[fixture.formula]["urls"]["stable"]
            (fixture.fallback / "provenance.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "components": {
                            fixture.formula: {
                                "version": fixture.version,
                                "source_url": source["url"],
                                "source_sha256": source["checksum"],
                                "files": {"LICENCE": digest(license_data)},
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )

            package_runtime(fixture.app, fixture.mapping, fixture.fallback, metadata)

            manifest = json.loads(
                (fixture.app / "Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(
                manifest["components"][0]["license_files"][0]["origin"],
                "audited-source-fallback",
            )

    def test_accepts_git_source_only_when_revision_is_pinned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory), formula="git-source", version="3.0")
            (fixture.prefix / "COPYING").write_text("Git source license\n", encoding="utf-8")
            metadata = fixture.metadata
            stable = metadata[fixture.formula]["urls"]["stable"]
            stable["url"] = "https://example.invalid/git-source.git"
            stable["checksum"] = None
            stable["revision"] = "4" * 40

            package_runtime(fixture.app, fixture.mapping, fixture.fallback, metadata)

            manifest = json.loads(
                (fixture.app / "Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(manifest["components"][0]["source"]["revision"], "4" * 40)

    def test_rejects_missing_license_text_and_non_cellar_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory))
            with self.assertRaisesRegex(RuntimeLicenseError, "no distributable license text"):
                package_runtime(fixture.app, fixture.mapping, fixture.fallback, fixture.metadata)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = Fixture(root)
            outside = root / "outside/libexample.1.dylib"
            outside.parent.mkdir()
            outside.write_bytes(b"outside")
            fixture.mapping.write_text(f"{outside.name}\t{outside}\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeLicenseError, "not inside a Homebrew Cellar"):
                package_runtime(fixture.app, fixture.mapping, fixture.fallback, fixture.metadata)

    def test_audit_rejects_added_dylib_and_modified_license(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory))
            (fixture.prefix / "COPYING").write_text("Example license\n", encoding="utf-8")
            package_runtime(fixture.app, fixture.mapping, fixture.fallback, fixture.metadata)
            (fixture.frameworks / "libextra.dylib").write_bytes(b"extra")
            with self.assertRaisesRegex(RuntimeLicenseError, "does not cover"):
                audit_runtime(fixture.app)

        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(Path(directory))
            (fixture.prefix / "COPYING").write_text("Example license\n", encoding="utf-8")
            package_runtime(fixture.app, fixture.mapping, fixture.fallback, fixture.metadata)
            packaged_license = next(
                (fixture.app / "Contents/Resources/ThirdPartyLicenses/libmpv").rglob("COPYING")
            )
            packaged_license.write_text("modified\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeLicenseError, "hash mismatch"):
                audit_runtime(fixture.app)


if __name__ == "__main__":
    unittest.main()
