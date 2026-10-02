#!/usr/bin/env python3
"""Run the real native packager with small compiler and dependency fixtures."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIBRARIES = ("libssh2", "libcrypto", "libssl")

# Compilation is replaced; hashing, cache decisions and publication use the
# production shell script. Every packaging invocation is counted independently.
TOOL = '''#!/usr/bin/env python3
import json
from pathlib import Path
import plistlib
import shutil
import sys
root = Path(__file__).resolve().parents[1]
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
if tool == "git":
    if "rev-parse" in args:
        name = Path(args[args.index("-C") + 1]).name
        print(json.loads((root / "pins.json").read_text())[name])
elif tool == "xcrun":
    sdk = root / "sdks" / args[args.index("--sdk") + 1]
    if "--show-sdk-path" in args:
        print(sdk)
    elif "--show-sdk-version" in args:
        print(json.loads((sdk / "SDKSettings.json").read_text())["Version"])
    else:
        raise SystemExit("unexpected xcrun arguments")
elif tool == "xcodebuild":
    if args == ["-version"]:
        print((root / "xcode-version").read_text().strip())
    else:
        destination = Path(args[args.index("-output") + 1])
        destination.mkdir(parents=True)
        slices = []
        for index, arg in enumerate(args):
            if arg != "-library":
                continue
            source = Path(args[index + 1])
            simulator = "iphonesimulator" in str(source)
            label = "ios-arm64-simulator" if simulator else "ios-arm64"
            (destination / label).mkdir()
            shutil.copy2(source, destination / label / source.name)
            entry = dict(LibraryIdentifier=label, LibraryPath=source.name,
                         SupportedArchitectures=["arm64"], SupportedPlatform="ios")
            if simulator:
                entry["SupportedPlatformVariant"] = "simulator"
            slices.append(entry)
        (destination / "Info.plist").write_bytes(plistlib.dumps(dict(AvailableLibraries=slices)))
        with (root / "packages-built").open("a") as stream:
            stream.write(destination.name + "\\n")
elif tool == "rsync":
    shutil.copytree(args[-2], args[-1], dirs_exist_ok=True)
elif tool == "sysctl":
    print(2)
elif tool == "make":
    if "install_sw" in args:
        destination = Path(Path(".fixture-prefix").read_text()) / "lib"
        destination.mkdir(parents=True)
        for name in ("libcrypto", "libssl"):
            (destination / (name + ".a")).write_bytes((name + str(destination)).encode())
elif tool == "cmake":
    if "-B" in args:
        directory = Path(args[args.index("-B") + 1])
        prefix = next(arg.split("=", 1)[1] for arg in args if arg.startswith("-DCMAKE_INSTALL_PREFIX="))
        (directory / ".fixture-prefix").write_text(prefix)
    elif "--install" in args:
        directory = Path(args[args.index("--install") + 1])
        destination = Path((directory / ".fixture-prefix").read_text()) / "lib"
        destination.mkdir(parents=True)
        (destination / "libssh2.a").write_bytes(str(destination).encode())
else:
    raise SystemExit("unexpected fixture tool " + tool)
'''


class NativeCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sshapp-native-cache-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / "build-libssh2.sh"
        shutil.copy2(ROOT / "scripts/build-libssh2.sh", self.script)
        source = self.script.read_text()
        pins = {name: re.search(f'EXPECTED_{variable}_COMMIT="([0-9a-f]+)"', source)[1]
                for name, variable in (("openssl", "OPENSSL"), ("libssh2", "LIBSSH2"))}
        (self.root / "pins.json").write_text(json.dumps(pins))
        for name in pins:
            (self.root / "vendor" / name).mkdir(parents=True)
        configure = self.root / "vendor/openssl/Configure"
        configure.write_text('''#!/usr/bin/env bash
for argument in "$@"; do
    case "$argument" in --prefix=*) printf '%s' "${argument#--prefix=}" > .fixture-prefix ;; esac
done
''')
        configure.chmod(0o755)
        (self.root / "vendor/libssh2/CMakeLists.txt").write_text("original\n")
        patches = scripts / "libssh2-patches"
        patches.mkdir()
        (patches / "0001-test.patch").write_text(
            "--- a/CMakeLists.txt\n+++ b/CMakeLists.txt\n@@ -1 +1 @@\n-original\n+patched\n")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name in ("git", "xcrun", "xcodebuild", "cmake", "make", "rsync", "sysctl"):
            path = bin_dir / name
            path.write_text(TOOL)
            path.chmod(0o755)
        (self.root / "xcode-version").write_text("Xcode 27.0\nBuild version 27A1\n")
        for sdk in ("iphoneos", "iphonesimulator"):
            path = self.root / "sdks" / sdk
            path.mkdir(parents=True)
            (path / "SDKSettings.json").write_text('{"Version": "27.0"}\n')
        self.environment = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
        self.run_build()

    def run_build(self):
        result = subprocess.run(["bash", str(self.script)], env=self.environment,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def count(self):
        return len((self.root / "packages-built").read_text().splitlines())

    def framework(self, name="libssh2"):
        return self.root / "Frameworks" / (name + ".xcframework")

    def assert_rebuilt(self):
        before = self.count()
        self.run_build()
        self.assertEqual(self.count(), before + 3)
        self.run_build()
        self.assertEqual(self.count(), before + 3, "repaired cache must be reusable")

    def test_matching_cache_skips_and_manifest_binds_all_files(self):
        self.assertEqual(self.count(), 3)
        self.assertIn("skipping build", self.run_build().stdout)
        self.assertEqual(self.count(), 3)
        for name in LIBRARIES:
            framework = self.framework(name)
            manifest = json.loads((framework / "SSHAppNative.provenance.json").read_text())
            expected = {"Info.plist", f"ios-arm64/{name}.a", f"ios-arm64-simulator/{name}.a"}
            self.assertEqual(set(manifest["packaged_files"]), expected)
            for path, digest in manifest["packaged_files"].items():
                self.assertEqual(hashlib.sha256((framework / path).read_bytes()).hexdigest(), digest)
            self.assertEqual(manifest["input_sha256"], (framework / "SSHAppNative.input-sha256").read_text().strip())

    def test_xcode_and_either_sdk_change_rebuild(self):
        (self.root / "xcode-version").write_text("Xcode 27.1\nBuild version 27B1\n")
        self.assert_rebuilt()
        for sdk in ("iphoneos", "iphonesimulator"):
            with self.subTest(sdk=sdk):
                # Same advertised version, different SDK contents.
                path = self.root / "sdks" / sdk / "SDKSettings.json"
                path.write_text('{"Version": "27.0", "changed": true}\n')
                self.assert_rebuilt()

    def test_unavailable_toolchain_inputs_fail_before_reusing_or_building(self):
        for path in [self.root / "xcode-version", self.root / "sdks/iphoneos/SDKSettings.json"]:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.unlink()
                before = self.count()
                result = subprocess.run(["bash", str(self.script)], env=self.environment,
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.count(), before)
                path.write_bytes(original)

    def test_corrupt_missing_or_extra_packaged_files_rebuild(self):
        for name in LIBRARIES:
            with self.subTest(library=name):
                binary = self.framework(name) / "ios-arm64" / (name + ".a")
                binary.write_bytes(b"corrupt")
                self.assert_rebuilt()
                binary.unlink()
                self.assert_rebuilt()
        (self.framework() / "Info.plist").write_bytes(b"invalid plist")
        self.assert_rebuilt()
        (self.framework() / "unexpected.a").write_bytes(b"extra")
        self.assert_rebuilt()

    def test_required_slice_cannot_be_omitted_from_manifest(self):
        framework = self.framework()
        path = "ios-arm64-simulator/libssh2.a"
        (framework / path).unlink()
        provenance = framework / "SSHAppNative.provenance.json"
        manifest = json.loads(provenance.read_text())
        del manifest["packaged_files"][path]
        provenance.write_text(json.dumps(manifest))
        self.assert_rebuilt()

    def test_missing_malformed_or_stale_provenance_rebuilds(self):
        path = self.framework() / "SSHAppNative.provenance.json"
        path.unlink()
        self.assert_rebuilt()
        for content in ("broken", "{}", "null"):
            with self.subTest(content=content):
                path.write_text(content)
                self.assert_rebuilt()
        manifest = json.loads(path.read_text())
        manifest["input_sha256"] = "unrelated inputs"
        path.write_text(json.dumps(manifest))
        self.assert_rebuilt()


if __name__ == "__main__":
    unittest.main()
