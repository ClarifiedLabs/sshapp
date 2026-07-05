#!/usr/bin/env python3
"""Regression checks for generic iOS Simulator destination resolution."""

from __future__ import annotations

import importlib.util

from _checks import REPO_ROOT, read, require, require_absent, require_contains


def load_resolver():
    path = REPO_ROOT / "scripts" / "resolve-ios-simulator.py"
    spec = importlib.util.spec_from_file_location("resolve_ios_simulator", path)
    require(spec is not None and spec.loader is not None, "resolver script must be importable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_runtime_selection(resolver) -> None:
    runtime = resolver.latest_ios_runtime(
        [
            {
                "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
                "platform": "iOS",
                "version": "18.5",
                "isAvailable": True,
                "name": "iOS 18.5",
            },
            {
                "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-4",
                "platform": "iOS",
                "version": "26.4",
                "isAvailable": False,
                "name": "iOS 26.4",
            },
            {
                "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                "platform": "iOS",
                "version": "26.5",
                "isAvailable": True,
                "name": "iOS 26.5",
            },
        ]
    )

    require(
        runtime["identifier"] == "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "resolver must choose the newest available iOS runtime",
    )


def test_existing_device_selection(resolver) -> None:
    runtime = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"}
    device = resolver.choose_existing_device(
        {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {
                    "name": "iPad Air",
                    "udid": "IPAD-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air",
                    "state": "Shutdown",
                },
                {
                    "name": "iPhone 17e",
                    "udid": "IPHONE-17E-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17e",
                    "state": "Shutdown",
                },
                {
                    "name": "iPhone 17 Pro",
                    "udid": "IPHONE-PRO-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    "state": "Shutdown",
                },
            ]
        },
        runtime,
    )

    require(device is not None and device["udid"] == "IPHONE-PRO-UDID", "resolver must prefer a standard iPhone")


def test_device_type_selection(resolver) -> None:
    runtime = {
        "name": "iOS 26.5",
        "supportedDeviceTypes": [
            {
                "name": "iPad Air",
                "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air",
                "productFamily": "iPad",
            },
            {
                "name": "iPhone 17",
                "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                "productFamily": "iPhone",
            },
        ],
    }

    device_type = resolver.choose_device_type(runtime, [])
    require(
        device_type["identifier"] == "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
        "resolver must create an iPhone simulator when no device exists",
    )


def test_ci_and_makefile_use_resolver() -> None:
    workflow = read(REPO_ROOT / ".github/workflows/test-ios.yml")
    makefile = read(REPO_ROOT / "Makefile")

    require_contains(workflow, "Resolve iOS simulator", "test-ios.yml")
    require_contains(workflow, "python3 ./scripts/resolve-ios-simulator.py", "test-ios.yml")
    require_contains(workflow, 'echo "DESTINATION=$destination" >> "$GITHUB_ENV"', "test-ios.yml")
    require_contains(makefile, "python3 ./scripts/resolve-ios-simulator.py", "Makefile")

    for context, text in (("test-ios.yml", workflow), ("Makefile", makefile)):
        require_absent(text, "iPhone 17 Pro", context)
        require_absent(text, "platform=iOS Simulator,name=", context)


def main() -> None:
    resolver = load_resolver()
    test_runtime_selection(resolver)
    test_existing_device_selection(resolver)
    test_device_type_selection(resolver)
    test_ci_and_makefile_use_resolver()


if __name__ == "__main__":
    main()
