#!/usr/bin/env python3
from __future__ import annotations

import json
import base64
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_provider_package import extract_archive, validate_package


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "script/build_provider_package.py"


class ProviderPackageTests(unittest.TestCase):
    def build_package(self) -> tuple[Path, tempfile.TemporaryDirectory[str]]:
        temporary = tempfile.TemporaryDirectory(prefix="netvplayer-provider-package-test-")
        root = Path(temporary.name)
        source = root / "source"
        source.mkdir()
        (source / "runner").write_text("runner\n", encoding="utf-8")
        (source / "provider.py").write_text("class Spider: pass\n", encoding="utf-8")
        license_file = root / "LICENSE"
        license_file.write_text("Fixture Provider License\n", encoding="utf-8")
        manifest = {
            "provider_id": "fixture.package",
            "version": "1.0.0",
            "protocol": 1,
            "shell_min_version": "1.0.0",
            "shell_max_version": None,
            "macos_min_version": "14.0",
            "architectures": ["arm64", "x86_64"],
            "runtime": "python",
            "entrypoint": "provider.py",
            "runner": "runner",
            "runtime_executable": "runner",
            "provider_class": "Spider",
            "capabilities": ["home", "search", "detail", "player"],
            "assets": [
                {"path": "runner", "sha256": "", "executable": True},
                {"path": "provider.py", "sha256": "", "executable": False},
            ],
            "source_revision": "test",
            "license": "MIT",
            "status": "compatible",
            "revoked": False,
        }
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        key = root / "private.pem"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        archive = root / "fixture.zip"
        launcher = root / "ProviderSandboxLauncher"
        shutil.copyfile("/usr/bin/true", launcher)
        launcher.chmod(0o755)
        subprocess.run(
            [
                "python3", str(BUILDER),
                "--source", str(source),
                "--manifest", str(manifest_path),
                "--license-file", str(license_file),
                "--private-key", str(key),
                "--output", str(archive),
                "--sandbox-launcher", str(launcher),
                "--codesign-identity", "-",
                "--release-profile", "community-adhoc",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        return archive, temporary

    def test_builder_output_passes_directory_and_archive_validation(self) -> None:
        archive, temporary = self.build_package()
        with self.subTest("archive"):
            self.assertEqual(validate_package(archive), [])
        with tempfile.TemporaryDirectory(prefix="netvplayer-provider-package-extract-") as extracted:
            with zipfile.ZipFile(archive) as handle:
                self.assertIn("LICENSES/PROVIDER.txt", handle.namelist())
            extract_archive(archive, Path(extracted))
            self.assertEqual(validate_package(Path(extracted)), [])
            manifest = json.loads((Path(extracted) / "manifest.json").read_text())
            self.assertEqual(manifest["host_capabilities"], [])
            wire_verifier = Path(temporary.name) / "verify-manifest-wire"
            subprocess.run([
                "xcrun", "swiftc", "-module-cache-path", str(Path(temporary.name) / "ModuleCache"),
                str(ROOT / "NetVplayer/Sources/ProviderSDK/ProviderManifest.swift"),
                str(ROOT / "NetVplayer/Sources/ProviderSDK/ProviderJSONValue.swift"),
                str(ROOT / "script/verify_provider_manifest_wire.swift"), "-o", str(wire_verifier),
            ], check=True, capture_output=True)
            key = subprocess.check_output(["openssl", "pkey", "-in", str(Path(temporary.name) / "private.pem"),
                                           "-pubout", "-outform", "DER"])[-32:]
            subprocess.run([str(wire_verifier), str(Path(extracted) / "signed-manifest.json"),
                            base64.b64encode(key).decode()], check=True, capture_output=True)
        temporary.cleanup()

    def test_quickjs_package_preserves_signed_runtime_and_host_capability_assets(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-quickjs-provider-package-") as temporary:
            root = Path(temporary)
            source = root / "source"
            runtime = source / "runtimes/quickjs/bin/qjs"
            polyglot = source / "runtimes/quickjs/bin/qjs-cosmo"
            bootstrap = source / "runtimes/quickjs/bin/.ape-1.10"
            runner = source / "provider-runners/quickjs/provider_runner.mjs"
            host_api = source / "provider-runners/quickjs/host_api.mjs"
            provider = source / "provider/fixture.mjs"
            for path in (runtime, polyglot, bootstrap, runner, host_api, provider):
                path.parent.mkdir(parents=True, exist_ok=True)
            runtime.write_text(
                "#!/bin/sh\n"
                "runtime_dir=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n"
                "export TMPDIR=\"$runtime_dir\"\n"
                "exec /bin/sh \"$runtime_dir/qjs-cosmo\" \"$@\"\n",
                encoding="utf-8",
            )
            polyglot.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            bootstrap.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            runner.write_text("// quickjs runner fixture\n", encoding="utf-8")
            host_api.write_text("// host API fixture\n", encoding="utf-8")
            provider.write_text("export class Spider {}\n", encoding="utf-8")
            for path in (runtime, polyglot, bootstrap):
                path.chmod(0o755)
            license_file = root / "LICENSE"
            license_file.write_text("Fixture QuickJS Provider License\n", encoding="utf-8")
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps({
                "provider_id": "fixture.quickjs.package",
                "version": "1.0.0",
                "protocol": 1,
                "shell_min_version": "1.0.0",
                "macos_min_version": "14.0",
                "architectures": ["arm64", "x86_64"],
                "runtime": "quickjs",
                "entrypoint": "provider/fixture.mjs",
                "runner": "provider-runners/quickjs/provider_runner.mjs",
                "runtime_executable": "runtimes/quickjs/bin/qjs",
                "provider_class": "Spider",
                "capabilities": ["home", "search", "detail", "player"],
                "host_capabilities": ["console", "base64", "md5", "url"],
                "assets": [
                    {"path": "runtimes/quickjs/bin/qjs", "sha256": "", "executable": True},
                    {"path": "runtimes/quickjs/bin/qjs-cosmo", "sha256": "", "executable": True},
                    {"path": "runtimes/quickjs/bin/.ape-1.10", "sha256": "", "executable": True},
                    {"path": "provider-runners/quickjs/provider_runner.mjs", "sha256": "", "executable": False},
                    {"path": "provider-runners/quickjs/host_api.mjs", "sha256": "", "executable": False},
                    {"path": "provider/fixture.mjs", "sha256": "", "executable": False},
                ],
                "source_revision": "test",
                "license": "MIT",
                "status": "compatible",
                "revoked": False,
            }), encoding="utf-8")
            key = root / "private.pem"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(key)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            archive = root / "quickjs-fixture.zip"
            launcher = root / "ProviderSandboxLauncher"
            shutil.copyfile("/usr/bin/true", launcher)
            launcher.chmod(0o755)
            subprocess.run([
                "python3", str(BUILDER),
                "--source", str(source),
                "--manifest", str(manifest_path),
                "--license-file", str(license_file),
                "--private-key", str(key),
                "--output", str(archive),
                "--sandbox-launcher", str(launcher),
                "--codesign-identity", "-",
                "--release-profile", "community-adhoc",
            ], check=True, stdout=subprocess.DEVNULL)
            self.assertEqual(validate_package(archive), [])
            with tempfile.TemporaryDirectory(prefix="netvplayer-quickjs-provider-package-extract-") as extracted:
                extract_archive(archive, Path(extracted))
                packaged_manifest = json.loads((Path(extracted) / "manifest.json").read_text(encoding="utf-8"))
                self.assertEqual(packaged_manifest["runtime"], "quickjs")
                self.assertEqual(packaged_manifest["host_capabilities"], ["console", "base64", "md5", "url"])
                declared = {asset["path"] for asset in packaged_manifest["assets"]}
                self.assertIn(packaged_manifest["runtime_executable"], declared)
                self.assertIn(packaged_manifest["runner"], declared)

    def test_validator_rejects_empty_provider_license(self) -> None:
        archive, temporary = self.build_package()
        with tempfile.TemporaryDirectory(prefix="netvplayer-provider-package-license-") as extracted:
            with zipfile.ZipFile(archive) as handle:
                handle.extractall(extracted)
            root = Path(extracted)
            (root / "runner").chmod(0o755)
            (root / "LICENSES/PROVIDER.txt").write_text("", encoding="utf-8")
            self.assertTrue(any("must be non-empty UTF-8 text" in error for error in validate_package(root)))
        temporary.cleanup()

    def test_builder_rejects_empty_provider_license(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-provider-package-empty-license-") as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "runner").write_text("runner\n", encoding="utf-8")
            license_file = root / "LICENSE"
            license_file.write_text("", encoding="utf-8")
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps({
                "provider_id": "fixture.package",
                "version": "1.0.0",
                "architectures": ["arm64"],
                "runtime": "python",
                "entrypoint": "runner",
                "runner": "runner",
                "runtime_executable": "runner",
                "assets": [{"path": "runner", "sha256": "", "executable": True}],
                "license": "MIT",
                "status": "compatible",
                "revoked": False,
            }), encoding="utf-8")
            key = root / "private.pem"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(key)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            result = subprocess.run([
                "python3", str(BUILDER),
                "--source", str(source),
                "--manifest", str(manifest_path),
                "--license-file", str(license_file),
                "--private-key", str(key),
                "--output", str(root / "fixture.zip"),
            ], text=True, capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("non-empty regular file", result.stderr)

    def test_validator_rejects_undeclared_payload(self) -> None:
        archive, temporary = self.build_package()
        with tempfile.TemporaryDirectory(prefix="netvplayer-provider-package-tamper-") as extracted:
            with zipfile.ZipFile(archive) as handle:
                handle.extractall(extracted)
            root = Path(extracted)
            (root / "unlisted.py").write_text("print('not signed')\n", encoding="utf-8")
            self.assertTrue(any("undeclared package files" in error for error in validate_package(root)))
        temporary.cleanup()

    def test_validator_rejects_symlink_payload(self) -> None:
        archive, temporary = self.build_package()
        with tempfile.TemporaryDirectory(prefix="netvplayer-provider-package-link-") as extracted:
            with zipfile.ZipFile(archive) as handle:
                handle.extractall(extracted)
            root = Path(extracted)
            (root / "runner").chmod(0o755)
            os.symlink(root / "provider.py", root / "linked.py")
            self.assertTrue(any("symlink is not allowed" in error for error in validate_package(root)))
        temporary.cleanup()

    def test_builder_rejects_ambiguous_architecture_declaration(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-provider-package-arch-") as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "runner").write_text("runner\n", encoding="utf-8")
            license_file = root / "LICENSE"
            license_file.write_text("Fixture Provider License\n", encoding="utf-8")
            manifest = {
                "provider_id": "fixture.package",
                "version": "1.0.0",
                "architectures": ["universal2", "arm64"],
                "runtime": "python",
                "entrypoint": "runner",
                "runner": "runner",
                "runtime_executable": "runner",
                "assets": [{"path": "runner", "sha256": "", "executable": True}],
                "license": "MIT",
                "status": "compatible",
                "revoked": False,
            }
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            key = root / "private.pem"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(key)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            result = subprocess.run(
                [
                    "python3", str(BUILDER),
                    "--source", str(source),
                    "--manifest", str(manifest_path),
                    "--license-file", str(license_file),
                    "--private-key", str(key),
                    "--output", str(root / "fixture.zip"),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("manifest architectures", result.stderr)


if __name__ == "__main__":
    unittest.main()
