#!/usr/bin/env python3
"""Tests for the SSH App release helper."""

from __future__ import annotations

import importlib.util
import io
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
RELEASE_SCRIPT = REPO_ROOT / "tools" / "release.py"

spec = importlib.util.spec_from_file_location("release_tool", RELEASE_SCRIPT)
release_tool = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = release_tool
spec.loader.exec_module(release_tool)


def _isolated_git_env() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def git(root: pathlib.Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=_isolated_git_env(),
    )


def git_output(root: pathlib.Path, *args: str) -> str:
    return git(root, *args).stdout.strip()


def write_project(root: pathlib.Path, version: str = "0.0.1") -> None:
    project_file = root / release_tool.PROJECT_FILE
    project_file.parent.mkdir(parents=True, exist_ok=True)
    project_file.write_text(
        f"""
/* Begin XCBuildConfiguration section */
		SSHAPPDEBUG /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				MARKETING_VERSION = {version};
			}};
			name = Debug;
		}};
		SSHAPPREL /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				MARKETING_VERSION = {version};
			}};
			name = Release;
		}};
		SSHAPPTESTS /* Tests */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				MARKETING_VERSION = 1.0;
			}};
			name = Debug;
		}};
/* End XCBuildConfiguration section */
""".lstrip()
    )


def create_release_quiet(*args, **kwargs) -> str:
    output = io.StringIO()
    original_git = release_tool.git

    def quiet_git(root: pathlib.Path, *git_args: str, capture_output: bool = False):
        return original_git(root, *git_args, capture_output=True)

    release_tool.git = quiet_git
    try:
        with redirect_stdout(output):
            release_tool.create_release(*args, **kwargs)
    finally:
        release_tool.git = original_git
    return output.getvalue()


class ReleaseTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._original_release_run = release_tool.run

        def isolated_run(
            repo_root: pathlib.Path,
            *args: str,
            capture_output: bool = False,
        ) -> subprocess.CompletedProcess[str]:
            return subprocess.run(
                list(args),
                cwd=repo_root,
                check=True,
                text=True,
                stdout=subprocess.PIPE if capture_output else None,
                stderr=subprocess.PIPE if capture_output else None,
                env=_isolated_git_env(),
            )

        release_tool.run = isolated_run

    @classmethod
    def tearDownClass(cls) -> None:
        release_tool.run = cls._original_release_run

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.remote_tempdirs: list[tempfile.TemporaryDirectory[str]] = []
        self.root = pathlib.Path(self.tempdir.name)
        git(self.root, "init")
        git(self.root, "checkout", "-b", "main")
        git(self.root, "config", "user.name", "Release Test")
        git(self.root, "config", "user.email", "release-test@example.com")
        (self.root / "README.md").write_text("test repo\n")
        write_project(self.root)
        git(self.root, "add", ".")
        git(self.root, "commit", "-m", "init")

    def tearDown(self) -> None:
        for remote_tempdir in self.remote_tempdirs:
            remote_tempdir.cleanup()
        self.tempdir.cleanup()

    def add_origin(self) -> pathlib.Path:
        remote_tempdir = tempfile.TemporaryDirectory()
        self.remote_tempdirs.append(remote_tempdir)
        remote = pathlib.Path(remote_tempdir.name) / "remote.git"
        git(remote.parent, "init", "--bare", remote.name)
        git(self.root, "remote", "add", "origin", str(remote))
        git(self.root, "push", "-u", "origin", "main")
        return remote

    def test_patch_from_no_tags_resolves_initial_0_0_1(self) -> None:
        self.assertEqual(release_tool.resolve_version(self.root, "patch"), "0.0.1")

    def test_resolves_patch_from_plain_tag_and_ignores_component_tags(self) -> None:
        git(self.root, "tag", "-a", "v0.0.1", "-m", "SSH App v0.0.1")
        git(self.root, "tag", "-a", "ios/v9.9.9", "-m", "old component tag")

        self.assertEqual(release_tool.resolve_version(self.root, "patch"), "0.0.2")

    def test_update_marketing_version_leaves_two_part_test_values(self) -> None:
        count = release_tool.update_marketing_version(self.root, "0.0.2")

        contents = (self.root / release_tool.PROJECT_FILE).read_text()
        self.assertEqual(count, 2)
        self.assertEqual(contents.count("MARKETING_VERSION = 0.0.2;"), 2)
        self.assertIn("MARKETING_VERSION = 1.0;", contents)
        self.assertNotIn("MARKETING_VERSION = 0.0.1;", contents)

    def test_release_commits_project_update_and_creates_plain_tag(self) -> None:
        git(self.root, "tag", "-a", "v0.0.1", "-m", "SSH App v0.0.1")

        create_release_quiet(
            root=self.root,
            version_arg="patch",
            dry_run=False,
            push=False,
        )

        self.assertEqual(git_output(self.root, "tag", "-l", "v0.0.2"), "v0.0.2")
        self.assertIn("MARKETING_VERSION = 0.0.2;", (self.root / release_tool.PROJECT_FILE).read_text())
        self.assertEqual(git_output(self.root, "log", "-1", "--pretty=%s"), "chore(release): bump version to v0.0.2")

    def test_initial_release_does_not_commit_when_project_already_matches(self) -> None:
        create_release_quiet(
            root=self.root,
            version_arg="patch",
            dry_run=False,
            push=False,
        )

        self.assertEqual(git_output(self.root, "tag", "-l", "v0.0.1"), "v0.0.1")
        self.assertEqual(git_output(self.root, "rev-list", "--count", "HEAD"), "1")

    def test_dry_run_reports_no_commit_when_project_already_matches(self) -> None:
        output = create_release_quiet(
            root=self.root,
            version_arg="patch",
            dry_run=True,
            push=False,
        )

        self.assertIn("already matches v0.0.1", output)
        self.assertNotIn("Would commit", output)

    def test_pushed_release_requires_head_on_origin_main(self) -> None:
        self.add_origin()
        (self.root / "README.md").write_text("local release candidate\n")
        git(self.root, "add", "README.md")
        git(self.root, "commit", "-m", "chore: local release candidate")

        with self.assertRaisesRegex(release_tool.ReleaseError, "origin/main"):
            create_release_quiet(
                root=self.root,
                version_arg="patch",
                dry_run=False,
                push=True,
            )

        self.assertEqual(git_output(self.root, "tag", "-l", "v0.0.1"), "")

    def test_dry_run_does_not_require_clean_worktree(self) -> None:
        (self.root / "dirty.txt").write_text("dirty\n")

        create_release_quiet(
            root=self.root,
            version_arg="0.0.2",
            dry_run=True,
            push=False,
        )

        self.assertEqual(git_output(self.root, "tag", "-l", "v0.0.2"), "")
        self.assertIn("MARKETING_VERSION = 0.0.1;", (self.root / release_tool.PROJECT_FILE).read_text())

    def test_rejects_versions_with_v_prefix(self) -> None:
        with self.assertRaisesRegex(release_tool.ReleaseError, "must not start with 'v'"):
            release_tool.resolve_version(self.root, "v0.0.2")

    def test_list_versions_prints_plain_tag_without_component_label(self) -> None:
        git(self.root, "tag", "-a", "v0.0.1", "-m", "SSH App v0.0.1")
        output = io.StringIO()

        with redirect_stdout(output):
            release_tool.list_versions(self.root)

        self.assertIn("  v0.0.1", output.getvalue())
        self.assertNotIn("ios/v", output.getvalue())
        self.assertNotIn("ios      ", output.getvalue())


if __name__ == "__main__":
    unittest.main()
