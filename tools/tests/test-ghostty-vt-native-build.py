#!/usr/bin/env python3
"""Provenance, pinned-source integrity and cache invalidation for the isolated VT build."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("vt_build", ROOT / "scripts/build-ghostty-vt-native.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class VTBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.destination = Path(self.temporary.name)
        self.inputs = {"lock": {"ghostty_revision": "pin", "zig_sha256": "toolchain"},
                       "recipe_sha256": "recipe", "patches": {}, "sdks": {"iphoneos": "sdk"}}
        self.paths = ["iphoneos/libghostty-vt.a", "iphonesimulator/libghostty-vt.a", "include/ghostty/vt.h"]
        for name in self.paths:
            path = self.destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        self.manifest = {"inputs": self.inputs,
                         "artifacts": {name: build.sha256(self.destination / name) for name in self.paths}}
        self.write_manifest()

    def write_manifest(self):
        (self.destination / "provenance.json").write_text(json.dumps(self.manifest))

    def testValidCacheRequiresMatchingInputsAndEveryArtifact(self):
        self.assertTrue(build.valid_cache(self.destination, self.inputs))
        for key in self.inputs:
            with self.subTest(key=key):
                changed = self.inputs | {key: "changed"}
                self.assertFalse(build.valid_cache(self.destination, changed))
                self.assertNotEqual(build.fingerprint(self.inputs), build.fingerprint(changed))
        (self.destination / self.paths[0]).write_bytes(b"damaged archive")
        self.assertFalse(build.valid_cache(self.destination, self.inputs))

    def testMissingOrOmittedSliceCannotCountAsAValidCache(self):
        (self.destination / self.paths[1]).unlink()
        self.assertFalse(build.valid_cache(self.destination, self.inputs))
        del self.manifest["artifacts"][self.paths[1]]
        self.write_manifest()
        self.assertFalse(build.valid_cache(self.destination, self.inputs))

    def testChangedHeaderInvalidatesCache(self):
        (self.destination / self.paths[2]).write_bytes(b"incompatible API")
        self.assertFalse(build.valid_cache(self.destination, self.inputs))

    def testChecksumFailureNeverPublishesDownloadedArchive(self):
        with patch.object(build, "WORK", self.destination), patch.object(build.urllib.request, "urlopen", return_value=io.BytesIO(b"wrong")):
            with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
                build.download("https://example.invalid/source", "0" * 64, "source.tar.gz")
        self.assertFalse((self.destination / "downloads/source.tar.gz").exists())

    def testFingerprintIsIndependentOfDictionaryOrdering(self):
        self.assertEqual(build.fingerprint(self.inputs), build.fingerprint(dict(reversed(list(self.inputs.items())))))

    def testExportedVersionIgnoresEnclosingReleaseTag(self):
        git("init", "-q", cwd=self.destination)
        git("-c", "user.name=test", "-c", "user.email=test@example.invalid",
            "commit", "--allow-empty", "-qm", "release", cwd=self.destination)
        git("tag", "v0.0.39", cwd=self.destination)
        source = self.destination / ".build/source"
        source.mkdir(parents=True)
        (source / "build.zig.zon").write_text('.{\n    .version = "1.3.2-dev",\n}\n')
        # Git sees the unrelated parent tag even though the export has no .git.
        self.assertEqual(git("describe", "--exact-match", "--tags", cwd=source), "v0.0.39")
        self.assertEqual(build.ghostty_version(source), "1.3.2-dev")
        (source / "VERSION").write_text("1.3.2-dev+33da684\n")
        self.assertEqual(build.ghostty_version(source), "1.3.2-dev+33da684")

    def testMissingExportedVersionFailsClosed(self):
        (self.destination / "build.zig.zon").write_text('.{ .name = .ghostty }\n')
        with self.assertRaisesRegex(RuntimeError, "Missing Ghostty version"):
            build.ghostty_version(self.destination)

    def testFreshCacheSupportsTemporaryZipFilesAndPreservesExistingCache(self):
        work = self.destination / "fresh-work"
        with patch.object(build, "WORK", work), patch.dict(build.os.environ, {"ZIG_GLOBAL_CACHE_DIR": "external-cache"}):
            environment = build.native_build_environment()
            cache = Path(environment["ZIG_GLOBAL_CACHE_DIR"])
            self.assertEqual(cache, work / "zig-cache")
            # Match the ZIP fetcher's exclusive creation inside cache/tmp.
            archive = cache / "tmp/dependency.zip"
            with archive.open("xb") as stream:
                stream.write(b"download")
            self.assertEqual(build.native_build_environment(), environment)
            self.assertEqual(archive.read_bytes(), b"download")
            self.assertEqual(build.os.environ["ZIG_GLOBAL_CACHE_DIR"], "external-cache")

    def make_patch(self):
        patches = self.destination / "patches"
        patches.mkdir()
        path = patches / "0001-api.patch"
        path.write_text("--- a/api.h\n+++ b/api.h\n@@ -1 +1 @@\n-original\n+extended\n")
        source = self.destination / "source"
        source.mkdir()
        (source / "api.h").write_text("original\n")
        return patches, path, source

    def testPatchContentAndRemovalInvalidatePublishedCache(self):
        patches, path, _ = self.make_patch()
        with patch.object(build, "PATCH_ROOT", patches):
            self.inputs["patches"] = build.patch_inputs()
            self.write_manifest()
            self.assertTrue(build.valid_cache(self.destination, self.inputs))
            path.write_text(path.read_text().replace("extended", "changed"))
            changed = self.inputs | {"patches": build.patch_inputs()}
            self.assertFalse(build.valid_cache(self.destination, changed))
            self.assertNotEqual(build.fingerprint(self.inputs), build.fingerprint(changed))
            (patches / "0002-extra.patch").write_text(path.read_text())
            self.assertFalse(build.valid_cache(self.destination, self.inputs | {"patches": build.patch_inputs()}))
            path.unlink()
            self.assertFalse(build.valid_cache(self.destination, self.inputs | {"patches": build.patch_inputs()}))

    def testEmptyOrMissingPatchDirectoryFailsInsteadOfBuildingUnpatchedUpstream(self):
        patches = self.destination / "patches"
        for exists in (False, True):
            with self.subTest(exists=exists):
                if exists:
                    patches.mkdir()
                    (patches / "README.md").write_text("not a patch\n")
                with patch.object(build, "PATCH_ROOT", patches):
                    with self.assertRaisesRegex(RuntimeError, "No VT patches found"):
                        build.patch_inputs()

    def testRepositoryPatchSetIsNotEmpty(self):
        self.assertTrue(build.patch_inputs())

    def testPatchAppliesOnceAndCannotSilentlyReverseOnRepeatedApplication(self):
        patches, _, source = self.make_patch()
        with patch.object(build, "PATCH_ROOT", patches):
            inputs = build.patch_inputs()
            build.apply_patches(source, inputs)
            self.assertEqual((source / "api.h").read_text(), "extended\n")
            with self.assertRaises(subprocess.CalledProcessError):
                build.apply_patches(source, inputs)
            self.assertEqual((source / "api.h").read_text(), "extended\n")

    def testChangedPatchDuringBuildFailsBeforeTouchingSource(self):
        patches, path, source = self.make_patch()
        with patch.object(build, "PATCH_ROOT", patches):
            inputs = build.patch_inputs()
            path.write_text(path.read_text().replace("extended", "changed"))
            with self.assertRaisesRegex(RuntimeError, "patch changed during build"):
                build.apply_patches(source, inputs)
            self.assertEqual((source / "api.h").read_text(), "original\n")

    def testPatchMismatchFailsInsteadOfPublishingAnUnpatchedAPI(self):
        patches, _, source = self.make_patch()
        (source / "api.h").write_text("different upstream\n")
        with patch.object(build, "PATCH_ROOT", patches):
            with self.assertRaises(subprocess.CalledProcessError):
                build.apply_patches(source, build.patch_inputs())
            self.assertEqual((source / "api.h").read_text(), "different upstream\n")


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class GhosttySubmoduleSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        identity = ("-c", "user.name=test", "-c", "user.email=test@example.invalid")
        self.source = base / "super/vendor/ghostty"
        self.source.mkdir(parents=True)
        git("init", "-q", cwd=self.source)
        (self.source / "build.zig").write_text("pinned\n")
        (self.source / ".gitignore").write_text("zig-out/\n")
        (self.source / "LICENSE").write_text("MIT\n")
        git("add", ".", cwd=self.source)
        git(*identity, "commit", "-qm", "pinned", cwd=self.source)
        self.revision = git("rev-parse", "HEAD", cwd=self.source)
        (self.source / "build.zig").write_text("newer\n")
        git(*identity, "commit", "-qam", "newer", cwd=self.source)
        self.newer = git("rev-parse", "HEAD", cwd=self.source)
        git("checkout", "-q", "--detach", self.revision, cwd=self.source)
        self.root = base / "super"
        git("init", "-q", cwd=self.root)
        self.set_gitlink(self.revision)

    def set_gitlink(self, revision):
        git("update-index", "--add", "--cacheinfo", f"160000,{revision},vendor/ghostty", cwd=self.root)

    def verify(self, revision=None):
        build.verify_ghostty_source(revision or self.revision, source=self.source, root=self.root)

    def testMatchingLockGitlinkAndPristineCheckoutIsAccepted(self):
        self.assertEqual(build.gitlink_revision(self.root), self.revision)
        self.verify()

    def testLockMustBeAFullCommitSha(self):
        with self.assertRaisesRegex(RuntimeError, "full commit SHA"):
            self.verify(self.revision[:12])

    def testGitlinkThatDisagreesWithLockFailsClosed(self):
        self.set_gitlink(self.newer)
        with self.assertRaisesRegex(RuntimeError, "gitlink"):
            self.verify()

    def testMissingGitlinkFailsClosed(self):
        git("update-index", "--force-remove", "vendor/ghostty", cwd=self.root)
        with self.assertRaisesRegex(RuntimeError, "not a git submodule"):
            self.verify()

    def testCheckoutAtAnotherCommitFailsClosed(self):
        git("checkout", "-q", "--detach", self.newer, cwd=self.source)
        with self.assertRaisesRegex(RuntimeError, "expected"):
            self.verify()

    def testUninitializedSubmoduleFailsClosed(self):
        with self.assertRaisesRegex(RuntimeError, "uninitialized"):
            build.verify_ghostty_source(self.revision, source=self.root / "missing", root=self.root)

    def testModifiedUntrackedOrIgnoredSubmoduleInputsFailClosed(self):
        for name, damage in (("modified", lambda: (self.source / "build.zig").write_text("local\n")),
                             ("untracked", lambda: (self.source / "extra.zig").write_text("x\n")),
                             ("ignored", lambda: ((self.source / "zig-out").mkdir(), (self.source / "zig-out/lib.a").write_text("x")))):
            with self.subTest(name=name):
                damage()
                with self.assertRaisesRegex(RuntimeError, "pristine"):
                    self.verify()
                git("checkout", "-q", "--", ".", cwd=self.source)
                git("clean", "-qfdx", cwd=self.source)
                self.verify()

    def testExportContainsExactlyThePinnedTreeWithoutGitMetadata(self):
        destination = self.root.parent / "export"
        destination.mkdir()
        build.export_ghostty_source(self.revision, destination, source=self.source)
        files = {str(p.relative_to(destination)): p.read_text() for p in destination.rglob("*") if p.is_file()}
        self.assertEqual(files, {"build.zig": "pinned\n", ".gitignore": "zig-out/\n", "LICENSE": "MIT\n"})

    def testRepositoryGitlinkMatchesNativeLock(self):
        lock = json.loads(build.LOCK_PATH.read_text())
        self.assertNotIn("ghostty_url", lock)
        self.assertNotIn("ghostty_sha256", lock)
        self.assertEqual(build.gitlink_revision(), lock["ghostty_revision"])
        gitmodules = (ROOT / ".gitmodules").read_text()
        self.assertIn('[submodule "vendor/ghostty"]', gitmodules)
        self.assertIn("url = https://github.com/ghostty-org/ghostty.git", gitmodules)
        self.assertIn("shallow = true", gitmodules.split('[submodule "vendor/ghostty"]')[1])


if __name__ == "__main__":
    unittest.main()
