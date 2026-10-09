from __future__ import annotations

import os
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_publication_identity as identity


GUARD = Path(identity.__file__).resolve()
SPUD_REMOTE = "https://github.com/spudhero/NetVplayer.git"


class PublicationIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="netvplayer-identity-test-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.command("init", "--initial-branch=main")
        self.command("remote", "add", "origin", SPUD_REMOTE)
        self.command("config", "user.name", identity.IDENTITIES["spudhero"][0])
        self.command("config", "user.email", identity.IDENTITIES["spudhero"][1])

    def command(self, *args: str, env: dict | None = None, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(["git", *args], cwd=self.repo, env=env or self.env,
                              capture_output=True, text=True, check=check)

    def guard(self, *args: str, env: dict | None = None, stdin: str = "") -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(GUARD), "--repo", str(self.repo), *args],
                              cwd=self.repo, env=env or self.env, input=stdin, capture_output=True, text=True)

    def commit(self, *, author: tuple | None = None, committer: tuple | None = None,
               message: str = "fixture") -> str:
        env = self.env.copy()
        for role, value in (("AUTHOR", author), ("COMMITTER", committer)):
            if value:
                env[f"GIT_{role}_NAME"], env[f"GIT_{role}_EMAIL"] = value
        self.command("-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "--allow-empty-message",
                     "-m", message, env=env)
        return self.command("rev-parse", "HEAD").stdout.strip()

    def test_owner_resolution_handles_supported_urls_without_disclosing_credentials(self) -> None:
        for url in (SPUD_REMOTE, "git@github.com:spudhero/NetVplayer.git",
                    "git@github-spudhero:spudhero/NetVplayer.git",
                    "ssh://git@github.com/spudhero/NetVplayer.git",
                    "https://secret:token@github.com/spudhero/NetVplayer.git"):
            self.assertEqual(identity.remote_owner(url), "spudhero")
        with self.assertRaises(identity.IdentityError) as error:
            identity.remote_owner("https://secret:token@example.com/spudhero/NetVplayer.git")
        self.assertNotIn("secret", str(error.exception))
        self.assertNotIn("token", str(error.exception))

    def test_owner_override_cannot_bypass_origin(self) -> None:
        result = self.guard("--owner", "chang-chaunce", "--history-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disagrees", result.stderr)

    def test_correct_identity_and_empty_repository_pass(self) -> None:
        self.assertEqual(self.guard().returncode, 0)
        self.commit(message="")
        self.assertEqual(self.guard().returncode, 0)

    def test_wrong_effective_author_and_committer_are_independently_blocked(self) -> None:
        for role in ("AUTHOR", "COMMITTER"):
            env = self.env.copy()
            env[f"GIT_{role}_NAME"], env[f"GIT_{role}_EMAIL"] = identity.IDENTITIES["chang-chaunce"]
            result = self.guard("--current-only", env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(role.lower(), result.stderr)

    def test_internal_owner_keeps_internal_identity(self) -> None:
        self.command("remote", "set-url", "origin", "git@github.com:chang-chaunce/NetVplayer.git")
        self.assertEqual(self.guard("--install-hooks").returncode, 0)
        for field, expected in zip(("name", "email"), identity.IDENTITIES["chang-chaunce"]):
            self.assertEqual(self.command("config", "--local", "user." + field).stdout.strip(), expected)
        result = self.command("commit", "--allow-empty", "-m", "internal owner", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_history_rejects_personal_author_even_when_local_configuration_is_correct(self) -> None:
        self.commit(author=identity.IDENTITIES["chang-chaunce"])
        result = self.guard("--history-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("author", result.stderr)

    def test_history_rejects_personal_committer(self) -> None:
        self.commit(committer=identity.IDENTITIES["chang-chaunce"])
        result = self.guard("--history-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("committer", result.stderr)

    def test_real_commit_hook_blocks_author_override_before_commit_is_created(self) -> None:
        self.assertEqual(self.guard("--install-hooks").returncode, 0)
        result = self.command("commit", "--allow-empty", "--author", "chaunce <chang.chaunce@gmail.com>",
                              "-m", "must fail", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("author must", result.stderr)
        self.assertNotEqual(self.command("rev-parse", "--verify", "HEAD", check=False).returncode, 0)

    def test_real_commit_message_hook_blocks_personal_coauthor(self) -> None:
        self.assertEqual(self.guard("--install-hooks").returncode, 0)
        result = self.command("commit", "--allow-empty", "-m",
                              "fixture\n\nCo-authored-by: chaunce <chang.chaunce@gmail.com>", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("coauthor", result.stderr)

    def test_legitimate_external_contributors_and_existing_release_identity_are_preserved(self) -> None:
        self.commit(author=("External Contributor", "external@example.invalid"))
        self.commit(author=("Spudhero", "spudhero585@gmail.com"), committer=("GitHub", "noreply@github.com"))
        self.command("tag", "-a", "1.1.1", "-m", "preserved release")
        tag = self.command("rev-parse", "1.1.1").stdout
        self.assertEqual(self.guard("--history-only").returncode, 0)
        self.assertEqual(self.command("rev-parse", "1.1.1").stdout, tag)

    def test_wrong_annotated_tagger_is_blocked(self) -> None:
        self.commit()
        env = self.env.copy()
        env.update(GIT_COMMITTER_NAME="chaunce", GIT_COMMITTER_EMAIL="chang.chaunce@gmail.com")
        self.command("tag", "-a", "bad", "-m", "wrong tagger", env=env)
        result = self.guard("--history-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tagger", result.stderr)

    def test_pre_push_checks_detached_objects_outside_branch_history(self) -> None:
        self.commit()
        old = self.command("rev-parse", "HEAD").stdout.strip()
        bad = self.commit(author=identity.IDENTITIES["chang-chaunce"])
        self.command("reset", "--hard", old)
        result = self.guard("--pre-push", SPUD_REMOTE,
                            stdin=f"{bad} {bad} refs/heads/other {'0' * 40}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("author", result.stderr)

    def test_push_to_another_owner_is_blocked(self) -> None:
        result = self.guard("--pre-push", "https://github.com/chang-chaunce/NetVplayer.git")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destination owner", result.stderr)

    def test_installer_preserves_existing_hooks_and_configuration(self) -> None:
        path = self.repo / ".git/hooks/pre-push"
        path.write_text("#!/bin/sh\n# existing hook\n")
        before = (self.repo / ".git/config").read_bytes()
        result = self.guard("--install-hooks")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires integration", result.stderr)
        self.assertEqual(path.read_text(), "#!/bin/sh\n# existing hook\n")
        self.assertEqual((self.repo / ".git/config").read_bytes(), before)

    def test_installer_preserves_custom_shared_hooks_path(self) -> None:
        shared = Path(self.temp.name) / "shared-hooks"
        self.command("config", "core.hooksPath", str(shared))
        result = self.guard("--install-hooks")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(shared.exists())

    def test_actual_index_api_payload_specifies_author_and_committer(self) -> None:
        if not (GUARD.parent / "publish_catalog_provider_release.py").exists():
            self.skipTest("private Provider publisher not present in this repository")
        import publish_catalog_provider_release as catalog
        index = {"protocol": 2, "generated_at": 0, "releases": [], "revoked": []}
        content = {"sha": "old", "content": base64.b64encode(json.dumps({"index": index}).encode()).decode()}
        payloads = []

        def github(*args: str) -> dict:
            if "PUT" not in args:
                return content
            payloads.append(json.loads(Path(args[-1]).read_text()))
            return {"commit": {"sha": "new"}}

        release = {"provider_id": "netvplayer.catalog.python", "version": "1.1.6",
                   "architectures": ["arm64"], "archive_sha256": "a" * 64}
        with patch.object(catalog, "gh", side_effect=github), \
                patch.object(catalog, "require_github_account"), \
                patch.object(catalog, "verify_signature"), \
                patch.object(catalog, "sign", return_value=b"signature"):
            self.assertEqual(catalog.update_signed_index(release, "https://example.invalid/package.zip", Path("key"),
                             {"distribution_public_key": "key"}), "new")
        self.assertEqual(len(payloads), 1)
        expected = {"name": "spudhero", "email": "318930237+spudhero@users.noreply.github.com"}
        self.assertEqual(payloads[0]["author"], expected)
        self.assertEqual(payloads[0]["committer"], expected)

    def test_provider_publishers_check_account_before_any_github_write(self) -> None:
        # This test is also shipped to the Distribution repository, which has no
        # private publisher implementation. Exercise those publishers where present.
        if not (GUARD.parent / "publish_catalog_provider_release.py").exists():
            self.skipTest("private Provider publisher not present in this repository")
        import publish_catalog_provider_release as catalog
        import publish_configurable_provider_release as configurable
        import publish_diagnostic_provider_release as diagnostic
        release = {"provider_id": "netvplayer.catalog.python", "version": "1.1.6", "architectures": ["arm64"]}
        for publisher, checked in ((catalog, (release, Path("package.zip"), {})),
                                   (configurable, (release, Path("package.zip"))),
                                   (diagnostic, (release, Path("package.zip")))):
            with self.subTest(publisher=publisher.__name__), \
                    patch.object(publisher, "checked_release", return_value=checked), \
                    patch.object(publisher, "require_github_account", side_effect=identity.IdentityError("wrong account")), \
                    patch.object(publisher, "gh") as github:
                with self.assertRaisesRegex(identity.IdentityError, "wrong account"):
                    publisher.publish(Path("unused"), Path("unused-key"), True)
                github.assert_not_called()

    def test_github_publication_account_must_match_owner(self) -> None:
        with patch.object(identity.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "spudhero\n", "")):
            identity.require_github_account("spudhero")
        with patch.object(identity.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "chang-chaunce\n", "")):
            with self.assertRaises(identity.IdentityError):
                identity.require_github_account("spudhero")


if __name__ == "__main__":
    unittest.main()
