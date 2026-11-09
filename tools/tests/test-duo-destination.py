#!/usr/bin/env python3
"""Regression checks for explicit Duo destination validation."""

from __future__ import annotations

import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/validate-duo-destination.py"
SPEC = importlib.util.spec_from_file_location("validate_duo_destination", SCRIPT)
assert SPEC and SPEC.loader
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)

DUO_ID = "67790072-2D79-47C8-89A8-DA7BC1B499BB"
DESTINATION = f"platform=iOS Simulator,id={DUO_ID}"


def listing(device_type: str = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo") -> dict:
    return {"devices": {"runtime": [{
        "udid": DUO_ID,
        "name": "iPhone Duo",
        "deviceTypeIdentifier": device_type,
        "isAvailable": True,
    }]}}


def reject(destination: str, devices: dict) -> None:
    try:
        validator.validated_duo_udid(destination, devices)
    except ValueError:
        return
    raise AssertionError(f"Destination must be rejected: {destination}")


def main() -> None:
    assert validator.validated_duo_udid(DESTINATION, listing()) == DUO_ID
    reject("", listing())
    reject("platform=iOS Simulator,name=iPhone Duo", listing())
    reject(DESTINATION + ",OS=latest", listing())
    reject(DESTINATION, listing("com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"))
    reject(DESTINATION, {"devices": {}})
    unavailable = listing()
    unavailable["devices"]["runtime"][0]["availabilityError"] = "runtime missing"
    unavailable["devices"]["runtime"][0]["isAvailable"] = False
    reject(DESTINATION, unavailable)
    print("Passed explicit Duo destination checks")


if __name__ == "__main__":
    main()
