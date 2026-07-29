#!/usr/bin/env python3
"""Inject live SSH settings into a temporary UI-test xctestrun file."""

from __future__ import annotations

import os
import pathlib
import plistlib
import sys
from typing import Any


ENVIRONMENT_KEYS = (
    "SSHAPP_LIVE_SSH_DESTINATION",
    "SSHAPP_LIVE_SSH_PASSWORD",
    "SSHAPP_LIVE_SSH_ACCEPT_UNKNOWN_HOST",
    "SSHAPP_LIVE_SSH_SAVE_PASSWORD",
    "SSHAPP_LIVE_SSH_ENABLE_DEFAULT_TMUX",
    "SSHAPP_LIVE_SSH_TIMEOUT",
)


def configured_environment(source: dict[str, str]) -> dict[str, str]:
    destination = source.get("SSHAPP_LIVE_SSH_DESTINATION", "").strip()
    if not destination:
        raise ValueError("SSHAPP_LIVE_SSH_DESTINATION is required")

    configured = {
        key: value
        for key in ENVIRONMENT_KEYS
        if (value := source.get(key)) is not None and value != ""
    }
    configured["SSHAPP_LIVE_SSH_DESTINATION"] = destination
    return configured


def substitute_test_root(node: Any, test_root: str) -> int:
    """Resolve __TESTROOT__ to an absolute path so a relocated xctestrun
    (outside Build/Products) still finds its test products."""
    replacements = 0
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(value, str) and "__TESTROOT__" in value:
                node[key] = value.replace("__TESTROOT__", test_root)
                replacements += 1
            else:
                replacements += substitute_test_root(value, test_root)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            if isinstance(value, str) and "__TESTROOT__" in value:
                node[index] = value.replace("__TESTROOT__", test_root)
                replacements += 1
            else:
                replacements += substitute_test_root(value, test_root)
    return replacements


def configure_xctestrun(
    document: dict[str, Any],
    environment: dict[str, str],
) -> int:
    configured_targets = 0
    for configuration in document.get("TestConfigurations", []):
        for target in configuration.get("TestTargets", []):
            if target.get("BlueprintName") != "SSHAppUITests":
                continue

            target.setdefault("EnvironmentVariables", {}).update(environment)
            configured_targets += 1

    return configured_targets


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(
            f"usage: {sys.argv[0]} <temporary.xctestrun> [test-root]",
            file=sys.stderr,
        )
        return 2

    path = pathlib.Path(sys.argv[1])
    test_root = sys.argv[2] if len(sys.argv) == 3 else None
    try:
        environment = configured_environment(dict(os.environ))
        with path.open("rb") as source:
            document = plistlib.load(source)

        if test_root is not None:
            substituted = substitute_test_root(document, test_root)
            if substituted == 0:
                raise ValueError("xctestrun file contains no __TESTROOT__ paths")

        configured_targets = configure_xctestrun(document, environment)
        if configured_targets == 0:
            raise ValueError("xctestrun file contains no SSHAppUITests target")

        with path.open("wb") as destination:
            plistlib.dump(document, destination)
        path.chmod(0o600)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Unable to configure live SSH test run: {error}", file=sys.stderr)
        return 1

    print(f"Configured {configured_targets} SSHAppUITests target.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
