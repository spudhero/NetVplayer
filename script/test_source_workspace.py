from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from source_workspace import source_entries, source_file, validate_links


class SourceWorkspaceTests(unittest.TestCase):
    def fixture(self, root: Path) -> None:
        subprocess.run(["git", "init", str(root)], check=True, capture_output=True)
        manifest = {
            "schema_version": 1,
            "projects": {key: {"directory": directory} for key, directory in (
                ("app", "NetVplayer"), ("providers", "NetVplayer-Providers"),
                ("distribution", "NetVplayer-Provider-Distribution"))},
            "compatibility_links": {"script/tool.py": "NetVplayer/script/tool.py"},
            "shared_links": {"NetVplayer-Providers/script/tool.py": "NetVplayer/script/tool.py"},
            "internal_root_files": [".netvplayer-workspace.json"],
        }
        (root / ".netvplayer-workspace.json").write_text(json.dumps(manifest))
        for relative, text in {
            "NetVplayer/script/tool.py": "public tool",
            "NetVplayer/NetVplayer/Sources/App.swift": "app",
            "NetVplayer-Providers/migration-reference/NetVplayer/Sources/SpiderEngine/OldNativeProvider.swift": "legacy",
            "NetVplayer-Providers/private-providers/demo/provider.py": "private",
            "NetVplayer-Provider-Distribution/stable/index.json": "distribution",
        }.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        for section in ("compatibility_links", "shared_links"):
            for relative, target in manifest[section].items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to(os.path.relpath(root / target, path.parent))
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)

    def test_component_paths_preserve_publication_contract_without_alias_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            entries = source_entries(root)
            self.assertEqual(set(entries), {"script/tool.py", "NetVplayer/Sources/App.swift",
                "NetVplayer/Sources/SpiderEngine/OldNativeProvider.swift", "private-providers/demo/provider.py"})
            self.assertEqual(source_file(root, "script/tool.py").read_text(), "public tool")
            self.assertEqual(validate_links(root)["links_checked"], 2)

    def test_duplicate_owner_cannot_shadow_an_application_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            path = root / "NetVplayer-Providers/script/tool.py"
            path.unlink()
            path.write_text("shadow")
            manifest = json.loads((root / ".netvplayer-workspace.json").read_text())
            manifest["shared_links"] = {}
            (root / ".netvplayer-workspace.json").write_text(json.dumps(manifest))
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            with self.assertRaisesRegex(ValueError, "duplicate publication input"):
                source_entries(root)

    def test_link_cannot_escape_the_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            path = root / "script/tool.py"
            path.unlink()
            path.symlink_to("/etc/hosts")
            with self.assertRaisesRegex(ValueError, "unsafe workspace link"):
                validate_links(root)

    def test_missing_shared_input_fails_instead_of_omitting_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / "NetVplayer/script/tool.py").unlink()
            with self.assertRaises(FileNotFoundError):
                validate_links(root)

    def test_standalone_repository_keeps_existing_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", str(root)], check=True, capture_output=True)
            (root / "provider.py").write_text("standalone")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            self.assertEqual(source_entries(root), {"provider.py": "provider.py"})

    def test_private_override_is_scoped_to_provider_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            target = root / "NetVplayer-Providers/script/tool.py"
            target.unlink()
            target.write_text("private tool")
            manifest_path = root / ".netvplayer-workspace.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["shared_links"] = {}
            manifest["private_overrides"] = {"script/tool.py": "NetVplayer-Providers/script/tool.py"}
            manifest_path.write_text(json.dumps(manifest))
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            self.assertEqual(source_file(root, "script/tool.py").read_text(), "public tool")
            self.assertEqual(source_file(root, "script/tool.py", component="providers").read_text(), "private tool")
            validate_links(root)
            target.unlink()
            with self.assertRaisesRegex(ValueError, "invalid private override"):
                validate_links(root)

    def test_workflow_template_keeps_its_export_destination_after_relocation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            physical = "NetVplayer-Providers/.github/workflows/provider-private-source.yml"
            logical = "script/templates/provider-private-source.yml"
            path = root / physical
            path.parent.mkdir(parents=True)
            path.write_text("name: providers")
            manifest_path = root / ".netvplayer-workspace.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["publication_inputs"] = {physical: logical}
            manifest_path.write_text(json.dumps(manifest))
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            self.assertEqual(source_entries(root)[logical], physical)
            self.assertEqual(source_file(root, logical).read_text(), "name: providers")
