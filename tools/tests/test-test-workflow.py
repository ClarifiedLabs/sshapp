#!/usr/bin/env python3
"""Regression checks for the iOS test workflow."""

from __future__ import annotations

from _checks import REPO_ROOT, read, require_absent, require_contains


def main() -> None:
    workflow = read(REPO_ROOT / ".github/workflows/test-ios.yml")
    runner = read(REPO_ROOT / "scripts/run-ios-tests.sh")
    makefile = read(REPO_ROOT / "Makefile")
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
        "XCODE_RESULT_BUNDLE_PATH: .build/ci/xcresults",
        "UNIT_SIMULATOR_NAME: SSHApp CI Unit Tests",
        "UNIT_TEST_ATTEMPTS: 2",
        "UI_SIMULATOR_NAME: SSHApp CI UI Tests",
        "UI_TEST_ATTEMPTS: 2",
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
        "Run unit tests",
        "./scripts/run-ios-tests.sh unit",
        "Run UI tests",
        "./scripts/run-ios-tests.sh ui",
        "Upload test result bundles",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "SSHApp.xcresults",
        "if-no-files-found: warn",
    ):
        require_contains(workflow, needle, context)

    for needle in (
        '"$XCODEBUILD" test',
        "python3 ./scripts/resolve-ios-simulator.py",
        "UNIT_SIMULATOR_NAME",
        "UNIT_TEST_ATTEMPTS",
        "resolve_unit_destination",
        "resolve_dedicated_destination \"$UNIT_SIMULATOR_NAME\"",
        "--dedicated",
        "--erase",
        "--boot",
        "UI_TEST_ATTEMPTS",
        "SSHAppTests",
        "SSHAppUITests",
        "-only-testing:\"$target\"",
        "-resultBundlePath",
        "unit-tests-attempt-${attempt}.xcresult",
        "ui-tests-attempt-${attempt}.xcresult",
        "-clonedSourcePackagesDirPath",
        "-derivedDataPath",
        "-skipPackagePluginValidation",
        "-skipMacroValidation",
    ):
        require_contains(runner, needle, "run-ios-tests.sh")

    for needle in (
        "test-unit:",
        "test-ui:",
        "./scripts/run-ios-tests.sh all",
        "./scripts/run-ios-tests.sh unit",
        "./scripts/run-ios-tests.sh ui",
        "XCODE_RESULT_BUNDLE_PATH",
    ):
        require_contains(makefile, needle, "Makefile")

    for old in (
        "iPhone 17 Pro",
        "platform=iOS Simulator,name=",
        'echo "DESTINATION=$destination" >> "$GITHUB_ENV"',
        "self" + "-hosted",
        "APP_STORE_CONNECT",
        "IOS_DISTRIBUTION_CERTIFICATE",
        "IOS_PROVISIONING_PROFILE",
        "APPLE_TEAM_ID",
    ):
        require_absent(workflow, old, context)


if __name__ == "__main__":
    main()
