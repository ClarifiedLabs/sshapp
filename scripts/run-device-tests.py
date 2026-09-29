#!/usr/bin/env python3
"""Run SSH App tests on an explicitly selected physical device, in an isolated app."""
import json
import os
from pathlib import Path
import plistlib
import queue
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime
from uuid import uuid4

ROOT = Path(__file__).resolve().parent.parent
CONFIG = runpy.run_path(str(ROOT / "scripts/configure-live-ssh-xctestrun.py"))

# iPadOS SpringBoard can crash or wedge behind a permanent black overlay
# mid-run (see docs/DEVELOPMENT.md); xcodebuild then waits indefinitely. Stop
# it instead of stalling for hours.
DEVICE_HUNG_STATUS = 75
# "Device UI is wedged" is SSHAppUITests/Support/UITestDeviceHealth.swift's
# failure once the app window stays unhittable or AX reports kAXErrorServerNotFound.
# XCTest logs "Interface orientation changed to Unknown" when SpringBoard
# respawned under the runner (the FBSDisplayMonitor crash); later tests only
# launch into the restarting SpringBoard.
HUNG_OUTPUT = (re.compile(r"Unlock .+ to Continue"), re.compile(r"[Dd]estination is not ready"),
               re.compile(r"Device UI is wedged"), re.compile(r"Interface orientation changed to Unknown"))
# XCTest's default per-test screen recording hot-plugs a virtual AirPlay display
# for every UI-target test. Short tests plug/unplug it every 10-30 ms, and iPadOS
# 27 SpringBoard crashed ("Not tracking hardware for display AirPlay[...]").
# Device runs capture screenshots instead; the xctestrun value for the test
# plan's "video" is "screenRecording".
SCREEN_CAPTURE_FORMAT_KEY = "PreferredScreenCaptureFormat"
DEVICE_SCREEN_CAPTURE_FORMAT = "screenshots"
# A wedged SpringBoard leaves the app window "hittable" while every element in
# it resolves to hit point {-1, -1}; XCTest only logs this and taps nothing.
# Healthy runs have never logged it, so a few occurrences mean the device UI is gone.
DEAD_HIT_POINT = re.compile(r"Computed hit point \{-1, -1\}")
DEAD_HIT_POINT_LIMIT = 3
UI_TEST_RUN_ID_KEY = "SSHAPP_UI_TEST_RUN_ID"
RUNNER_RESTART = "Restarting after unexpected exit"
TEST_PROGRESS = re.compile(r"Test Case '.+' (started|passed|failed|skipped)")
DEFAULT_IDLE_TIMEOUT = 20 * 60

def require_unlocked_device(device):
    """Fail closed instead of letting Xcode wait indefinitely at its unlock prompt."""
    try:
        result = subprocess.run(
            ["xcrun", "devicectl", "device", "info", "lockState", "--device", device,
             "--timeout", "15", "--quiet", "--json-output", "-"],
            capture_output=True, text=True, timeout=20, check=True)
        document = json.loads(result.stdout)
        if not isinstance(document, dict) or not isinstance(document.get("info"), dict):
            raise ValueError("invalid lock-state response")
        if document["info"].get("outcome") != "success":
            raise ValueError("lock-state query did not succeed")
        state = document["result"]
        if not isinstance(state, dict):
            raise ValueError("invalid lock-state result")
        if state.get("passcodeRequired") is not False or state.get("unlockedSinceBoot") is not True:
            raise RuntimeError(f"Unlock device {device} before running physical tests; no tests were launched.")
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError) as error:
        raise RuntimeError(f"Cannot verify that device {device} is unlocked: {error}") from error


def run_watched(command, cwd, env, idle_timeout=DEFAULT_IDLE_TIMEOUT, clock=time.monotonic):
    """Stream xcodebuild output; stop it if the device appears hung."""
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1)
    lines = queue.Queue()

    def read():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    threading.Thread(target=read, daemon=True).start()
    last_progress, restarts, dead_hit_points, reason = clock(), 0, 0, None
    while reason is None:
        try:
            line = lines.get(timeout=5)
        except queue.Empty:
            line = ""
        if line is None:
            return process.wait()
        if line:
            sys.stdout.write(line)
            sys.stdout.flush()
            if TEST_PROGRESS.search(line):
                last_progress = clock()
            if any(pattern.search(line) for pattern in HUNG_OUTPUT):
                reason = line.strip()
            elif RUNNER_RESTART in line:
                restarts += 1
                if restarts >= 2:
                    reason = "test runner restarted twice"
            elif DEAD_HIT_POINT.search(line):
                dead_hit_points += 1
                if dead_hit_points >= DEAD_HIT_POINT_LIMIT:
                    reason = f"XCTest computed hit point {{-1, -1}} {dead_hit_points} times (Device UI is wedged)"
        if reason is None and clock() - last_progress > idle_timeout:
            reason = f"no test progress for {idle_timeout} seconds"
    process.terminate()
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    print(f"Device likely hung ({reason}); stopped xcodebuild. Capture a sysdiagnose "
          "before restarting the device.", file=sys.stderr, flush=True)
    return DEVICE_HUNG_STATUS


def configure_ui_test_run_id(document, run_id):
    """Scope the UI runner's wedged-device marker to this run, across runner restarts."""
    count = 0
    for configuration in document.get("TestConfigurations", []):
        for target in configuration.get("TestTargets", []):
            if target.get("BlueprintName") == "SSHAppUITests":
                target.setdefault("EnvironmentVariables", {})[UI_TEST_RUN_ID_KEY] = run_id
                count += 1
    return count


