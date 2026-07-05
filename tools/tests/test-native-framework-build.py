#!/usr/bin/env python3
"""Regression checks for the native framework build recipe."""

from __future__ import annotations

from _checks import REPO_ROOT, read, require_absent, require_contains


def main() -> None:
    script = read(REPO_ROOT / "scripts/build-libssh2.sh")
    context = "build-libssh2.sh"

    for forbidden in (
        "x86_64",
        "lipo",
        "sim-fat",
    ):
        require_absent(script, forbidden, context)

    for expected in (
        "build_openssl ios64-xcrun                iphoneos-arm64",
        "build_openssl iossimulator-arm64-xcrun   iphonesimulator-arm64",
        "build_libssh2 arm64  iphoneos-arm64           iphoneos",
        "build_libssh2 arm64  iphonesimulator-arm64    iphonesimulator",
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

    for forbidden in (
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
