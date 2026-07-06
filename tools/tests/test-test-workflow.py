#!/usr/bin/env python3
"""Regression checks for the iOS test workflow."""

from __future__ import annotations

from _checks import REPO_ROOT, read, require_absent, require_contains


def main() -> None:
    workflow = read(REPO_ROOT / ".github/workflows/test-ios.yml")
    context = "test-ios.yml"

    for needle in (
        "name: test-ios",
        "push:",
        "branches:",
        "- main",
        "- release-ci",
        "pull_request:",
        "workflow_dispatch:",
        "runs-on: macos-26",
        "timeout-minutes: 90",
        "PROJECT: SSHApp.xcodeproj",
        "SCHEME: SSHApp",
        "Resolve iOS simulator",
        "python3 ./scripts/resolve-ios-simulator.py",
        'echo "DESTINATION=$destination" >> "$GITHUB_ENV"',
        "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd",
        "submodules: true",
        "actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae",
        "brew install zig@0.15",
        'zig_version="$("$zig_path" version)"',
        'echo "ZIG=$zig_path" >> "$GITHUB_ENV"',
        "Resolve native cache inputs",
        "libssh2_commit",
        "openssl_commit",
        "ghostty_commit",
        "scripts/build-ghostty-ios.sh",
        "scripts/ghostty-patches/**",
        "Packages/SSHAppGhostty/Package.swift",
        "Packages/SSHAppGhostty/Sources/**/*.swift",
        "make setup",
        "xcodebuild -resolvePackageDependencies",
        "xcodebuild test",
        "-clonedSourcePackagesDirPath",
        "-derivedDataPath",
        "-skipPackagePluginValidation",
        "-skipMacroValidation",
    ):
        require_contains(workflow, needle, context)

    for old in (
        "iPhone 17 Pro",
        "platform=iOS Simulator,name=",
        "self" + "-hosted",
        "APP_STORE_CONNECT",
        "IOS_DISTRIBUTION_CERTIFICATE",
        "IOS_PROVISIONING_PROFILE",
        "APPLE_TEAM_ID",
    ):
        require_absent(workflow, old, context)


if __name__ == "__main__":
    main()
