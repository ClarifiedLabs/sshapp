#!/usr/bin/env python3
"""Device-runner isolation, credential handling, and failure propagation."""
import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("device_runner", ROOT / "scripts/run-device-tests.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class DeviceRunnerTests(unittest.TestCase):
    def test_requires_an_explicit_device(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(runner.subprocess, "call") as call:
            self.assertEqual(runner.main(), 2)
            call.assert_not_called()

    def test_isolates_app_and_cloud_and_removes_credentials_on_test_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = []
            temporary_configs = []

            def invoke(command, **kwargs):
                calls.append(command)
                self.assertNotIn("SSHAPP_LIVE_SSH_PASSWORD", kwargs["env"])
                self.assertNotIn("test-password", " ".join(command))
                if command[1] == "build-for-testing":
                    self.assertIn("PRODUCT_BUNDLE_IDENTIFIER=dev.sshapp.devicetests.$(PRODUCT_NAME:rfc1034identifier)", command)
                    self.assertFalse(any(c.startswith("CODE_SIGN_ENTITLEMENTS=") for c in command))
                    products = root / ".build/device-tests/Build/Products"
                    products.mkdir(parents=True)
                    config = {"TestConfigurations": [{"TestTargets": [{
                        "BlueprintName": "SSHAppUITests", "TestBundlePath": "__TESTROOT__/tests.xctest"
                    }]}]}
                    (products / "SSHApp_SSHAppAllTests_iphoneos27.0-arm64.xctestrun").write_bytes(plistlib.dumps(config))
                    return 0
                temporary = Path(command[command.index("-xctestrun") + 1])
                temporary_configs.append(temporary)
                self.assertEqual(temporary.stat().st_mode & 0o777, 0o600)
                config = plistlib.loads(temporary.read_bytes())
                target = config["TestConfigurations"][0]["TestTargets"][0]
                self.assertEqual(target["EnvironmentVariables"]["SSHAPP_LIVE_SSH_PASSWORD"], "test-password")
                self.assertNotIn("__TESTROOT__", target["TestBundlePath"])
                result = Path(command[command.index("-resultBundlePath") + 1])
                result.mkdir()
                return 65

            with patch.object(runner, "ROOT", root), \
                 patch.object(runner.subprocess, "call", side_effect=invoke), \
                 patch.object(sys, "argv", ["runner", "-only-testing:SSHAppUITests/LiveSSHSmokeUITests"]), \
                 patch.dict(os.environ, {"DEVICE_UDID": "test-device", "SSHAPP_LIVE_SSH_DESTINATION": "demo@example.test", "SSHAPP_LIVE_SSH_PASSWORD": "test-password"}, clear=True):
                self.assertEqual(runner.main(), 65)
            self.assertEqual(len(calls), 2)
            self.assertFalse(temporary_configs[0].exists())
            self.assertEqual(list((root / ".build/ci/xcresults").iterdir()), [])

    def test_stops_on_build_failure(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(runner, "ROOT", Path(directory)), \
             patch.object(runner.subprocess, "call", return_value=73) as call, \
             patch.object(sys, "argv", ["runner"]), \
             patch.dict(os.environ, {"DEVICE_UDID": "test-device"}, clear=True):
            self.assertEqual(runner.main(), 73)
            self.assertEqual(call.call_count, 1)


if __name__ == "__main__":
    unittest.main()
