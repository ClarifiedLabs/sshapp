#!/usr/bin/env python3
"""Exercise CI toolchain selection without switching the machine's Xcode."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[2]


class XcodeResolutionTests(unittest.TestCase):
    def resolve(self, version, major="27"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            developer = root / "Selected Xcode.app" / "Contents" / "Developer"
            developer.mkdir(parents=True)
            binary = root / "xcodebuild"
            binary.write_text('#!/bin/sh\nprintf "Xcode %s\\nBuild version test\\n" "$TEST_XCODE_VERSION"\n')
            binary.chmod(0o755)
            return subprocess.run(
                [str(REPO_ROOT / "scripts/resolve-xcode.sh"), major],
                env={**os.environ, "PATH": f"{root}:/usr/bin:/bin",
                     "DEVELOPER_DIR": str(developer), "TEST_XCODE_VERSION": version},
                text=True, capture_output=True,
            ), str(developer)

    def test_selects_matching_major_and_preserves_spaces(self):
        for version in ("27", "27.0", "27.1"):
            with self.subTest(version=version):
                result, developer = self.resolve(version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), developer)

    def test_rejects_older_and_unvalidated_future_major_versions(self):
        for version in ("26.5", "28.0", "270.0"):
            with self.subTest(version=version):
                result, _ = self.resolve(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Xcode 27 is required", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_both_workflows_select_xcode_before_building(self):
        for name in ("test-ios.yml", "deploy-ios.yml"):
            with self.subTest(workflow=name):
                workflow = (REPO_ROOT / ".github/workflows" / name).read_text()
                self.assertIn("runs-on: xcode-27", workflow)
                selection = workflow.index("./scripts/resolve-xcode.sh 27")
                self.assertLess(selection, workflow.index("make setup"))
                self.assertIn('echo "DEVELOPER_DIR=$developer_dir" >> "$GITHUB_ENV"', workflow)
                self.assertIn("native-frameworks-${{ runner.os }}-xcode27-", workflow)
                self.assertNotIn("Require Xcode 26", workflow)


if __name__ == "__main__":
    unittest.main()
