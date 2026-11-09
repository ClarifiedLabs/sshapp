#!/usr/bin/env python3
"""Validate an explicit, existing iPhone Duo simulator destination."""

from __future__ import annotations

import json
import subprocess
import sys
from typing import Any

DUO_DEVICE_TYPE_SUFFIX = "SimDeviceType.iPhone-Duo"
DESTINATION_PREFIX = "platform=iOS Simulator,id="


def validated_duo_udid(destination: str, listing: dict[str, Any]) -> str:
    if not destination.startswith(DESTINATION_PREFIX):
        raise ValueError(
            "Duo tests require XCODE_DESTINATION='platform=iOS Simulator,id=<duo-udid>'."
        )
    udid = destination.removeprefix(DESTINATION_PREFIX)
    if not udid or "," in udid or any(char.isspace() for char in udid):
        raise ValueError("The Duo destination must contain exactly one simulator UDID.")

    devices = listing.get("devices", {})
    for runtime_devices in devices.values():
        for device in runtime_devices:
            if device.get("udid") != udid:
                continue
            if not device.get("isAvailable", True) or device.get("availabilityError"):
                raise ValueError(f"Simulator {udid} is unavailable: {device.get('availabilityError', 'unknown error')}")
            identifier = str(device.get("deviceTypeIdentifier", ""))
            if not identifier.endswith(DUO_DEVICE_TYPE_SUFFIX):
                raise ValueError(
                    f"Simulator {udid} is {device.get('name', 'unknown')}, not iPhone Duo. "
                    "The focused Duo test plan is not a general simulator fallback."
                )
            return udid
    raise ValueError(f"No existing simulator matches Duo UDID {udid}; create and boot it explicitly first.")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-duo-destination.py 'platform=iOS Simulator,id=<duo-udid>'", file=sys.stderr)
        return 2
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "-j"],
            check=True,
            capture_output=True,
            text=True,
        )
        validated_duo_udid(sys.argv[1], json.loads(result.stdout))
    except (ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"Invalid Duo destination: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
