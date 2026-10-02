#!/usr/bin/env python3
"""Regression checks for the native framework build recipe."""

from __future__ import annotations

from pathlib import Path
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile

from _checks import REPO_ROOT, read, require, require_absent, require_contains


def test_ghostty_vt_packaging() -> None:
    script = read(REPO_ROOT / "scripts/build-ghostty-vt.sh")
    context = "build-ghostty-vt.sh"

    for expected in (
        'LOCK_PATH="$PROJECT_DIR/vendor/libghostty-vt/native-lock.json"',
        'PATCH_DIR="$PROJECT_DIR/vendor/libghostty-vt/patches"',
        'python3 "$SCRIPT_DIR/build-ghostty-vt-native.py"',
        'libghostty-vt.a',
        'libghosttyvt.framework/libghosttyvt',
        'Modules/module.modulemap',
        'framework module libghosttyvt {',
        'umbrella header "ghostty/vt.h"',
        '-framework "$ARTIFACTS_DIR/iphoneos-arm64/libghosttyvt.framework"',
        '-framework "$ARTIFACTS_DIR/iphonesimulator-arm64/libghosttyvt.framework"',
        'Rewrite upstream <ghostty/',
        'relpath',
        'Sources/CGhosttyVT/include/ghostty',
        '-output "$XCFRAMEWORK_PATH"',
        '"SSHAppGhostty.provenance.json"',
        'SSHAppGhostty.input-sha256',
        'matches input $INPUT_HASH; skipping build',
        'verify_ghostty_gitlink',
        'ls-files --stage -- vendor/ghostty',
    ):
        require_contains(script, expected, context)

    for forbidden in (
        "x86_64",
        "maccatalyst",
        "macosx",
    ):
        require_absent(script, forbidden, context)

    makefile = read(REPO_ROOT / "Makefile")
    require_contains(
        makefile,
        "ghostty-vt: submodules ## Package libghostty-vt slices as GhosttyVT.xcframework when inputs changed",
        "Makefile ghostty-vt target",
    )
    require_contains(
        makefile,
        "clean-ghostty-vt: ## Remove GhosttyVT xcframework",
        "Makefile clean-ghostty-vt target",
    )
    require_contains(
        makefile,
        "git submodule update --init --depth 1 -- vendor/ghostty",
        "Makefile fetches only the pinned Ghostty commit",
    )


