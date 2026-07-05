#!/usr/bin/env python3
"""Resolve an available iOS Simulator destination for xcodebuild tests."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any


SIMULATOR_NAME = "SSHApp CI"


def parse_version(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def is_ios_runtime(runtime: dict[str, Any]) -> bool:
    identifier = runtime.get("identifier", "")
    name = runtime.get("name", "")
    return runtime.get("platform") == "iOS" or ".iOS-" in identifier or name.startswith("iOS ")


def latest_ios_runtime(runtimes: list[dict[str, Any]]) -> dict[str, Any]:
    candidates = [
        runtime
        for runtime in runtimes
        if runtime.get("isAvailable", True)
        and runtime.get("identifier")
        and is_ios_runtime(runtime)
    ]
    if not candidates:
        raise RuntimeError("No available iOS Simulator runtime found.")

    return max(
        candidates,
        key=lambda runtime: (
            parse_version(str(runtime.get("version", ""))),
            str(runtime.get("name", "")),
        ),
    )


def is_available_device(device: dict[str, Any]) -> bool:
    return bool(device.get("udid")) and device.get("isAvailable", True) and not device.get("availabilityError")


def is_iphone_device(device: dict[str, Any]) -> bool:
    name = str(device.get("name", ""))
    identifier = str(device.get("deviceTypeIdentifier", ""))
    return name.startswith("iPhone") or ".iPhone-" in identifier


def iphone_variant_score(name: str) -> int:
    if not name.startswith("iPhone"):
        return 0
    if " Pro Max" in name:
        return 4
    if " Pro" in name:
        return 5
    if re.fullmatch(r"iPhone \d+", name):
        return 3
    if " Air" in name or " Plus" in name:
        return 2
    if " mini" in name or " SE" in name:
        return 1
    return 1


def device_score(device: dict[str, Any]) -> tuple[int, tuple[int, ...], int, int, str]:
    name = str(device.get("name", ""))
    state = str(device.get("state", ""))
    return (
        1 if is_iphone_device(device) else 0,
        parse_version(name),
        iphone_variant_score(name),
        1 if state == "Booted" else 0,
        name,
    )


def choose_existing_device(
    devices_by_runtime: dict[str, list[dict[str, Any]]],
    runtime: dict[str, Any],
) -> dict[str, Any] | None:
    devices = [
        device
        for device in devices_by_runtime.get(str(runtime["identifier"]), [])
        if is_available_device(device)
    ]
    if not devices:
        return None

    iphones = [device for device in devices if is_iphone_device(device)]
    return max(iphones or devices, key=device_score)


def is_iphone_device_type(device_type: dict[str, Any]) -> bool:
    name = str(device_type.get("name", ""))
    identifier = str(device_type.get("identifier", ""))
    return device_type.get("productFamily") == "iPhone" or name.startswith("iPhone") or ".iPhone-" in identifier


def choose_device_type(
    runtime: dict[str, Any],
    device_types: list[dict[str, Any]],
) -> dict[str, Any]:
    supported_device_types = runtime.get("supportedDeviceTypes")
    candidates = supported_device_types if isinstance(supported_device_types, list) else device_types
    iphones = [
        device_type
        for device_type in candidates
        if device_type.get("identifier") and is_iphone_device_type(device_type)
    ]
    if not iphones:
        raise RuntimeError(f"No iPhone simulator device type found for {runtime.get('name', 'iOS')}.")

    return iphones[0]


def run_json(*command: str) -> dict[str, Any]:
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def create_device(
    runtime: dict[str, Any],
    device_type: dict[str, Any],
    *,
    name: str = SIMULATOR_NAME,
) -> str:
    result = subprocess.run(
        [
            "xcrun",
            "simctl",
            "create",
            name,
            str(device_type["identifier"]),
            str(runtime["identifier"]),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def resolve_udid(name: str = SIMULATOR_NAME) -> str:
    runtime = latest_ios_runtime(run_json("xcrun", "simctl", "list", "runtimes", "--json").get("runtimes") or [])
    devices_by_runtime = run_json("xcrun", "simctl", "list", "devices", "--json").get("devices") or {}

    device = choose_existing_device(devices_by_runtime, runtime)
    if device:
        print(
            f"Using {device.get('name')} on {runtime.get('name')} ({device['udid']}).",
            file=sys.stderr,
        )
        return str(device["udid"])

    device_types = run_json("xcrun", "simctl", "list", "devicetypes", "--json").get("devicetypes") or []
    device_type = choose_device_type(runtime, device_types)
    udid = create_device(runtime, device_type, name=name)
    print(
        f"Created {name} as {device_type.get('name')} on {runtime.get('name')} ({udid}).",
        file=sys.stderr,
    )
    return udid


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default=SIMULATOR_NAME, help="name to use when creating a simulator")
    parser.add_argument("--udid-only", action="store_true", help="print only the resolved simulator UDID")
    args = parser.parse_args()

    udid = resolve_udid(name=args.name)
    if args.udid_only:
        print(udid)
    else:
        print(f"platform=iOS Simulator,id={udid}")


if __name__ == "__main__":
    main()
