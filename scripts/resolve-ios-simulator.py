#!/usr/bin/env python3
"""Resolve an available iOS Simulator destination for xcodebuild tests."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any


SIMULATOR_NAME = "SSHApp CI"
DUO_DEVICE_TYPE_SUFFIX = "SimDeviceType.iPhone-Duo"


class DuoOnlyRuntimeError(RuntimeError):
    """A runtime offers only the iPhone Duo form factor, unusable for benchmarks."""


def is_duo_device_type(device_type: Any) -> bool:
    return str(device_type.get("identifier", "")).endswith(DUO_DEVICE_TYPE_SUFFIX)


def parse_version(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def is_ios_runtime(runtime: dict[str, Any]) -> bool:
    identifier = runtime.get("identifier", "")
    name = runtime.get("name", "")
    return runtime.get("platform") == "iOS" or ".iOS-" in identifier or name.startswith("iOS ")


def latest_ios_runtime(
    runtimes: list[dict[str, Any]],
    major: int | None = None,
    *,
    device_family: str | None = None,
    device_types: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    def supports_family(runtime: dict[str, Any]) -> bool:
        if device_family is None:
            return True
        try:
            choose_device_type(runtime, device_types or [], device_family=device_family)
            return True
        except DuoOnlyRuntimeError:
            raise
        except RuntimeError:
            return False

    candidates = []
    duo_runtimes = []
    for runtime in runtimes:
        if not (runtime.get("isAvailable", True) and runtime.get("identifier") and is_ios_runtime(runtime)):
            continue
        if major is not None and parse_version(str(runtime.get("version", "")))[:1] != (major,):
            continue
        try:
            supports = supports_family(runtime)
        except DuoOnlyRuntimeError as error:
            duo_runtimes.append(str(error))
            continue
        if supports:
            candidates.append(runtime)
    if not candidates:
        if duo_runtimes:
            raise DuoOnlyRuntimeError(duo_runtimes[0])
        requested = f"iOS {major}" if major is not None else "iOS"
        family = f" supporting {device_family}" if device_family else ""
        raise RuntimeError(f"No available {requested} Simulator runtime{family} found.")

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


def is_ipad_device(device: dict[str, Any]) -> bool:
    name = str(device.get("name", ""))
    identifier = str(device.get("deviceTypeIdentifier", ""))
    return name.startswith("iPad") or ".iPad-" in identifier


def is_device_family(device: dict[str, Any], device_family: str) -> bool:
    if device_family == "iPad":
        return is_ipad_device(device)
    return is_iphone_device(device)


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


def ipad_variant_score(name: str) -> int:
    if not name.startswith("iPad"):
        return 0
    if "Pro 13-inch" in name:
        return 5
    if "Pro" in name:
        return 4
    if "Air 13-inch" in name:
        return 3
    if "Air" in name:
        return 2
    return 1


def device_score(
    device: dict[str, Any],
    device_family: str = "iPhone",
) -> tuple[int, tuple[int, ...], int, int, str]:
    name = str(device.get("name", ""))
    state = str(device.get("state", ""))
    variant_score = (
        ipad_variant_score(name)
        if device_family == "iPad"
        else iphone_variant_score(name)
    )
    return (
        1 if is_device_family(device, device_family) else 0,
        parse_version(name),
        variant_score,
        1 if state == "Booted" else 0,
        name,
    )


def is_duo_device(device: dict[str, Any]) -> bool:
    return str(device.get("deviceTypeIdentifier", "")).endswith(DUO_DEVICE_TYPE_SUFFIX)


def choose_existing_device(
    devices_by_runtime: dict[str, list[dict[str, Any]]],
    runtime: dict[str, Any],
    *,
    name: str | None = None,
    device_family: str = "iPhone",
) -> dict[str, Any] | None:
    devices = [
        device
        for device in devices_by_runtime.get(str(runtime["identifier"]), [])
        if is_available_device(device)
    ]
    if name is not None:
        devices = [device for device in devices if device.get("name") == name]
    # iOS 27.1 supports only the iPhone Duo form factor; CoreSimulator may even
    # name such devices "iPhone ..."/"iPad ...". Their portrait safe area
    # (382x644) cannot fit this project's 390x600 benchmarks and their single
    # orientation breaks rotation assertions, so they are never selected.
    standard = [device for device in devices if not is_duo_device(device)]
    if name is not None and devices and not standard:
        # Creating a same-named replacement would leave two simulators with
        # this name; make the caller pick a different one instead.
        raise DuoOnlyRuntimeError(
            f"Simulator {name!r} on {runtime.get('name', 'iOS')} is an iPhone Duo "
            "device, which cannot run this project's fixed 390x600 benchmarks. "
            "Delete it with `xcrun simctl delete` or pass a different --name."
        )
    devices = standard
    if not devices:
        return None

    # Callers rely on `None` here to create a correct-family device rather
    # than reuse a foreign one (e.g. `make build` must not pick an iPad when
    # only iPad simulators exist on the machine).
    family_devices = [
        device for device in devices if is_device_family(device, device_family)
    ]
    if not family_devices:
        return None
    return max(
        family_devices,
        key=lambda device: device_score(device, device_family),
    )


def is_iphone_device_type(device_type: dict[str, Any]) -> bool:
    name = str(device_type.get("name", ""))
    identifier = str(device_type.get("identifier", ""))
    return device_type.get("productFamily") == "iPhone" or name.startswith("iPhone") or ".iPhone-" in identifier


def is_ipad_device_type(device_type: dict[str, Any]) -> bool:
    name = str(device_type.get("name", ""))
    identifier = str(device_type.get("identifier", ""))
    return device_type.get("productFamily") == "iPad" or name.startswith("iPad") or ".iPad-" in identifier


def choose_device_type(
    runtime: dict[str, Any],
    device_types: list[dict[str, Any]],
    *,
    device_family: str = "iPhone",
) -> dict[str, Any]:
    supported_device_types = runtime.get("supportedDeviceTypes")
    candidates = supported_device_types if isinstance(supported_device_types, list) else device_types
    family_device_types = [
        device_type
        for device_type in candidates
        if device_type.get("identifier")
        and not is_duo_device_type(device_type)
        and (
            is_ipad_device_type(device_type)
            if device_family == "iPad"
            else is_iphone_device_type(device_type)
        )
    ]
    if not family_device_types:
        if any(is_duo_device_type(device_type) for device_type in candidates if isinstance(device_type, dict)):
            raise DuoOnlyRuntimeError(
                f"{runtime.get('name', 'iOS')} supports only the iPhone Duo form "
                "factor, whose safe area cannot fit this project's fixed 390x600 "
                "benchmarks. Install an iOS Simulator runtime with standard device "
                "types (for example iOS 27.0) in Xcode > Settings > Components; "
                "the resolver then selects it automatically."
            )
        raise RuntimeError(
            f"No {device_family} simulator device type found for "
            f"{runtime.get('name', 'iOS')}."
        )

    if device_family == "iPad":
        return max(
            family_device_types,
            key=lambda device_type: (
                ipad_variant_score(str(device_type.get("name", ""))),
                parse_version(str(device_type.get("name", ""))),
            ),
        )
    return family_device_types[0]


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


def erase_device(udid: str) -> None:
    subprocess.run(["xcrun", "simctl", "shutdown", udid], check=False, capture_output=True, text=True)
    subprocess.run(["xcrun", "simctl", "erase", udid], check=True, stdout=sys.stderr, stderr=sys.stderr, text=True)


def boot_device(udid: str) -> None:
    subprocess.run(["xcrun", "simctl", "boot", udid], check=False, capture_output=True, text=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, stdout=sys.stderr, stderr=sys.stderr, text=True)


def configure_keyboard(udid: str, name: str) -> None:
    """Disable hardware keyboard input on this booted dedicated test device only."""
    print(f"Disabling hardware keyboard for {name} ({udid}).", file=sys.stderr)
    try:
        # xcrun honors DEVELOPER_DIR, including when it names an Xcode app bundle.
        result = subprocess.run(
            ["xcrun", "--find", "simctl"],
            check=True, stdout=subprocess.PIPE, stderr=sys.stderr, text=True,
        )
        simctl = Path(result.stdout.strip())
        if not simctl.is_absolute() or simctl.parts[-3:] != ("usr", "bin", "simctl"):
            raise ValueError(f"xcrun returned an unexpected simctl path: {str(simctl)!r}")
        developer_dir = simctl.parents[2]
        source = Path(__file__).resolve().with_name("configure-ios-simulator-keyboard.m")
        # Compile a host-only helper afresh; never cache it or link it into the app.
        with tempfile.TemporaryDirectory(prefix="sshapp-simulator-keyboard-") as directory:
            helper = Path(directory) / "configure-ios-simulator-keyboard"
            subprocess.run(
                ["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-framework",
                 "Foundation", str(source), "-o", str(helper)],
                check=True, stdout=sys.stderr, stderr=sys.stderr, text=True,
            )
            subprocess.run(
                [str(helper), str(developer_dir), udid, name],
                check=True, stdout=sys.stderr, stderr=sys.stderr, text=True,
            )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise RuntimeError(
            f"Cannot configure the hardware keyboard for dedicated simulator {name!r} "
            f"({udid}); refusing to return an unconfigured destination. Check the "
            "diagnostics above and the selected Xcode (DEVELOPER_DIR / xcode-select); "
            "the host keyboard helper must support its CoreSimulator API before retrying. "
            f"Cause: {error}"
        ) from error


def resolve_udid(
    name: str = SIMULATOR_NAME,
    *,
    dedicated: bool = False,
    erase: bool = False,
    boot: bool = False,
    device_family: str = "iPhone",
    runtime_major: int | None = None,
) -> str:
    device_types = run_json("xcrun", "simctl", "list", "devicetypes", "--json").get("devicetypes") or []
    runtime = latest_ios_runtime(
        run_json("xcrun", "simctl", "list", "runtimes", "--json").get("runtimes") or [],
        major=runtime_major,
        device_family=device_family,
        device_types=device_types,
    )
    devices_by_runtime = run_json("xcrun", "simctl", "list", "devices", "--json").get("devices") or {}

    device = choose_existing_device(
        devices_by_runtime,
        runtime,
        name=name if dedicated else None,
        device_family=device_family,
    )
    if device:
        print(
            f"Using {device.get('name')} on {runtime.get('name')} ({device['udid']}).",
            file=sys.stderr,
        )
        udid = str(device["udid"])
    else:
        device_type = choose_device_type(
            runtime,
            device_types,
            device_family=device_family,
        )
        udid = create_device(runtime, device_type, name=name)
        print(
            f"Created {name} as {device_type.get('name')} on {runtime.get('name')} ({udid}).",
            file=sys.stderr,
        )

    if erase:
        print(f"Erasing {name} ({udid}).", file=sys.stderr)
        erase_device(udid)
    if boot:
        print(f"Booting {name} ({udid}).", file=sys.stderr)
        boot_device(udid)
        if dedicated:
            configure_keyboard(udid, name)
    return udid


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default=SIMULATOR_NAME, help="name to use when creating a simulator")
    parser.add_argument("--dedicated", action="store_true", help="reuse or create only a simulator with --name")
    parser.add_argument("--erase", action="store_true", help="erase the resolved simulator before printing it")
    parser.add_argument("--boot", action="store_true", help="boot the resolved simulator and wait until boot completes")
    parser.add_argument("--udid-only", action="store_true", help="print only the resolved simulator UDID")
    parser.add_argument(
        "--device-family",
        choices=("iPhone", "iPad"),
        default="iPhone",
        help="simulator device family to select or create",
    )
    parser.add_argument(
        "--runtime-major", type=int, default=os.environ.get("IOS_SIMULATOR_RUNTIME_MAJOR"),
        help="require an iOS major version (defaults to IOS_SIMULATOR_RUNTIME_MAJOR, otherwise newest)",
    )
    args = parser.parse_args()

    if args.erase and not args.dedicated:
        parser.error("--erase requires --dedicated so arbitrary developer simulators are not erased")

    udid = resolve_udid(
        name=args.name,
        dedicated=args.dedicated,
        erase=args.erase,
        boot=args.boot,
        device_family=args.device_family,
        runtime_major=args.runtime_major,
    )
    if args.udid_only:
        print(udid)
    else:
        print(f"platform=iOS Simulator,id={udid}")


if __name__ == "__main__":
    main()