def test_ghostty_vt_cache_behavior() -> None:
    """Run the real packager/preflight with tiny native and xcodebuild fixtures."""
    with tempfile.TemporaryDirectory(prefix="ghostty-vt-package-test-") as directory:
        root = Path(directory)
        scripts = root / "scripts"
        scripts.mkdir()
        packager = scripts / "build-ghostty-vt.sh"
        shutil.copy2(REPO_ROOT / "scripts/build-ghostty-vt.sh", packager)
        patches = root / "vendor/libghostty-vt/patches"
        patches.mkdir(parents=True)
        patch = patches / "0001-api.patch"
        patch.write_text("original patch\n")
        lock = patches.parent / "native-lock.json"
        first, second, other = ("1" * 40, "2" * 40, "3" * 40)
        lock.write_text(json.dumps({"ghostty_revision": first, "deployment_target": "17.2"}) + "\n")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)

        def set_gitlink(revision: str) -> None:
            subprocess.run(["git", "update-index", "--add", "--cacheinfo", f"160000,{revision},vendor/ghostty"],
                           cwd=root, check=True)

        set_gitlink(first)
        recipe = scripts / "build-ghostty-vt-native.py"
        recipe.write_text('''from pathlib import Path
import json
import shutil
root = Path(__file__).resolve().parents[1]
native = root / ".build/ghostty-vt/native"
if native.exists():
    shutil.rmtree(native)
revision = json.loads((root / "vendor/libghostty-vt/native-lock.json").read_text())["ghostty_revision"]
for sdk in ("iphoneos", "iphonesimulator"):
    path = native / sdk / "libghostty-vt.a"
    path.parent.mkdir(parents=True)
    path.write_text(sdk + revision)
headers = native / "include/ghostty"
(headers / "detail").mkdir(parents=True)
(headers / "vt.h").write_text('#include <ghostty/detail/api.h>\\n')
(headers / "detail/api.h").write_text("// " + revision + "\\n")
(headers / "vt.h.orig").write_text("must not be packaged")
with (root / "native-builds").open("a") as stream:
    stream.write("build\\n")
''')
        bin_dir = root / "bin"
        bin_dir.mkdir()
        xcodebuild = bin_dir / "xcodebuild"
        xcodebuild.write_text('''#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys
args = sys.argv[1:]
if args == ["-version"]:
    print((Path(__file__).parent / "xcode-version").read_text().strip())
    sys.exit(0)
output = Path(args[args.index("-output") + 1])
output.mkdir(parents=True)
for index, argument in enumerate(args):
    if argument == "-framework":
        source = Path(args[index + 1])
        label = "ios-arm64-simulator" if "iphonesimulator" in str(source) else "ios-arm64"
        shutil.copytree(source, output / label / source.name)
(output / "Info.plist").write_text("fixture xcframework")
''')
        xcodebuild.chmod(0o755)
        (bin_dir / "xcode-version").write_text("Xcode 27.0\nBuild version 27A1\n")
        sdk_root = root / "sdk"
        sdk_root.mkdir()
        (sdk_root / "SDKSettings.json").write_text('{"Version": "27.0"}\n')
        xcrun = bin_dir / "xcrun"
        xcrun.write_text(f'''#!/usr/bin/env bash
case "$3" in
    --show-sdk-path) echo "{sdk_root}" ;;
    --show-sdk-version) echo 27.0 ;;
    *) exit 1 ;;
esac
''')
        xcrun.chmod(0o755)
        environment = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"], PROJECT_DIR=str(root))
        framework = root / "Frameworks/GhosttyVT.xcframework"
        headers = root / "Packages/SSHAppGhostty/Sources/CGhosttyVT/include/ghostty"
        native = root / ".build/ghostty-vt/native"

        def run(*arguments: str, success: bool = True) -> subprocess.CompletedProcess:
            result = subprocess.run(["bash", str(packager), *arguments], env=environment,
                                    capture_output=True, text=True)
            require((result.returncode == 0) == success, result.stdout + result.stderr)
            return result

        def builds() -> int:
            return len((root / "native-builds").read_text().splitlines())

        def check_bundle_metadata() -> None:
            bundles = sorted(framework.glob("*/libghosttyvt.framework"))
            require(len(bundles) == 2, "both VT slices must carry bundle metadata")
            deployment_target = json.loads(lock.read_text())["deployment_target"]
            for bundle in bundles:
                plist = plistlib.loads((bundle / "Info.plist").read_bytes())
                version = plist.get("CFBundleShortVersionString", "")
                require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is not None,
                        f"{bundle.name} needs an App Store compatible release version")
                require(plist.get("MinimumOSVersion") == deployment_target,
                        f"{bundle.name} minimum OS must match the compiled native deployment target")

        run()
        require(builds() == 1, "cold cache must build native slices")
        check_bundle_metadata()
        expected = {str(p.relative_to(headers)): p.read_bytes() for p in headers.rglob("*") if p.is_file()}
        require(expected["vt.h"] == b'#include "detail/api.h"\n', "C headers use packaged relative includes")
        require("vt.h.orig" not in expected, "patch backups must not be staged")
        header_mtime = (headers / "vt.h").stat().st_mtime_ns
        run()
        run("--check")
        require(builds() == 1, "matching caches must not rebuild")
        require((headers / "vt.h").stat().st_mtime_ns == header_mtime, "valid headers must not be rewritten")

        # An Xcode or SDK update must rebuild even though no tracked file changed.
        (bin_dir / "xcode-version").write_text("Xcode 27.1\nBuild version 27B1\n")
        run("--check", success=False)
        run()
        require(builds() == 2, "a toolchain update must rebuild native slices")
        (sdk_root / "SDKSettings.json").write_text('{"Version": "27.1"}\n')
        run("--check", success=False)
        run()
        require(builds() == 3, "an SDK update must rebuild native slices")
        run("--check")

        # No native build cache is needed to restore generated C headers.
        shutil.rmtree(native)
        shutil.rmtree(headers)
        result = run("--check", success=False)
        require_contains(result.stderr, "Run make setup", "read-only Xcode preflight guidance")
        require(not headers.exists(), "preflight cannot write headers after SwiftPM compilation starts")
        run()
        require(builds() == 3, "missing C headers must restore without native compilation")
        require({str(p.relative_to(headers)): p.read_bytes() for p in headers.rglob("*") if p.is_file()} == expected,
                "restored header tree must match packaged binary")

        # A mutable native build cache must never supply headers for a packaged binary.
        (native / "include/ghostty").mkdir(parents=True)
        (native / "include/ghostty/vt.h").write_text("incompatible cached API")
        (headers / "vt.h").write_text("stale C header")
        (headers / "unexpected.h").write_text("stale extra header")
        (headers / "detail/api.h").unlink()
        run("--check", success=False)
        require((headers / "vt.h").read_text() == "stale C header", "preflight cannot repair stale headers")
        require((headers / "unexpected.h").exists(), "preflight cannot remove extra headers")
        require(not (headers / "detail/api.h").exists(), "preflight cannot restore missing headers")
        run()
        require(builds() == 3, "stale C header tree must be repaired from packaged cache")
        require({str(p.relative_to(headers)): p.read_bytes() for p in headers.rglob("*") if p.is_file()} == expected,
                "repair must replace stale, missing and extra generated headers")

        # Damage to either packaged slice/header invalidates the binary-bound cache.
        for pattern in ("*/libghosttyvt.framework/libghosttyvt", "*/libghosttyvt.framework/Headers/ghostty/vt.h"):
            before = builds()
            next(framework.glob(pattern)).write_text("damaged")
            run("--check", success=False)
            run()
            require(builds() == before + 1, "corrupt packaged files must rebuild, not restage")
        next(framework.glob("*/libghosttyvt.framework/libghosttyvt")).unlink()
        run()
        require(builds() == 6, "missing packaged slice must rebuild")

        # Exercise the actual pbxproj phase against an existing but stale bundle.
        project = read(REPO_ROOT / "SSHApp.xcodeproj/project.pbxproj")
        phase = next(json.loads(match) for match in re.findall(r'shellScript = ("(?:\\.|[^"\\])*");', project)
                     if "build-ghostty-vt.sh" in match)
        lock.write_text(json.dumps({"ghostty_revision": second, "deployment_target": "18.0"}) + "\n")
        set_gitlink(second)
        result = subprocess.run(["bash", "-c", phase], env=environment, capture_output=True, text=True)
        require(result.returncode != 0, "existing framework directory must not bypass input invalidation")
        require_contains(result.stderr, "Run make setup", "project phase setup guidance")
        require(builds() == 6, "project preflight must not rebuild behind SwiftPM")
        run()
        require(builds() == 7, "changed lock must rebuild")
        check_bundle_metadata()
        require((headers / "detail/api.h").read_text() == f"// {second}\n", "new headers must match new binary")

        # The Ghostty gitlink and lock revision must agree, even on a cache hit.
        set_gitlink(other)
        for arguments in (("--check",), ()):
            result = run(*arguments, success=False)
            require_contains(result.stderr, "vendor/ghostty gitlink", "gitlink/lock mismatch guidance")
        subprocess.run(["git", "update-index", "--force-remove", "vendor/ghostty"], cwd=root, check=True)
        run("--check", success=False)
        require(builds() == 7, "a gitlink mismatch must fail before building")
        set_gitlink(second)
        run("--check")
        subprocess.run(["bash", "-c", phase], env=environment, check=True, capture_output=True, text=True)
        require(builds() == 7, "valid project preflight must not rebuild")
        for changed in (patch, recipe, packager):
            before = builds()
            with changed.open("a") as stream:
                stream.write("\n# changed input\n")
            run("--check", success=False)
            run()
            require(builds() == before + 1, f"changed {changed.name} must invalidate cache")

        provenance = framework / "SSHAppGhostty.provenance.json"
        manifest = json.loads(provenance.read_text())
        require(manifest["vt_lock"] == json.loads(lock.read_text()), "provenance must record the VT lock")
        require("0001-api.patch" in manifest["patches"], "provenance must record VT patches")
        require(len(manifest["artifacts"]) == 2, "provenance must record both native slices")
        require(len(manifest["module_maps"]) == 2, "provenance must record both module maps")
        for damaged in ("invalid json", "{}"):
            before = builds()
            provenance.write_text(damaged)
            run("--check", success=False)
            require(provenance.read_text() == damaged, "preflight cannot repair provenance")
            run()
            require(builds() == before + 1, "invalid provenance must rebuild")


