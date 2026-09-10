from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import time
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_provider_public_boundary import build_report
from export_provider_public_shell import (
    PublicExportError,
    SWIFT_TEST_COMMAND,
    exclusion_reason,
    export_public_shell,
    swift_test_environment,
)


def git(repo: Path, *arguments: str) -> str:
    environment = os.environ.copy()
    environment.update({
        "GIT_AUTHOR_NAME": "Public Export Test",
        "GIT_AUTHOR_EMAIL": "test@netvplayer.invalid",
        "GIT_COMMITTER_NAME": "Public Export Test",
        "GIT_COMMITTER_EMAIL": "test@netvplayer.invalid",
    })
    return subprocess.run(
        ["git", *arguments],
        cwd=repo,
        env=environment,
        text=True,
        capture_output=True,
        check=True,
    ).stdout


class ProviderPublicExportTests(unittest.TestCase):
    def test_swift_verification_disables_nested_sandbox_and_parallelism(self) -> None:
        self.assertEqual(
            SWIFT_TEST_COMMAND,
            ("swift", "test", "--disable-sandbox", "--no-parallel"),
        )

    def test_swift_verification_uses_isolated_writable_home_and_caches(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "swift-home"
            environment = swift_test_environment(home)

            self.assertEqual(environment["HOME"], str(home))
            self.assertEqual(environment["CFFIXED_USER_HOME"], str(home))
            self.assertTrue(Path(environment["XDG_CACHE_HOME"]).is_dir())
            self.assertTrue(Path(environment["CLANG_MODULE_CACHE_PATH"]).is_dir())
            self.assertTrue(Path(environment["SWIFTPM_MODULECACHE_OVERRIDE"]).is_dir())
            self.assertTrue(Path(environment["TMPDIR"]).is_dir())

    def test_exclusions_cover_private_sources_tests_and_reference_trees(self) -> None:
        self.assertEqual(exclusion_reason("FongMi/app/Spider.java"), "forbidden-private-tree")
        self.assertEqual(exclusion_reason("private-providers/bili-js/provider.mjs"), "forbidden-private-tree")
        self.assertEqual(
            exclusion_reason("NetVplayer/Sources/SpiderEngine/BiliNativeProvider.swift"),
            "site-specific-swift-provider",
        )
        self.assertEqual(
            exclusion_reason("NetVplayer/Tests/ConfigEngineTests/ExternalSourceCompatibilityTests.swift"),
            "site-specific-swift-provider-test",
        )
        self.assertEqual(
            exclusion_reason("NetVplayer/Sources/SpiderEngine/NewCzNativeProviderBrowserSession.swift"),
            "site-specific-swift-provider",
        )
        self.assertEqual(
            exclusion_reason("NetVplayer/Tests/ConfigEngineTests/NewCzBrowserSessionTests.swift"),
            "site-specific-swift-provider-test",
        )
        self.assertEqual(
            exclusion_reason(".github/workflows/provider-runtime-poc.yml"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_provider_runtime_packages.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_provider_production_release_gate.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/export_provider_private_source.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/build_all_private_java_providers.sh"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_bili_quickjs_live.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_generic_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_hmys_java_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/templates/provider-private-source.yml"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_bili_live_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("NetVplayer/Docs/provider_release_acceptance_20260909.md"),
            "internal-publication-artifact",
        )
        self.assertEqual(
            exclusion_reason("docs/data/provider-runtime-catalog-v1.json"),
            "internal-publication-artifact",
        )
        self.assertEqual(
            exclusion_reason("docs/evidence/device-capture.xml"),
            "internal-publication-artifact",
        )
        self.assertEqual(
            exclusion_reason("docs/data/torrent-bridge-license-audit-2026-08-18.json"),
            None,
        )
        self.assertEqual(
            exclusion_reason("docs/design/player-ui/assets/w700d1q75cms.jpg"),
            None,
        )
        self.assertEqual(
            exclusion_reason("script/test_private_anime1_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_alllive_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_alllive_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_dm84_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_dm84_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_anime1_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_bili_live_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_tangdou_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_tangdou_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_auete_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_auete_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_doubao_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_doubao_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_duboku_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_duboku_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_ygp_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_ygp_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_sixv_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_sixv_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_nmyswv_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_nmyswv_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_nmvod_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_nmvod_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_nmvod_python_verification.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_libvio_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_libvio_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_dytt_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_dytt_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_wwgz_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_wwgz_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_kanqiu_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_kanqiu_python_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_hbpianku8_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_hbpianku8_java_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_app99_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_app99_java_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_appdrama_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_appdrama_java_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_appsx_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_appsx_java_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_appgz_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_appgz_java_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_livegz_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_livegz_java_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_tingshu275_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/test_private_future_provider.py"),
            "internal-migration-tooling",
        )
        self.assertEqual(
            exclusion_reason("script/verify_tingshu275_java_provider.py"),
            "internal-migration-tooling",
        )
        self.assertIsNone(exclusion_reason("NetVplayer/Sources/SpiderEngine/RemoteSiteContentProvider.swift"))
        self.assertIsNone(exclusion_reason("script/test_provider_public_shell.py"))

    def test_export_has_one_clean_commit_and_passes_boundary_audit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            output = root / "public"
            (source / "NetVplayer/Sources/SpiderEngine").mkdir(parents=True)
            (source / "NetVplayer/Tests/ConfigEngineTests").mkdir(parents=True)
            (source / ".github/ISSUE_TEMPLATE").mkdir(parents=True)
            (source / "FongMi").mkdir()
            (source / "private-providers/example").mkdir(parents=True)
            files = {
                "README.md": "public\n",
                ".github/ISSUE_TEMPLATE/user-feedback.yml": "name: user feedback\n",
                ".github/ISSUE_TEMPLATE/config.yml": "blank_issues_enabled: true\n",
                "NetVplayer/Sources/SpiderEngine/RemoteSiteContentProvider.swift": "public struct Remote {}\n",
                "NetVplayer/Sources/SpiderEngine/BiliNativeProvider.swift": "private\n",
                "NetVplayer/Tests/ConfigEngineTests/ExternalSourceCompatibilityTests.swift": "private test\n",
                "FongMi/Spider.java": "reference\n",
                "private-providers/example/provider.py": "private\n",
            }
            for relative, content in files.items():
                path = source / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            git(source, "init", "--initial-branch=main")
            git(source, "add", "--", ".")
            git(source, "commit", "-m", "fixture")

            before_export = int(time.time())
            result = export_public_shell(source, output)

            self.assertEqual(git(output, "show", "-s", "--format=%an|%ae|%cn|%ce").strip(),
                             "spudhero|318930237+spudhero@users.noreply.github.com|spudhero|318930237+spudhero@users.noreply.github.com")
            for field in ("%at", "%ct"):
                timestamp = int(git(output, "show", "-s", f"--format={field}").strip())
                self.assertGreaterEqual(timestamp, before_export)
                self.assertLessEqual(timestamp, int(time.time()))

            self.assertTrue(result["ok"])
            self.assertEqual(git(output, "rev-list", "--count", "HEAD").strip(), "1")
            self.assertEqual(git(output, "status", "--porcelain"), "")
            self.assertTrue((output / "README.md").is_file())
            self.assertTrue((output / ".github/ISSUE_TEMPLATE/user-feedback.yml").is_file())
            self.assertTrue((output / ".github/ISSUE_TEMPLATE/config.yml").is_file())
            self.assertFalse((output / "FongMi").exists())
            self.assertFalse((output / "private-providers").exists())
            self.assertFalse((output / "NetVplayer/Sources/SpiderEngine/BiliNativeProvider.swift").exists())
            self.assertTrue(build_report(output)["summary"]["release_ready"])

    def test_export_rejects_dirty_source_unless_preview_is_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            output = root / "public"
            source.mkdir()
            readme = source / "README.md"
            readme.write_text("committed\n", encoding="utf-8")
            git(source, "init", "--initial-branch=main")
            git(source, "add", "--", ".")
            git(source, "commit", "-m", "fixture")
            readme.write_text("preview\n", encoding="utf-8")

            with self.assertRaisesRegex(PublicExportError, "source repository is dirty"):
                export_public_shell(source, output)

            result = export_public_shell(source, output, allow_dirty=True)
            self.assertTrue(result["ok"])


if __name__ == "__main__":
    unittest.main()
