from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_public_links import missing_markdown_targets


class PublicDocumentLinkTests(unittest.TestCase):
    def test_checks_tracked_targets_not_an_internal_file_that_happens_to_exist(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "internal.md").write_text("internal")
            (repo / "docs").mkdir()
            (repo / "docs/Public Guide.md").write_text("# Intro\n")
            (repo / "README.md").write_text("[private](internal.md)\n[good](docs/Public%20Guide.md#intro)\n")
            result = missing_markdown_targets(repo, ["README.md", "docs/Public Guide.md"])
            self.assertEqual(result, [{"path": "README.md", "line": 1, "target": "internal.md"}])

    def test_handles_images_references_and_code_without_network_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "README.md").write_text(
                "![image](missing.png)\n[guide]: <missing guide.md>\n"
                "[remote](https://example.test/a) [anchor](#local)\n"
                "`[example](fake.md)`\n```md\n[example](other.md)\n```\n")
            self.assertEqual(missing_markdown_targets(repo, ["README.md"]), [
                {"path": "README.md", "line": 1, "target": "missing.png"},
                {"path": "README.md", "line": 2, "target": "missing guide.md"},
            ])


if __name__ == "__main__":
    unittest.main()
