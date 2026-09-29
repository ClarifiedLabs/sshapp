#!/usr/bin/env python3
"""Regression checks for generic iOS Simulator destination resolution."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import subprocess
from unittest.mock import patch

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


def test_required_runtime_major(resolver) -> None:
    runtimes = [
        {"identifier": f"com.apple.CoreSimulator.SimRuntime.iOS-{version.replace('.', '-')}",
         "platform": "iOS", "version": version, "isAvailable": available}
        for version, available in [("18.6", True), ("26.5", True), ("27.0", True), ("27.1", False), ("28.0", True)]
    ]
    require(resolver.latest_ios_runtime(runtimes, major=27)["version"] == "27.0",
            "CI must select the requested major, ignoring older/newer and unavailable runtimes")
    try:
        resolver.latest_ios_runtime(runtimes, major=25)
    except RuntimeError as error:
        require("iOS 25" in str(error), "missing runtime diagnostic must identify the requested major")
    else:
        raise AssertionError("Must not silently fall back when a required runtime is unavailable")


def test_runtime_must_support_requested_family(resolver) -> None:
    iphone = {"identifier": "iPhone-18-Pro", "productFamily": "iPhone"}
    ipad = {"identifier": "iPad-Pro", "productFamily": "iPad"}
    runtimes = [
        {"identifier": "iOS-27-1", "platform": "iOS", "version": "27.1",
         "supportedDeviceTypes": [iphone]},
        {"identifier": "iOS-27-0", "platform": "iOS", "version": "27.0",
         "supportedDeviceTypes": [iphone, ipad]},
    ]
    require(resolver.latest_ios_runtime(runtimes, device_family="iPad")["version"] == "27.0",
            "iPad runs must skip newer runtimes that only support iPhone")
    require(resolver.latest_ios_runtime(runtimes, device_family="iPhone")["version"] == "27.1",
            "iPhone runs must still choose the newest supported runtime")
    try:
        resolver.latest_ios_runtime(runtimes[:1], major=27, device_family="iPad")
    except RuntimeError as error:
        require("iOS 27" in str(error) and "iPad" in str(error),
                "missing runtime diagnostic must include version and family")
    else:
        raise AssertionError("Must reject a runtime without the requested family")


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


def test_non_dedicated_device_family(resolver) -> None:
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
            ]
        },
        runtime,
    )

    require(
        device is None,
        "non-dedicated resolution must not reuse a foreign device family; "
        "returning None lets the caller create an iPhone instead",
    )


def test_dedicated_device_selection(resolver) -> None:
    runtime = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"}
    device = resolver.choose_existing_device(
        {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {
                    "name": "iPhone 17 Pro",
                    "udid": "GENERAL-IPHONE-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    "state": "Shutdown",
                },
                {
                    "name": "SSHApp UI Tests",
                    "udid": "DEDICATED-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    "state": "Shutdown",
                },
            ]
        },
        runtime,
        name="SSHApp UI Tests",
    )

    require(
        device is not None and device["udid"] == "DEDICATED-UDID",
        "resolver must support selecting a dedicated named simulator",
    )

    wrong_family = resolver.choose_existing_device(
        {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {
                    "name": "SSHApp Live SSH Smoke",
                    "udid": "DEDICATED-IPHONE-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    "state": "Shutdown",
                },
            ]
        },
        runtime,
        name="SSHApp Live SSH Smoke",
        device_family="iPad",
    )
    require(
        wrong_family is None,
        "resolver must not reuse a dedicated simulator from the wrong device family",
    )


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

    ipad_device_type = resolver.choose_device_type(
        {
            "name": "iOS 26.5",
            "supportedDeviceTypes": [
                {
                    "name": "iPad Air 13-inch (M4)",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-13-inch-M4",
                    "productFamily": "iPad",
                },
                {
                    "name": "iPad Pro 13-inch (M5)",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5",
                    "productFamily": "iPad",
                },
                {
                    "name": "iPhone 17",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
                    "productFamily": "iPhone",
                },
            ],
        },
        [],
        device_family="iPad",
    )
    require(
        ipad_device_type["identifier"]
        == "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5",
        "resolver must prefer a 13-inch iPad Pro for live SSH tests",
    )


def test_bootstatus_output_stays_off_stdout(resolver) -> None:
    calls = []
    original_run = resolver.subprocess.run

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))

        class Result:
            stdout = ""

        return Result()

    resolver.subprocess.run = fake_run
    try:
        resolver.boot_device("BOOT-UDID")
    finally:
        resolver.subprocess.run = original_run

    bootstatus = [call for call in calls if call[0][:3] == ["xcrun", "simctl", "bootstatus"]]
    require(bootstatus, "boot_device must wait for simctl bootstatus")
    require(
        bootstatus[0][1].get("stdout") is resolver.sys.stderr,
        "bootstatus progress must not contaminate --udid-only stdout",
    )


def test_ci_and_makefile_use_resolver() -> None:
    workflow = read(REPO_ROOT / ".github/workflows/test-ios.yml")
    makefile = read(REPO_ROOT / "Makefile")
    runner = read(REPO_ROOT / "scripts" / "run-ios-tests.sh")

    require_contains(workflow, "./scripts/run-ios-tests.sh all", "test-ios.yml")
    require_contains(workflow, "TEST_SIMULATOR_NAME: SSHApp CI Tests", "test-ios.yml")
    require_contains(workflow, "UNIT_SIMULATOR_NAME: SSHApp CI Unit Tests", "test-ios.yml")
    require_contains(workflow, "UI_SIMULATOR_NAME: SSHApp CI UI Tests", "test-ios.yml")
    require_contains(makefile, "./scripts/run-ios-tests.sh all", "Makefile")
    require_contains(makefile, "./scripts/run-ios-tests.sh unit", "Makefile")
    require_contains(makefile, "./scripts/run-ios-tests.sh ui", "Makefile")
    require_contains(runner, "python3 ./scripts/resolve-ios-simulator.py", "run-ios-tests.sh")
    require_contains(runner, "TEST_SIMULATOR_NAME", "run-ios-tests.sh")
    require_contains(runner, "UNIT_SIMULATOR_NAME", "run-ios-tests.sh")
    require_contains(runner, "resolve_unit_destination", "run-ios-tests.sh")
    require_contains(runner, "resolve_dedicated_destination \"$UNIT_SIMULATOR_NAME\"", "run-ios-tests.sh")
    require_contains(runner, "${result_prefix}-attempt-${attempt}.xcresult", "run-ios-tests.sh")
    require_contains(runner, "--dedicated", "run-ios-tests.sh")
    require_contains(runner, "--erase", "run-ios-tests.sh")
    require_contains(runner, "--boot", "run-ios-tests.sh")
    require_absent(runner, "unit-tests.xcresult", "run-ios-tests.sh")

    for context, text in (("test-ios.yml", workflow), ("Makefile", makefile), ("run-ios-tests.sh", runner)):
        require_absent(text, "iPhone 17 Pro", context)
        require_absent(text, "platform=iOS Simulator,name=", context)


def test_duo_devices_are_never_implicitly_selected(resolver) -> None:
    runtime = {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1"}
    # iOS 27.1 names Duo devices like standard iPhones/iPads, so the guard must
    # inspect the device type, not the display name.
    device = resolver.choose_existing_device(
        {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                {
                    "name": "iPhone 18 Pro",
                    "udid": "DUO-AS-IPHONE-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                    "state": "Shutdown",
                },
                {
                    "name": "iPad Pro 13-inch (M5)",
                    "udid": "DUO-AS-IPAD-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                    "state": "Shutdown",
                },
            ]
        },
        runtime,
        device_family="iPad",
    )
    require(device is None, "Duo devices named like iPads must not be selected")

    try:
        resolver.choose_existing_device(
            {
                "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                    {
                        "name": "iPhone 18 Pro",
                        "udid": "DUO-AS-IPHONE-UDID",
                        "isAvailable": True,
                        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                        "state": "Shutdown",
                    }
                ]
            },
            runtime,
            name="iPhone 18 Pro",
        )
    except resolver.DuoOnlyRuntimeError as error:
        require("iPhone 18 Pro" in str(error) and "--name" in str(error),
                "a named Duo device must fail with a remedy, not create a same-named duplicate")
    else:
        raise AssertionError("A dedicated name matching only a Duo device must not be silently replaced")

    general = resolver.choose_existing_device(
        {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
                {
                    "name": "iPhone 18 Pro",
                    "udid": "DUO-AS-IPHONE-UDID",
                    "isAvailable": True,
                    "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
                    "state": "Shutdown",
                }
            ]
        },
        runtime,
    )
    require(general is None, "non-dedicated resolution must also skip Duo devices")

    assert resolver.is_duo_device(
        {"deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}
    ), "is_duo_device must recognize the Duo device type identifier"
    assert not resolver.is_duo_device(
        {"deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"}
    ), "is_duo_device must not match standard iPhone device types"


def test_duo_only_runtime_fails_closed(resolver) -> None:
    runtime = {
        "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
        "name": "iOS 27.1",
        # Only the Duo device type is compatible with this runtime, matching the
        # observed xcrun behavior for iOS 27.1.
        "supportedDeviceTypes": [
            {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "name": "iPhone Duo"}
        ],
    }
    device_types = [
        {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "name": "iPhone Duo"},
        {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "name": "iPhone 18 Pro"},
    ]
    original_run_json = resolver.run_json
    try:
        # Drive resolve_udid with stubbed simctl listings; runtime selection
        # refuses the Duo-only runtime before any device is created.
        resolver.run_json = lambda *command: (
            {"devicetypes": device_types}
            if command[2:4] == ("list", "devicetypes")
            else {"runtimes": [runtime]}
            if command[2:4] == ("list", "runtimes")
            else {"devices": {runtime["identifier"]: []}}
        )
        try:
            resolver.resolve_udid(name="SSHApp CI", dedicated=True)
        except resolver.DuoOnlyRuntimeError as error:
            require("iPhone Duo" in str(error) and "Install an iOS Simulator runtime" in str(error),
                    "a Duo-only runtime must explain the failure and an actionable remedy")
            require(isinstance(error, RuntimeError),
                    "DuoOnlyRuntimeError must stay a RuntimeError for existing callers")
        else:
            raise AssertionError("Must not silently create a Duo device for benchmark workloads")
    finally:
        resolver.run_json = original_run_json


KEYBOARD_TEST_UDID = "11111111-2222-3333-4444-555555555555"
KEYBOARD_TEST_NAME = "SSHApp Keyboard Tests"
SELECTED_DEVELOPER_DIR = "/Volumes/CI Tools/Xcode Beta.app/Contents/Developer"


def keyboard_simulator_listing(*command):
    device_type = {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "name": "iPhone 18 Pro"}
    runtime = {"identifier": "iOS-27-0", "platform": "iOS", "version": "27.0", "name": "iOS 27.0"}
    return {
        "devicetypes": {"devicetypes": [device_type]},
        "runtimes": {"runtimes": [runtime]},
        "devices": {"devices": {runtime["identifier"]: [
            {"name": KEYBOARD_TEST_NAME, "udid": KEYBOARD_TEST_UDID,
             "deviceTypeIdentifier": device_type["identifier"], "state": "Shutdown"},
        ]}},
    }[command[3]]


def test_keyboard_setup_follows_dedicated_boot(resolver) -> None:
    for erase in (False, True):
        for created in (False, True):
            events = []

            def listing(*command):
                if created and command[3] == "devices":
                    return {"devices": {}}
                return keyboard_simulator_listing(*command)

            with patch.object(resolver, "run_json", side_effect=listing), \
                 patch.object(resolver, "create_device", side_effect=lambda *args, **kwargs: events.append("create") or KEYBOARD_TEST_UDID), \
                 patch.object(resolver, "erase_device", side_effect=lambda udid: events.append(("erase", udid))), \
                 patch.object(resolver, "boot_device", side_effect=lambda udid: events.append(("boot", udid))), \
                 patch.object(resolver, "configure_keyboard", side_effect=lambda udid, name: events.append(("keyboard", udid, name))), \
                 redirect_stderr(io.StringIO()):
                udid = resolver.resolve_udid(name=KEYBOARD_TEST_NAME, dedicated=True, erase=erase, boot=True)
            expected = (["create"] if created else []) + ([("erase", KEYBOARD_TEST_UDID)] if erase else [])
            expected += [("boot", KEYBOARD_TEST_UDID), ("keyboard", KEYBOARD_TEST_UDID, KEYBOARD_TEST_NAME)]
            require(events == expected and udid == KEYBOARD_TEST_UDID,
                    "existing and newly created dedicated devices must configure the exact target after boot, with or without erase")


def test_keyboard_setup_is_dedicated_boot_only(resolver) -> None:
    for dedicated, boot in ((False, False), (False, True), (True, False)):
        with patch.object(resolver, "run_json", side_effect=keyboard_simulator_listing), \
             patch.object(resolver, "boot_device") as boot_device, \
             patch.object(resolver, "configure_keyboard") as configure, \
             patch.object(resolver.subprocess, "run") as host_command, \
             redirect_stderr(io.StringIO()):
            resolver.resolve_udid(name=KEYBOARD_TEST_NAME, dedicated=dedicated, boot=boot)
        require(boot_device.call_count == int(boot), "non-dedicated boot behavior must remain unchanged")
        configure.assert_not_called()
        host_command.assert_not_called()


def test_failed_boot_does_not_configure_keyboard(resolver) -> None:
    with patch.object(resolver, "run_json", side_effect=keyboard_simulator_listing), \
         patch.object(resolver, "boot_device", side_effect=RuntimeError("boot failed")), \
         patch.object(resolver, "configure_keyboard") as configure, \
         redirect_stderr(io.StringIO()):
        try:
            resolver.resolve_udid(name=KEYBOARD_TEST_NAME, dedicated=True, boot=True)
        except RuntimeError as error:
            require(str(error) == "boot failed", "boot errors must propagate")
        else:
            raise AssertionError("A failed boot must not resolve a destination")
    configure.assert_not_called()


def mock_keyboard_commands(calls):
    def run(command, **kwargs):
        calls.append((command, kwargs))
        if command == ["xcrun", "--find", "simctl"]:
            return subprocess.CompletedProcess(command, 0, stdout=f"{SELECTED_DEVELOPER_DIR}/usr/bin/simctl\n")
        print("mock host compiler/helper diagnostic", file=kwargs["stdout"])
        if command[:4] == ["xcrun", "--sdk", "macosx", "clang"]:
            Path(command[-1]).write_text("mock binary", encoding="utf-8")
        return subprocess.CompletedProcess(command, 0)
    return run


def test_keyboard_helper_uses_selected_xcode_and_cleans_up(resolver) -> None:
    calls = []
    stdout, stderr = io.StringIO(), io.StringIO()
    with patch.dict(resolver.os.environ, {"DEVELOPER_DIR": SELECTED_DEVELOPER_DIR}), \
         patch.object(resolver.subprocess, "run", side_effect=mock_keyboard_commands(calls)), \
         redirect_stdout(stdout), redirect_stderr(stderr):
        resolver.configure_keyboard(KEYBOARD_TEST_UDID, KEYBOARD_TEST_NAME)
    require(len(calls) == 3, "keyboard setup must discover selected simctl, compile, then invoke once")
    require(calls[0][0] == ["xcrun", "--find", "simctl"], "selected Xcode must be discovered through xcrun")
    helper = calls[1][0][-1]
    require(calls[1][0] == [
        "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-framework", "Foundation",
        str(REPO_ROOT / "scripts/configure-ios-simulator-keyboard.m"), "-o", helper,
    ], "compile only a temporary Foundation host helper using selected xcrun")
    require(calls[2][0] == [helper, SELECTED_DEVELOPER_DIR, KEYBOARD_TEST_UDID, KEYBOARD_TEST_NAME],
            "helper must receive exact selected developer directory, UDID and expected name as separate arguments")
    for _, kwargs in calls:
        require(kwargs.get("check") is True and "env" not in kwargs,
                "all host commands must propagate failure and inherit DEVELOPER_DIR")
        require(kwargs.get("stderr") is stderr, "host diagnostics must stay on stderr")
    require(calls[0][1].get("stdout") is subprocess.PIPE,
            "simctl path discovery must not leak to resolver stdout")
    require(all(kwargs.get("stdout") is stderr for _, kwargs in calls[1:]),
            "compiler and helper stdout must be redirected to stderr")
    require(stdout.getvalue() == "" and "mock host compiler/helper diagnostic" in stderr.getvalue(),
            "keyboard setup must not contaminate --udid-only output")
    require(not Path(helper).parent.exists(), "temporary helper and its directory must be removed")


def test_keyboard_command_failures_stop_resolution(resolver) -> None:
    for failed_command in range(3):
        calls = []
        successful_run = mock_keyboard_commands(calls)

        def failing_run(command, **kwargs):
            if len(calls) == failed_command:
                calls.append((command, kwargs))
                raise subprocess.CalledProcessError(1, command)
            return successful_run(command, **kwargs)

        stdout = io.StringIO()
        with patch.object(resolver, "run_json", side_effect=keyboard_simulator_listing), \
             patch.object(resolver, "boot_device"), \
             patch.object(resolver.subprocess, "run", side_effect=failing_run), \
             patch.object(resolver.sys, "argv", ["resolver", "--name", KEYBOARD_TEST_NAME, "--dedicated", "--boot", "--udid-only"]), \
             redirect_stdout(stdout), redirect_stderr(io.StringIO()):
            try:
                resolver.main()
            except RuntimeError as error:
                require(KEYBOARD_TEST_UDID in str(error) and "refusing" in str(error) and "DEVELOPER_DIR" in str(error),
                        "configuration failures must identify the device and explain how to diagnose selected Xcode")
            else:
                raise AssertionError("Discovery, compile and configuration failures must all stop resolution")
        require(len(calls) == failed_command + 1, "a failed host command must stop subsequent commands")
        require(stdout.getvalue() == "", "failed configuration must not print a usable destination")
        if failed_command >= 1:
            require(not Path(calls[1][0][-1]).parent.exists(), "failure must also clean up the temporary helper")


def test_keyboard_rejects_unexpected_simctl_path(resolver) -> None:
    for path in ("", "usr/bin/simctl", "/usr/local/bin/simctl", "/selected/Xcode/simctl"):
        with patch.object(resolver.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=path)) as run, \
             redirect_stderr(io.StringIO()):
            try:
                resolver.configure_keyboard(KEYBOARD_TEST_UDID, KEYBOARD_TEST_NAME)
            except RuntimeError as error:
                require("unexpected simctl path" in str(error), "invalid discovery output must have an actionable error")
            else:
                raise AssertionError("Must not guess developer directory from unexpected simctl output")
        require(run.call_count == 1, "invalid selected Xcode path must fail before compiling or invoking helper")


def test_keyboard_cli_stdout_is_only_destination(resolver) -> None:
    for udid_only in (False, True):
        calls = []
        stdout = io.StringIO()
        argv = ["resolver", "--name", KEYBOARD_TEST_NAME, "--dedicated", "--boot"]
        if udid_only:
            argv.append("--udid-only")
        with patch.object(resolver, "run_json", side_effect=keyboard_simulator_listing), \
             patch.object(resolver, "boot_device"), \
             patch.object(resolver.subprocess, "run", side_effect=mock_keyboard_commands(calls)), \
             patch.object(resolver.sys, "argv", argv), \
             redirect_stdout(stdout), redirect_stderr(io.StringIO()):
            resolver.main()
        expected = KEYBOARD_TEST_UDID if udid_only else f"platform=iOS Simulator,id={KEYBOARD_TEST_UDID}"
        require(stdout.getvalue() == expected + "\n", "successful keyboard setup must leave resolver stdout machine-readable")


def main() -> None:
    resolver = load_resolver()
    test_runtime_selection(resolver)
    test_required_runtime_major(resolver)
    test_runtime_must_support_requested_family(resolver)
    test_existing_device_selection(resolver)
    test_non_dedicated_device_family(resolver)
    test_dedicated_device_selection(resolver)
    test_device_type_selection(resolver)
    test_duo_devices_are_never_implicitly_selected(resolver)
    test_duo_only_runtime_fails_closed(resolver)
    test_bootstatus_output_stays_off_stdout(resolver)
    test_ci_and_makefile_use_resolver()
    test_keyboard_setup_follows_dedicated_boot(resolver)
    test_keyboard_setup_is_dedicated_boot_only(resolver)
    test_failed_boot_does_not_configure_keyboard(resolver)
    test_keyboard_helper_uses_selected_xcode_and_cleans_up(resolver)
    test_keyboard_command_failures_stop_resolution(resolver)
    test_keyboard_rejects_unexpected_simctl_path(resolver)
    test_keyboard_cli_stdout_is_only_destination(resolver)
    print("Passed 18 simulator resolution checks (including mocked keyboard setup).")


if __name__ == "__main__":
    main()