def configure_screen_capture(document, capture_format=DEVICE_SCREEN_CAPTURE_FORMAT):
    """Sets every test target's automatic screen capture format; returns the target count."""
    count = 0
    for configuration in document.get("TestConfigurations", []):
        for target in configuration.get("TestTargets", []):
            target[SCREEN_CAPTURE_FORMAT_KEY] = capture_format
            count += 1
    if not count:
        raise ValueError("No test targets found for the screen capture format")
    return count


def configure_metal_validation(document):
    """Opt-in API validation for app-hosted tests, never performance baselines."""
    count = 0
    for configuration in document.get("TestConfigurations", []):
        for target in configuration.get("TestTargets", []):
            if target.get("BlueprintName") == "SSHAppTests":
                target.setdefault("EnvironmentVariables", {})["MTL_DEBUG_LAYER"] = "1"
                count += 1
    if not count:
        raise ValueError("No app-hosted test target found for Metal API validation")
    return count


def main():
    device = os.environ.get("DEVICE_UDID", "").strip()
    if not device:
        print("Set DEVICE_UDID to the physical device UDID from xcrun devicectl list devices.", file=sys.stderr)
        return 2
    if any(not arg.startswith("-only-testing:") for arg in sys.argv[1:]):
        print("Optional arguments must be -only-testing:<target>/<suite>/<test> filters.", file=sys.stderr)
        return 2

    validation = os.environ.get("SSHAPP_METAL_VALIDATION", "0")
    if validation not in {"0", "1"}:
        print("SSHAPP_METAL_VALIDATION must be 0 or 1.", file=sys.stderr)
        return 2

    configuration = os.environ.get("DEVICE_BUILD_CONFIGURATION", "Debug")
    if configuration not in {"Debug", "Release"}:
        print("DEVICE_BUILD_CONFIGURATION must be Debug or Release.", file=sys.stderr)
        return 2

    derived = (ROOT / os.environ.get("DEVICE_DERIVED_DATA_PATH", ".build/device-tests")).resolve()
    packages = (ROOT / ".build/ci/xcode-source-packages").resolve()
    # Independent devices can start in the same second. Never share a result
    # bundle (especially when a live run deletes its sensitive artifacts).
    results = ROOT / ".build/ci/xcresults" / (datetime.now().strftime("device-%Y%m%d-%H%M%S-") + uuid4().hex + ".xcresult")
    results.parent.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    live = bool(environment.get("SSHAPP_LIVE_SSH_DESTINATION"))
    credentials = CONFIG["configured_environment"](environment) if live else {}
    for key in CONFIG["ENVIRONMENT_KEYS"]:
        environment.pop(key, None)

    destination = f"platform=iOS,id={device}"
    xcodebuild = os.environ.get("XCODEBUILD", "xcodebuild")
    build = [xcodebuild, "build-for-testing", "-project", "SSHApp.xcodeproj",
             "-scheme", "SSHApp", "-testPlan", "SSHAppAllTests",
             "-configuration", configuration, "ENABLE_TESTABILITY=YES",
             # Test seams are compiled out of App Store builds; Release test runs opt in.
             "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) VT_TEST_HOOKS",
             "GCC_PREPROCESSOR_DEFINITIONS=$(inherited) VT_TEST_HOOKS=1",
             "-destination", destination, "-derivedDataPath", str(derived),
             "-clonedSourcePackagesDirPath", str(packages),
             "-skipPackagePluginValidation", "-skipMacroValidation",
             "-hideShellScriptEnvironment", "-allowProvisioningUpdates",
             "PRODUCT_BUNDLE_IDENTIFIER=dev.sshapp.devicetests.$(PRODUCT_NAME:rfc1034identifier)",
             "DEVELOPMENT_TEAM=" + os.environ.get("DEVICE_DEVELOPMENT_TEAM", "M6P3423NZS")]
    status = subprocess.call(build, cwd=ROOT, env=environment)
    if status:
        return status
    products = derived / "Build/Products"
    candidates = list(products.glob("SSHApp_SSHAppAllTests_iphoneos*.xctestrun"))
    if len(candidates) != 1:
        print(f"Expected one device test configuration, found {len(candidates)}.", file=sys.stderr)
        return 2

    # Query after the build: a device can auto-lock while compilation runs.
    try:
        require_unlocked_device(device)
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="sshapp-device-tests-") as temporary:
        configured = Path(temporary) / "device.xctestrun"
        document = plistlib.loads(candidates[0].read_bytes())
        CONFIG["substitute_test_root"](document, str(products))
        configure_screen_capture(document)
        configure_ui_test_run_id(document, uuid4().hex)
        if validation == "1":
            count = configure_metal_validation(document)
            print(f"Configured {count} app-hosted test targets for Metal API validation (not performance evidence)", flush=True)
        if live:
            if CONFIG["configure_xctestrun"](document, credentials) != 1:
                raise ValueError("Expected one UI-test target for live SSH settings")
        configured.touch(mode=0o600)
        configured.write_bytes(plistlib.dumps(document))
        # Live test artifacts can contain the test environment and screen contents.
        # Keep them only when explicitly requested; always delete the config copy.
        try:
            idle_timeout = int(os.environ.get("DEVICE_TEST_IDLE_TIMEOUT", DEFAULT_IDLE_TIMEOUT))
            status = run_watched(
                [xcodebuild, "test-without-building", "-xctestrun", str(configured),
                 "-destination", destination, "-parallel-testing-enabled", "NO",
                 "-resultBundlePath", str(results), *sys.argv[1:]], cwd=ROOT, env=environment,
                idle_timeout=idle_timeout)
        finally:
            if live and os.environ.get("SSHAPP_LIVE_SSH_KEEP_RESULTS") != "1" and results.exists():
                shutil.rmtree(results)
    if results.exists():
        print(f"Device test results: {results}")
    print(f"Device test exit status: {status}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
