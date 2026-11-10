#!/usr/bin/env python3
"""Regression checks for the TestFlight deploy workflow."""

from __future__ import annotations

from _checks import REPO_ROOT, read, require, require_absent, require_contains, require_count


def main() -> None:
    workflow = read(REPO_ROOT / ".github/workflows/deploy-ios.yml")
    context = "deploy-ios.yml"

    for needle in (
        "on:\n  workflow_call:",
        "if: startsWith(github.ref, 'refs/tags/v')",
        "GITHUB_SHA^{commit}",
        "release_sha",
        "runs-on: xcode-27",
        "PROJECT: SSHApp.xcodeproj",
        "SCHEME: SSHApp",
        "BUNDLE_IDENTIFIER: dev.sshapp.sshapp",
        "Resolve native cache inputs",
        "- name: Check out pinned submodules\n        run: make submodules",
        "libssh2_commit",
        "openssl_commit",
        "scripts/libssh2-patches/**",
        "scripts/build-ghostty-vt.sh",
        "scripts/build-ghostty-vt-native.py",
        "vendor/libghostty-vt/native-lock.json",
        "vendor/libghostty-vt/patches/**",
        "Frameworks/libssh2.xcframework",
        "Frameworks/libcrypto.xcframework",
        "Frameworks/libssl.xcframework",
        "Frameworks/GhosttyVT.xcframework",
        "Packages/SSHAppGhostty/Sources/**/*.h",
        "Packages/SSHAppGhostty/Sources/**/*.c",
        "Packages/SSHAppGhostty/Package.swift",
        "Packages/SSHAppGhostty/Sources/**/*.swift",
        "make setup",
        "APP_STORE_CONNECT_KEY_ID",
        "APP_STORE_CONNECT_ISSUER_ID",
        "APP_STORE_CONNECT_PRIVATE_KEY",
        "APPLE_TEAM_ID",
        "IOS_DISTRIBUTION_CERTIFICATE_BASE64",
        "IOS_DISTRIBUTION_CERTIFICATE_PASSWORD",
        "IOS_PROVISIONING_PROFILE_BASE64",
        "PROVISIONING_PROFILE_NAME",
        "MARKETING_VERSION",
        "CURRENT_PROJECT_VERSION",
        "SUPPRESS_WARNINGS=NO",
        "dev.sshapp.sshapp",
    ):
        require_contains(workflow, needle, context)

    require_absent(workflow, "submodules: true", "Ghostty must not be cloned with full history")
    require(
        workflow.index("- name: Check out pinned submodules") < workflow.index("- name: Resolve native cache inputs"),
        "pinned submodules must be checked out before native cache inputs are read",
    )

    # Test seams compile only with VT_TEST_HOOKS; the App Store archive must never set it.
    require_absent(workflow, "VT_TEST_HOOKS", context)
    package = read(REPO_ROOT / "Packages/SSHAppGhostty/Package.swift")
    require_contains(package, '.define("VT_TEST_HOOKS", .when(configuration: .debug))',
                     "Package.swift test hooks must be Debug-only")
    require(
        workflow.index("- name: Build native frameworks") < workflow.index("- name: Resolve Swift packages"),
        "make setup must stage generated CGhosttyVT headers before SwiftPM resolution",
    )
    for cache_key in (line for line in workflow.splitlines() if "key: native-frameworks-" in line
                      or "key: xcode-deriveddata-" in line):
        for input_path in ("scripts/build-ghostty-vt.sh", "scripts/build-ghostty-vt-native.py",
                           "vendor/libghostty-vt/native-lock.json", "vendor/libghostty-vt/patches/**"):
            require_contains(cache_key, input_path, "native/DerivedData cache VT provenance inputs")
        if "key: native-frameworks-" in cache_key:
            require_contains(cache_key, "steps.native-cache.outputs.toolchain",
                             "native cache must miss after an Xcode or SDK update")

    for needle in (
        "if ! xcrun --sdk iphoneos metal --version; then",
        "xcodebuild -downloadComponent MetalToolchain",
        "fi\n          xcrun --sdk iphoneos metal --version",
    ):
        require_contains(workflow, needle, context)
    require(
        workflow.index("- name: Select Xcode 27")
        < workflow.index("- name: Ensure Metal toolchain")
        < workflow.index("- name: Build native frameworks"),
        "Metal must be available in the selected Xcode before building native frameworks",
    )

    # Only automatic release-tag pushes publish; manual dispatch is always a dry run.
    upload_guard = "if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')"
    require_contains(workflow, 'python3 scripts/validate-ipa.py "$IPA_PATH" --bundle-identifier "$BUNDLE_IDENTIFIER"',
                     "exported IPA must be checked using the release bundle identifier")
    require(workflow.index("- name: Export IPA")
            < workflow.index("- name: Validate exported bundle metadata")
            < workflow.index("- name: Upload to TestFlight"),
            "IPA metadata must be checked after export and before upload")
    require_count(workflow, upload_guard, 2, context)
    for step in ("Upload to TestFlight", "Upload dSYMs to App Store Connect"):
        require_contains(workflow, f"- name: {step}\n        {upload_guard}", context)
    for obsolete in ("require-tests:", "actions: write", "TEST_POLL_SECONDS",
                     "time.sleep", "/dispatches", "workflow_dispatch:", "upload_to_testflight"):
        require_absent(workflow, obsolete, context)
    require_absent(workflow.split("jobs:", 1)[0], "push:",
                   "reusable release workflow must not start a duplicate pipeline")
    require_absent(workflow, "self" + "-hosted", context)

    for old in (
        "if: github.event_name == 'push' || inputs.upload_to_testflight",
        "ios/v*.*.*",
        "ios/v[0-9]*",
        "mobile/ios/apps/NaughtBot",
        "com.naughtbot.naughtbot",
        "ASC_API_KEY",
        "APPLE_DISTRIBUTION_CERT",
        "xcodebuild test",
    ):
        require_absent(workflow, old, context)


if __name__ == "__main__":
    main()
