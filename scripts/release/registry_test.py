"""Release-notes provenance for registry.py, against a real temporary git repository.

Run with: python3 -I -m unittest discover -s scripts/release -p '*_test.py'
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REGISTRY = Path(__file__).resolve().with_name("registry.py")
PUBLISHED = "## [1.4.0] - 2026-11-20\n\n- The section as published and tagged.\n"
MOVED = "## [1.4.0] - 2026-11-20\n\n- The section as edited after publication.\n"
OLDER = "## [1.3.0] - 2026-11-01\n\n- An older release.\n"


class NotesFromPublishedCommit(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.repo = Path(self.scratch.name)
        self.git("init", "-q", "-b", "main")
        self.published = self.commit("# Changelog\n\n" + PUBLISHED + "\n" + OLDER, "Release 1.4.0")
        self.head = self.commit("# Changelog\n\n" + MOVED + "\n" + OLDER, "Edit after release")

    def tearDown(self):
        self.scratch.cleanup()

    def git(self, *args):
        return subprocess.run(
            ["git", "-c", "user.name=release-test", "-c", "user.email=release-test@invalid",
             "-c", "commit.gpgsign=false", *args],
            cwd=self.repo, capture_output=True, text=True, check=True,
        ).stdout.strip()

    def commit(self, changelog, message):
        (self.repo / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
        self.git("add", "CHANGELOG.md")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def notes(self, version, commit):
        output = self.repo / "notes.md"
        result = subprocess.run(
            [sys.executable, "-I", str(REGISTRY), "notes", version, commit, str(output)],
            cwd=self.repo, capture_output=True, text=True, check=False,
        )
        return result, output

    def test_reads_the_published_commit_not_the_checkout(self):
        self.assertNotEqual(self.published, self.head)
        result, output = self.notes("1.4.0", self.published)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(encoding="utf-8"), PUBLISHED)

    def test_reads_the_head_when_head_is_published(self):
        result, output = self.notes("1.4.0", self.head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(encoding="utf-8"), MOVED)

    def test_refuses_a_version_the_published_commit_lacks(self):
        result, output = self.notes("1.5.0", self.published)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"CHANGELOG.md at {self.published} has no section for 1.5.0", result.stderr)
        self.assertFalse(output.exists())

    def test_refuses_a_commit_that_is_not_in_the_repository(self):
        result, output = self.notes("1.4.0", "0" * 40)
        self.assertEqual(result.returncode, 1)
        self.assertIn("has no readable CHANGELOG.md", result.stderr)
        self.assertFalse(output.exists())

    def test_refuses_an_abbreviated_commit(self):
        result, output = self.notes("1.4.0", self.published[:12])
        self.assertEqual(result.returncode, 1)
        self.assertIn("notes needs the full published commit", result.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
