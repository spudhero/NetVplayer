from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_provider_public_boundary import build_report, serialized
from audit_provider_public_release import build_release_report


def git(repo: Path, *arguments: str) -> str:
    environment = os.environ.copy()
    environment.update({
        "GIT_AUTHOR_NAME": "Public Release Audit Test",
        "GIT_AUTHOR_EMAIL": "test@netvplayer.invalid",
        "GIT_COMMITTER_NAME": "Public Release Audit Test",
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


def public_fixture(root: Path) -> Path:
    repo = root / "public"
    (repo / ".github/ISSUE_TEMPLATE").mkdir(parents=True)
    (repo / ".github/workflows").mkdir(parents=True)
    (repo / "docs/data").mkdir(parents=True)
    (repo / "provider-sdk").mkdir(parents=True)
    (repo / "NetVplayer/Sources/ProviderSandboxLauncher").mkdir(parents=True)
    (repo / "script").mkdir(parents=True)
    (repo / "LICENSE").write_text("MIT License\n", encoding="utf-8")
    (repo / "provider-sdk/LICENSE").write_text("MIT License\n", encoding="utf-8")
    (repo / ".github/workflows/provider-public-shell.yml").write_text("name: public\n", encoding="utf-8")
    (repo / ".github/ISSUE_TEMPLATE/user-feedback.yml").write_text(
        "name: user feedback\n", encoding="utf-8"
    )
    (repo / ".github/ISSUE_TEMPLATE/config.yml").write_text(
        "blank_issues_enabled: true\n", encoding="utf-8"
    )
    (repo / "NetVplayer/Sources/ProviderSandboxLauncher/main.swift").write_text(
        "print(\"launcher fixture\")\n", encoding="utf-8"
    )
    for name in (
        "build_provider_sandbox_launcher.py",
        "validate_provider_sandbox.py",
        "test_provider_app_sandbox.py",
    ):
        (repo / "script" / name).write_text("# fixture\n", encoding="utf-8")
    git(repo, "init", "--initial-branch=main")
    git(repo, "add", "--", ".")
    git(repo, "commit", "-m", "initial public fixture")
    report_path = repo / "docs/data/provider-public-boundary-v1.json"
    report_path.write_text(serialized(build_report(repo)), encoding="utf-8")
    git(repo, "add", "--", ".")
    git(repo, "commit", "-m", "add boundary report")
    return repo


class ProviderPublicReleaseAuditTests(unittest.TestCase):
    def test_minimal_public_repository_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = build_release_report(public_fixture(Path(directory)))
            self.assertTrue(report["release_ready"])
            self.assertEqual(report["blocking_reasons"], [])

    def test_secret_and_executable_binary_are_reported_without_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = public_fixture(Path(directory))
            token = "AKIA" + ("A" * 16)
            (repo / "credential.txt").write_text(token + "\n", encoding="utf-8")
            (repo / "payload.jar").write_bytes(b"not a real jar")
            git(repo, "add", "--", ".")
            git(repo, "commit", "-m", "unsafe fixture")

            report = build_release_report(repo)

            self.assertFalse(report["release_ready"])
            self.assertIn("potential-secrets", report["blocking_reasons"])
            self.assertIn("forbidden-executable-binaries", report["blocking_reasons"])
            self.assertEqual(report["secret_findings"][0]["kind"], "aws-access-key")
            self.assertNotIn(token, str(report))

    def test_private_key_audit_requires_a_complete_static_key_block(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = public_fixture(Path(directory))
            (repo / "parser.swift").write_text(
                'let marker = "-----BEGIN PRIVATE KEY-----"\n',
                encoding="utf-8",
            )
            (repo / "invalid-fixture.txt").write_text(
                "-----BEGIN RSA PRIVATE KEY-----\nAQ==\n-----END RSA PRIVATE KEY-----\n",
                encoding="utf-8",
            )
            git(repo, "add", "--", ".")
            git(repo, "commit", "-m", "add harmless PEM markers")
            self.assertTrue(build_release_report(repo)["release_ready"])

            (repo / "leaked.pem").write_text(
                "-----BEGIN PRIVATE KEY-----\n"
                + ("A" * 120)
                + "\n-----END PRIVATE KEY-----\n",
                encoding="utf-8",
            )
            git(repo, "add", "--", "leaked.pem")
            git(repo, "commit", "-m", "add leaked key fixture")

            report = build_release_report(repo)
            self.assertFalse(report["release_ready"])
            self.assertEqual(report["secret_findings"], [
                {"path": "leaked.pem", "line": 1, "kind": "private-key"},
            ])

    def test_internal_workflow_and_build_artifact_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = public_fixture(Path(directory))
            (repo / ".github/workflows/provider-runtime-poc.yml").write_text("name: internal\n", encoding="utf-8")
            (repo / "script/verify_generic_python_provider.py").write_text("# internal\n", encoding="utf-8")
            (repo / "script/verify_hmys_java_provider.py").write_text("# internal\n", encoding="utf-8")
            (repo / "dist").mkdir()
            (repo / "dist/result.txt").write_text("generated\n", encoding="utf-8")
            git(repo, "add", "--", ".")
            git(repo, "commit", "-m", "internal fixture")

            report = build_release_report(repo)

            self.assertIn("internal-migration-tooling-present", report["blocking_reasons"])
            self.assertIn("script/verify_generic_python_provider.py", report["internal_only_files"])
            self.assertIn("script/verify_hmys_java_provider.py", report["internal_only_files"])
            self.assertIn("tracked-build-artifacts", report["blocking_reasons"])

    def test_internal_progress_documents_and_provider_catalog_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = public_fixture(Path(directory))
            (repo / "NetVplayer/Docs").mkdir(parents=True)
            (repo / "NetVplayer/Docs/progress.md").write_text("internal progress\n", encoding="utf-8")
            (repo / "docs/data/provider-runtime-catalog-v1.json").write_text("[]\n", encoding="utf-8")
            git(repo, "add", "--", ".")
            git(repo, "commit", "-m", "add internal publication artifacts")

            report = build_release_report(repo)

            self.assertFalse(report["release_ready"])
            self.assertIn("internal-publication-artifacts-present", report["blocking_reasons"])
            self.assertEqual(report["internal_publication_artifacts"], [
                "NetVplayer/Docs/progress.md",
                "docs/data/provider-runtime-catalog-v1.json",
            ])

    def test_provider_sdk_license_must_match_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = public_fixture(Path(directory))
            (repo / "provider-sdk/LICENSE").write_text("different\n", encoding="utf-8")
            git(repo, "add", "--", "provider-sdk/LICENSE")
            git(repo, "commit", "-m", "drift SDK license")

            report = build_release_report(repo)

            self.assertFalse(report["release_ready"])
            self.assertFalse(report["provider_sdk_license_matches_root"])
            self.assertIn("provider-sdk-license-mismatch", report["blocking_reasons"])


if __name__ == "__main__":
    unittest.main()
