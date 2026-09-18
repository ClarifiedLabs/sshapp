#!/usr/bin/env python3
"""Regression checks for the native framework build recipe."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile

from _checks import REPO_ROOT, read, require, require_absent, require_contains


def test_ghostty_install_patch() -> None:
    # Exercise the actual patch without requiring Zig or initialized submodules.
    source = """    libghostty_vt_shared.install(libvt_step);
    libghostty_vt_shared.install(b.getInstallStep());
        // We shouldn't have this guard but we don't currently
        // build on macOS this way ironically so we need to fix that.
        if (!config.target.result.os.tag.isDarwin()) {
            libghostty_shared.installHeader(); // Only need one header
            libghostty_shared.install("libghostty.so");
            libghostty_static.install("libghostty.a");
        }
"""
    patch = REPO_ROOT / "scripts/ghostty-patches/0001-darwin-libghostty-install.sh"
    with tempfile.TemporaryDirectory(prefix="ghostty-install-test-") as directory:
        build_file = Path(directory) / "build.zig"
        build_file.write_text(source)
        subprocess.run([str(patch), directory], check=True, capture_output=True, text=True)
        patched = build_file.read_text()
        require_contains(
            patched,
            """    if (config.target.result.os.tag != .ios) {
        libghostty_vt_shared.install(b.getInstallStep());
    }""",
            "Ghostty install patch must exclude the unused VT dylib on iOS",
        )
        require_contains(patched, "libghostty_vt_shared.install(libvt_step);", "explicit VT build step")
        require_contains(patched, 'libghostty_static.install("libghostty.a");', "static embedded library")
        require_contains(patched, "libghostty static install for Darwin", "Darwin static install")
        subprocess.run([str(patch), directory], check=True, capture_output=True, text=True)
        require(build_file.read_text() == patched, "Ghostty install patch must be idempotent")

        # An already-applied Darwin patch must not bypass the new iOS VT guard.
        build_file.write_text(source + "// libghostty static install for Darwin\n")
        subprocess.run([str(patch), directory], check=True, capture_output=True, text=True)
        require_contains(build_file.read_text(), "if (config.target.result.os.tag != .ios)", "existing Darwin patch")

        build_file.write_text("// Upstream install step changed\n")
        result = subprocess.run([str(patch), directory], capture_output=True, text=True)
        require(result.returncode != 0, "Ghostty install patch must fail if the VT install step changes")


def main() -> None:
    test_ghostty_install_patch()
    script = read(REPO_ROOT / "scripts/build-libssh2.sh")
    context = "build-libssh2.sh"

    for forbidden in (
        "x86_64",
        "lipo",
        "sim-fat",
    ):
        require_absent(script, forbidden, context)

    for expected in (
        'EXPECTED_OPENSSL_COMMIT="f4dc4d58b48d346a8270183f89acf826d459b0ca"',
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

    ghostty_script = read(REPO_ROOT / "scripts/build-ghostty-ios.sh")
    ghostty_context = "build-ghostty-ios.sh"

    for expected in (
        'GHOSTTY_SRC="$PROJECT_DIR/vendor/ghostty"',
        'EXPECTED_GHOSTTY_COMMIT="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"',
        'REQUIRED_ZIG_VERSION="0.15.2"',
        'patch -p1 -i "$patch_file"',
        'GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED',
        'ghostty_surface_write_buffer',
        'local build_args=(',
        'build_args+=("-Dcpu=$zig_cpu")',
        '"${build_args[@]}"',
        'archive_name" = "libghostty-fat.a"',
        'archive_platforms="$(',
        'if [ "$archive_platforms" != "$mach_o_platform" ]; then',
        'ar -x "$archive"',
        'chmod u+rw "$staged_object"',
        'xcrun libtool -static -no_warning_for_no_symbols -o "$out/lib/libghostty.a" "${objects[@]}"',
        'build_ghostty_slice "aarch64-ios" "iphoneos-arm64" "2"',
        'build_ghostty_slice "aarch64-ios-simulator" "iphonesimulator-arm64" "7" "apple_m1"',
        '-output "$XCFRAMEWORK_PATH"',
        '"SSHAppGhostty.provenance.json"',
    ):
        require_contains(ghostty_script, expected, ghostty_context)

    # Stale-framework guard: the script must rebuild whenever the Ghostty
    # pin, build script, patches, or support inputs change instead of
    # silently reusing an existing xcframework (which previously left new
    # ghostty patches out of the linked framework).
    for expected in (
        "INPUT_HASH=\"$(compute_input_hash)\"",
        "SSHAppGhostty.input-sha256",
        'printf \'ghostty=%s\\n\' "$EXPECTED_GHOSTTY_COMMIT"',
        'printf \'zig=%s\\n\' "$REQUIRED_ZIG_VERSION"',
        "printf 'patch:%s=%s\\n'",
        "printf 'support:%s=%s\\n'",
        '[ -d "$XCFRAMEWORK_PATH" ] &&',
        '[ "$(tr -d \'\\r\\n\' < \"$XCFRAMEWORK_PATH/$INPUT_HASH_NAME\")\" = \"$INPUT_HASH\" ]',
        "matches input $INPUT_HASH; skipping build",
        'printf \'%s\\n\' "$INPUT_HASH" >"$XCFRAMEWORK_PATH/$INPUT_HASH_NAME"',
    ):
        require_contains(ghostty_script, expected, ghostty_context)

    require(
        ghostty_script.index("matches input $INPUT_HASH; skipping build")
        < ghostty_script.index('if ! command -v "$ZIG_BIN"'),
        "build-ghostty-ios.sh must reuse a matching cached framework before requiring Zig",
    )
    require_absent(
        ghostty_script,
        'printf \'zig=%s\\n\' "$zig_version"',
        ghostty_context,
    )

    makefile = read(REPO_ROOT / "Makefile")
    require_contains(
        makefile,
        "ghostty: submodules ## Build Ghostty xcframework when inputs changed",
        "Makefile ghostty target",
    )
    require_absent(
        makefile,
        "GhosttyKit.xcframework already exists, skipping",
        "Makefile ghostty target",
    )

    for forbidden in (
        'local cpu_args=()',
        '"${cpu_args[@]}"',
        "x86_64-ios-simulator",
        "maccatalyst",
        "macosx",
    ):
        require_absent(ghostty_script, forbidden, ghostty_context)

    package = read(REPO_ROOT / "Packages/SSHAppGhostty/Package.swift")
    require_contains(package, 'name: "SSHAppGhostty"', "SSHAppGhostty Package.swift")
    require_contains(package, '.iOS(.v18)', "SSHAppGhostty Package.swift")
    require_contains(
        package,
        'path: "../../Frameworks/GhosttyKit.xcframework"',
        "SSHAppGhostty Package.swift",
    )
    require_absent(package, ".macOS", "SSHAppGhostty Package.swift")
    require_absent(package, ".macCatalyst", "SSHAppGhostty Package.swift")

    require_contains(project, "Build Ghostty", "project build phases")
    require_contains(project, "XCLocalSwiftPackageReference", "project package references")
    require_contains(project, "Packages/SSHAppGhostty", "project package references")
    require_absent(project, "https://github.com/Lakr233/libghostty-spm", "project package references")


if __name__ == "__main__":
    main()
