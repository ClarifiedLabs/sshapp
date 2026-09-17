#!/usr/bin/env python3
"""Run SSH App tests on an explicitly selected physical device, in an isolated app."""
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent
CONFIG = runpy.run_path(str(ROOT / "scripts/configure-live-ssh-xctestrun.py"))


def main():
    device = os.environ.get("DEVICE_UDID", "").strip()
    if not device:
        print("Set DEVICE_UDID to the physical device UDID from xcrun devicectl list devices.", file=sys.stderr)
        return 2
    if any(not arg.startswith("-only-testing:") for arg in sys.argv[1:]):
        print("Optional arguments must be -only-testing:<target>/<suite>/<test> filters.", file=sys.stderr)
        return 2

    derived = (ROOT / os.environ.get("DEVICE_DERIVED_DATA_PATH", ".build/device-tests")).resolve()
    packages = (ROOT / ".build/ci/xcode-source-packages").resolve()
    results = ROOT / ".build/ci/xcresults" / datetime.now().strftime("device-%Y%m%d-%H%M%S.xcresult")
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

    with tempfile.TemporaryDirectory(prefix="sshapp-device-tests-") as temporary:
        configured = Path(temporary) / "device.xctestrun"
        document = plistlib.loads(candidates[0].read_bytes())
        CONFIG["substitute_test_root"](document, str(products))
        if live:
            if CONFIG["configure_xctestrun"](document, credentials) != 1:
                raise ValueError("Expected one UI-test target for live SSH settings")
        configured.touch(mode=0o600)
        configured.write_bytes(plistlib.dumps(document))
        # Live test artifacts can contain the test environment and screen contents.
        # Keep them only when explicitly requested; always delete the config copy.
        try:
            status = subprocess.call(
                [xcodebuild, "test-without-building", "-xctestrun", str(configured),
                 "-destination", destination, "-parallel-testing-enabled", "NO",
                 "-resultBundlePath", str(results), *sys.argv[1:]], cwd=ROOT, env=environment)
        finally:
            if live and os.environ.get("SSHAPP_LIVE_SSH_KEEP_RESULTS") != "1" and results.exists():
                shutil.rmtree(results)
    if results.exists():
        print(f"Device test results: {results}")
    print(f"Device test exit status: {status}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
