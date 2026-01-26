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


if __name__ == "__main__":
    main()