def main() -> None:
    test_ghostty_vt_packaging()
    test_ghostty_vt_cache_behavior()
    script = read(REPO_ROOT / "scripts/build-libssh2.sh")
    context = "build-libssh2.sh"

    for forbidden in (
        "x86_64",
        "lipo",
        "sim-fat",
    ):
        require_absent(script, forbidden, context)

    for expected in (
        'EXPECTED_OPENSSL_COMMIT="45e844fa2a14ec92d146bd8f5778ac130b6625fb"',
        'EXPECTED_LIBSSH2_COMMIT="2e1717456b8dd4c980e8e48d6dbfec524c2e62d1"',
        'homebrew_bin="/opt/homebrew/bin"',
        'PATH="$PATH:$homebrew_bin"',
        'git -C "$source_dir" rev-parse HEAD',
        'git -C "$source_dir" status --porcelain --untracked-files=all --ignored',
        "native builds require pristine pinned sources",
        'LIBSSH2_SRC="$BUILD_DIR/libssh2-src"',
        "rsync -a --delete --exclude='.git'",
        "numbered_patches",
        'patch -d "$LIBSSH2_SRC" -p1 -F 0 --batch',
        'build-script=%s',
        'patch:%s=%s',
        'SSHAppNative.input-sha256',
        'SSHAppNative.provenance.json',
        'framework_hash_matches "libssh2.xcframework"',
        'framework_hash_matches "libcrypto.xcframework"',
        'framework_hash_matches "libssl.xcframework"',
        '[ "$(tr -d \'\\r\\n\' < "$hash_path")" = "$INPUT_HASH" ]',
        'rm -rf "$BUILD_DIR"',
        '"$FRAMEWORKS_DIR/libcrypto.xcframework"',
        '"$FRAMEWORKS_DIR/libssl.xcframework"',
        '"$FRAMEWORKS_DIR/libssh2.xcframework"',
        "build_openssl ios64-xcrun iphoneos-arm64",
        "build_openssl iossimulator-arm64-xcrun iphonesimulator-arm64",
        "build_libssh2 arm64 iphoneos-arm64 iphoneos",
        "build_libssh2 arm64 iphonesimulator-arm64 iphonesimulator",
        '-library "$BUILD_DIR/openssl-iphonesimulator-arm64/lib/libcrypto.a"',
        '-library "$BUILD_DIR/openssl-iphonesimulator-arm64/lib/libssl.a"',
        '-library "$BUILD_DIR/libssh2-iphonesimulator-arm64/lib/libssh2.a"',
    ):
        require_contains(script, expected, context)

    for forbidden in (
        '-headers "$BUILD_DIR/openssl-iphoneos-arm64/include"',
        '-headers "$BUILD_DIR/openssl-iphonesimulator-arm64/include"',
        '-headers "$BUILD_DIR/libssh2-iphoneos-arm64/include"',
        '-headers "$BUILD_DIR/libssh2-iphonesimulator-arm64/include"',
        "Namespacing libssh2 headers",
    ):
        require_absent(script, forbidden, context)

    patch = read(
        REPO_ROOT
        / "scripts/libssh2-patches/0001-userauth-banner-callback.patch"
    )
    patch_context = "libssh2 userauth banner patch"
    for expected in (
        "LIBSSH2_USERAUTH_BANNER_FUNC",
        "LIBSSH2_CALLBACK_USERAUTH_BANNER      10",
        "SSH_MSG_USERAUTH_BANNER",
        "ssh2_get_chars",
        "ssh2_eob",
        "macstate == SSH2_MAC_CONFIRMED",
        "test_userauth_banner_callback",
        "malformed banner invoked callback",
        "post-auth callback must not run",
        "banner packet was consumed or changed",
    ):
        require_contains(patch, expected, patch_context)

    shim = read(REPO_ROOT / "SSHApp/SSH/CLibSSH2Shim.c")
    require_contains(
        shim,
        "SSHAPP_LIBSSH2_CALLBACK_USERAUTH_BANNER 10",
        "CLibSSH2Shim callback compatibility declaration",
    )
    host_test = read(REPO_ROOT / "scripts/test-libssh2-banner-callback.sh")
    require_contains(
        host_test,
        "test-keyboard-interactive-bridge.c",
        "patched libssh2 host tests",
    )
    require_contains(
        host_test,
        '"$bridge_test"',
        "patched libssh2 host tests",
    )

    modulemap = read(REPO_ROOT / "SSHApp/SSH/CSSH2/module.modulemap")
    require_contains(modulemap, "module CSSH2", "CSSH2 module map")
    require_contains(modulemap, "../../../vendor/libssh2/include/libssh2.h", "CSSH2 module map")

    project = read(REPO_ROOT / "SSHApp.xcodeproj/project.pbxproj")
    require_contains(project, "$(PROJECT_DIR)/SSHApp/SSH/CSSH2", "project build settings")
    require_contains(project, "$(PROJECT_DIR)/vendor/libssh2/include", "project build settings")

    makefile = read(REPO_ROOT / "Makefile")
    require_contains(makefile, "setup: submodules libssh2 ghostty-vt", "setup must stage VT headers before SwiftPM")
    for target in ("build", "test", "test-unit", "test-ui", "test-device", "test-live-ssh"):
        require_contains(makefile, f"{target}: setup", "app/test targets must prepare native packages")

    package = read(REPO_ROOT / "Packages/SSHAppGhostty/Package.swift")
    require_contains(package, 'name: "SSHAppGhostty"', "SSHAppGhostty Package.swift")
    require_contains(package, '.iOS(.v18)', "SSHAppGhostty Package.swift")
    require_contains(
        package,
        'path: "../../Frameworks/GhosttyVT.xcframework"',
        "SSHAppGhostty Package.swift",
    )
    require_contains(
        package,
        '.library(name: "GhosttyTheme", targets: ["GhosttyTheme"])',
        "SSHAppGhostty Package.swift",
    )
    require_contains(
        package,
        'dependencies: ["GhosttyVT"]',
        "SSHAppGhostty Package.swift",
    )
    require_absent(package, '.package(', "package has no remote dependencies")
    require_contains(package, 'dependencies: ["libghosttyvt"]', "CGhosttyVT binary edge")
    require_contains(package, 'dependencies: ["CGhosttyVT"]', "GhosttyVT C bridge edge")
    require_contains(package, 'dependencies: ["GhosttyTerminal", "GhosttyVT"]', "GhosttyTheme umbrella closure")
    require_contains(package, '.linkedLibrary("c++")', "VT native runtime linkage")
    require_absent(package, ".macOS", "SSHAppGhostty Package.swift")
    require_absent(package, ".macCatalyst", "SSHAppGhostty Package.swift")

    require(package.count('.library(name:') == 1, "Only the GhosttyTheme umbrella may be exposed")
    require(project.count('productName = GhosttyTheme;') == 2, "App and hosted tests share GhosttyTheme")
    require_absent(project, "GhosttyTerminal in Frameworks", "no overlapping product closures")
    require_absent(project, "GhosttyVT in Frameworks", "no overlapping product closures")
    require_absent(project, "already exists, skipping build", "project phases must validate inputs")
    require_contains(project, "Validate GhosttyVT", "project build phases")
    require_contains(project, "XCLocalSwiftPackageReference", "project package references")
    require_contains(project, "Packages/SSHAppGhostty", "project package references")
    require_absent(project, "https://github.com/Lakr233/libghostty-spm", "project package references")


if __name__ == "__main__":
    main()
