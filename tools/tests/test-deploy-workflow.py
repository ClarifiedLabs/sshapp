#!/usr/bin/env python3
"""Regression checks for the TestFlight deploy workflow."""

from __future__ import annotations

from _checks import REPO_ROOT, read, require_absent, require_contains, require_count


def main() -> None:
    workflow = read(REPO_ROOT / ".github/workflows/deploy-ios.yml")
    context = "deploy-ios.yml"

    for needle in (
        "release-ci",
        "v*.*.*",
        "if: startsWith(github.ref, 'refs/tags/v')",
        "GITHUB_SHA^{commit}",
        "release_sha",
        "runs-on: macos-26",
        "PROJECT: SSHApp.xcodeproj",
        "SCHEME: SSHApp",
        "BUNDLE_IDENTIFIER: dev.sshapp.sshapp",
        "make libssh2",
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
        "upload_to_testflight",
        "dev.sshapp.sshapp",
    ):
        require_contains(workflow, needle, context)

    upload_guard = "if: startsWith(github.ref, 'refs/tags/v') || (github.event_name == 'workflow_dispatch' && inputs.upload_to_testflight)"
    require_count(workflow, upload_guard, 2, context)
    require_absent(workflow, "self" + "-hosted", context)

    for old in (
        "if: github.event_name == 'push' || inputs.upload_to_testflight",
        "ios/v*.*.*",
        "ios/v[0-9]*",
        "mobile/ios/apps/NaughtBot",
        "com.naughtbot.naughtbot",
        "ASC_API_KEY",
        "APPLE_DISTRIBUTION_CERT",
    ):
        require_absent(workflow, old, context)


if __name__ == "__main__":
    main()
