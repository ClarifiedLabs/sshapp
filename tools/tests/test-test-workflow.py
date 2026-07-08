#!/usr/bin/env python3
"""Regression checks for the iOS test workflow."""

from __future__ import annotations

from _checks import REPO_ROOT, read, require_absent, require_contains


def main() -> None:
    workflow = read(REPO_ROOT / ".github/workflows/test-ios.yml")
    runner = read(REPO_ROOT / "scripts/run-ios-tests.sh")
    makefile = read(REPO_ROOT / "Makefile")
    all_test_plan = read(REPO_ROOT / "TestPlans/SSHAppAllTests.xctestplan")
    unit_test_plan = read(REPO_ROOT / "TestPlans/SSHAppUnitTests.xctestplan")
    ui_test_plan = read(REPO_ROOT / "TestPlans/SSHAppUITests.xctestplan")
    scheme = read(REPO_ROOT / "SSHApp.xcodeproj/xcshareddata/xcschemes/SSHApp.xcscheme")
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
        "TEST_SIMULATOR_NAME: SSHApp CI Tests",
        "ALL_TEST_PLAN: SSHAppAllTests",
        "UNIT_TEST_PLAN: SSHAppUnitTests",
        "UNIT_SIMULATOR_NAME: SSHApp CI Unit Tests",
        "UNIT_TEST_ATTEMPTS: 2",
        "UI_TEST_PLAN: SSHAppUITests",
        "UI_SIMULATOR_NAME: SSHApp CI UI Tests",
        "UI_TEST_ATTEMPTS: 2",
        "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd",
        "submodules: true",
        "actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae",
        "id: native-framework-cache",
        "if: steps.native-framework-cache.outputs.cache-hit != 'true'",
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
        "TestPlans/*.xctestplan",
        "make setup",
        "restore-keys:",
        "xcode-deriveddata-test-${{ runner.os }}-",
        "xcodebuild -resolvePackageDependencies",
        "Run iOS tests",
        "./scripts/run-ios-tests.sh all",
        "Upload test result bundles",
        "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
        "SSHApp.xcresults",
        "if-no-files-found: warn",
    ):
        require_contains(workflow, needle, context)

    for needle in (
        '"$XCODEBUILD" build-for-testing',
        '"$XCODEBUILD" test-without-building',
        "python3 ./scripts/resolve-ios-simulator.py",
        "TEST_SIMULATOR_NAME",
        "ALL_TEST_PLAN",
        "UNIT_TEST_PLAN",
        "UI_TEST_PLAN",
        "UNIT_SIMULATOR_NAME",
        "UNIT_TEST_ATTEMPTS",
        "resolve_unit_destination",
        "resolve_dedicated_destination \"$UNIT_SIMULATOR_NAME\"",
        "--dedicated",
        "--erase",
        "--boot",
        "UI_TEST_ATTEMPTS",
        "build_for_testing \"all test plans\" \"$ALL_TEST_PLAN\"",
        "run_test_plan_with_retries \"unit tests\" \"$UNIT_TEST_PLAN\" \"$TEST_SIMULATOR_NAME\"",
        "run_test_plan_with_retries \"UI tests\" \"$UI_TEST_PLAN\" \"$TEST_SIMULATOR_NAME\"",
        "-testPlan \"$test_plan\"",
        "-resultBundlePath",
        "${result_prefix}-attempt-${attempt}.xcresult",
        "unit-tests",
        "ui-tests",
        "all-build-for-testing.xcresult",
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
        "TEST_SIMULATOR_NAME",
        "ALL_TEST_PLAN",
        "UNIT_TEST_PLAN",
        "UI_TEST_PLAN",
    ):
        require_contains(makefile, needle, "Makefile")

    for needle in (
        "SSHAppAllTests.xctestplan",
        "SSHAppUnitTests.xctestplan",
        "SSHAppUITests.xctestplan",
        'shouldAutocreateTestPlan = "NO"',
        "<TestPlans>",
    ):
        require_contains(scheme, needle, "SSHApp.xcscheme")

    for plan, plan_name, expected_targets in (
        (all_test_plan, "SSHAppAllTests.xctestplan", ("SSHAppTests", "SSHAppUITests")),
        (unit_test_plan, "SSHAppUnitTests.xctestplan", ("SSHAppTests",)),
        (ui_test_plan, "SSHAppUITests.xctestplan", ("SSHAppUITests",)),
    ):
        require_contains(plan, '"version" : 1', plan_name)
        require_contains(plan, '"targetForVariableExpansion"', plan_name)
        for target in expected_targets:
            require_contains(plan, f'"name" : "{target}"', plan_name)

    for old in (
        "iPhone 17 Pro",
        "platform=iOS Simulator,name=",
        'echo "DESTINATION=$destination" >> "$GITHUB_ENV"',
        "self" + "-hosted",
        "APP_STORE_CONNECT",
        "IOS_DISTRIBUTION_CERTIFICATE",
        "IOS_PROVISIONING_PROFILE",
        "APPLE_TEAM_ID",
        "-only-testing:",
    ):
        require_absent(workflow, old, context)

    for old in (
        "-only-testing:",
        '"$XCODEBUILD" test \\',
    ):
        require_absent(runner, old, "run-ios-tests.sh")


if __name__ == "__main__":
    main()
