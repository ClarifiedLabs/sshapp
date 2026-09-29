#!/usr/bin/env python3
"""Device-runner isolation, credential handling, and failure propagation."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("device_runner", ROOT / "scripts/run-device-tests.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class DeviceRunnerTests(unittest.TestCase):
    def setUp(self):
        # Runner unit tests must never contact a physical device.
        self.real_device_check = runner.require_unlocked_device
        device_check = patch.object(runner, "require_unlocked_device")
        self.device_check = device_check.start()
        self.addCleanup(device_check.stop)

    def test_lock_preflight_rejects_locked_and_missing_evidence(self):
        for state in ({"passcodeRequired": True, "unlockedSinceBoot": True},
                      {"passcodeRequired": False, "unlockedSinceBoot": False}, {}):
            output = json.dumps({"info": {"outcome": "success"}, "result": state})
            with patch.object(runner.subprocess, "run", return_value=Mock(stdout=output)), self.assertRaises(RuntimeError):
                self.real_device_check("test-device")
        with patch.object(runner.subprocess, "run", return_value=Mock(stdout="invalid")), self.assertRaises(RuntimeError):
            self.real_device_check("test-device")

    def test_lock_preflight_accepts_only_confirmed_unlock_and_is_bounded(self):
        output = json.dumps({"info": {"outcome": "success"},
                             "result": {"passcodeRequired": False, "unlockedSinceBoot": True}})
        with patch.object(runner.subprocess, "run", return_value=Mock(stdout=output)) as run:
            self.real_device_check("test-device")
            self.assertEqual(run.call_args.kwargs["timeout"], 20)
            self.assertIn("lockState", run.call_args.args[0])
            self.assertIn("test-device", run.call_args.args[0])

    def test_metal_validation_is_explicit_and_only_changes_app_hosted_target(self):
        targets = [{"BlueprintName": name, "EnvironmentVariables": {"EXISTING": "1"}}
                   for name in ("SSHAppTests", "SSHAppUITests", "OtherTests")]
        document = {"TestConfigurations": [{"TestTargets": targets}]}
        self.assertEqual(runner.configure_metal_validation(document), 1)
        self.assertEqual(targets[0]["EnvironmentVariables"], {"EXISTING": "1", "MTL_DEBUG_LAYER": "1"})
        for target in targets[1:]:
            self.assertEqual(target["EnvironmentVariables"], {"EXISTING": "1"})
        with self.assertRaises(ValueError):
            runner.configure_metal_validation({})

    def test_ui_test_run_id_only_changes_ui_target_and_is_unique_per_run(self):
        targets = [{"BlueprintName": name, "EnvironmentVariables": {"EXISTING": "1"}}
                   for name in ("SSHAppTests", "SSHAppUITests")]
        document = {"TestConfigurations": [{"TestTargets": targets}]}
        self.assertEqual(runner.configure_ui_test_run_id(document, "abc123"), 1)
        self.assertEqual(targets[0]["EnvironmentVariables"], {"EXISTING": "1"})
        self.assertEqual(targets[1]["EnvironmentVariables"],
                         {"EXISTING": "1", runner.UI_TEST_RUN_ID_KEY: "abc123"})
        self.assertEqual(runner.configure_ui_test_run_id({}, "abc123"), 0)

    def test_invalid_validation_flag_does_not_build(self):
        with patch.object(runner.subprocess, "call") as call, \
             patch.object(sys, "argv", ["runner"]), \
             patch.dict(os.environ, {"DEVICE_UDID": "test-device", "SSHAPP_METAL_VALIDATION": "maybe"}, clear=True):
            self.assertEqual(runner.main(), 2)
            call.assert_not_called()

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
                        "BlueprintName": "SSHAppUITests", "TestBundlePath": "__TESTROOT__/tests.xctest",
                        "PreferredScreenCaptureFormat": "screenRecording"
                    }]}]}
                    (products / "SSHApp_SSHAppAllTests_iphoneos27.0-arm64.xctestrun").write_bytes(plistlib.dumps(config))
                    return 0
                self.assertEqual(command[-1], "-only-testing:SSHAppUITests/LiveSSHSmokeUITests",
                                 "One pass runs exactly the user's filters")
                temporary = Path(command[command.index("-xctestrun") + 1])
                temporary_configs.append(temporary)
                self.assertEqual(temporary.stat().st_mode & 0o777, 0o600)
                config = plistlib.loads(temporary.read_bytes())
                target = config["TestConfigurations"][0]["TestTargets"][0]
                self.assertEqual(target["EnvironmentVariables"]["SSHAPP_LIVE_SSH_PASSWORD"], "test-password")
                self.assertNotIn("SSHAPP_VT_PRESENTATION_BACKEND", target["EnvironmentVariables"])
                self.assertRegex(target["EnvironmentVariables"][runner.UI_TEST_RUN_ID_KEY], r"^[0-9a-f]{32}$")
                self.assertEqual(target["PreferredScreenCaptureFormat"], "screenshots")
                self.assertNotIn("__TESTROOT__", target["TestBundlePath"])
                result = Path(command[command.index("-resultBundlePath") + 1])
                result.mkdir()
                return 65

            with patch.object(runner, "ROOT", root), \
                 patch.object(runner.subprocess, "call", side_effect=invoke), \
                 patch.object(runner, "run_watched", side_effect=invoke), \
                 patch.object(sys, "argv", ["runner", "-only-testing:SSHAppUITests/LiveSSHSmokeUITests"]), \
                 patch.dict(os.environ, {"DEVICE_UDID": "test-device", "SSHAPP_LIVE_SSH_DESTINATION": "demo@example.test", "SSHAPP_LIVE_SSH_PASSWORD": "test-password"}, clear=True):
                self.assertEqual(runner.main(), 65)
            self.assertEqual(len(calls), 2, "One build and one test run")
            self.assertFalse(temporary_configs[0].exists())
            self.assertEqual(list((root / ".build/ci/xcresults").iterdir()), [])

    def test_release_build_configuration_is_forwarded_and_invalid_value_does_not_build(self):
        with patch.object(runner.subprocess, "call", return_value=73) as call, \
             patch.object(sys, "argv", ["runner"]), \
             patch.dict(os.environ, {"DEVICE_UDID": "test-device", "DEVICE_BUILD_CONFIGURATION": "Release"}, clear=True):
            self.assertEqual(runner.main(), 73)
            command = call.call_args.args[0]
            self.assertEqual(command[command.index("-configuration") + 1], "Release")
            self.assertIn("ENABLE_TESTABILITY=YES", command)
            # Release device tests opt back into the seams App Store builds omit.
            self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) VT_TEST_HOOKS", command)
            self.assertIn("GCC_PREPROCESSOR_DEFINITIONS=$(inherited) VT_TEST_HOOKS=1", command)
        with patch.object(runner.subprocess, "call") as call, \
             patch.object(sys, "argv", ["runner"]), \
             patch.dict(os.environ, {"DEVICE_UDID": "test-device", "DEVICE_BUILD_CONFIGURATION": "Invalid"}, clear=True):
            self.assertEqual(runner.main(), 2)
            call.assert_not_called()

    def test_runs_started_in_same_second_do_not_share_results(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results = []

            def invoke(command, **kwargs):
                if command[1] == "build-for-testing":
                    products = root / ".build/device-tests/Build/Products"
                    products.mkdir(parents=True, exist_ok=True)
                    config = {"TestConfigurations": [{"TestTargets": [{
                        "BlueprintName": "SSHAppTests", "TestBundlePath": "__TESTROOT__/tests.xctest"
                    }]}]}
                    (products / "SSHApp_SSHAppAllTests_iphoneos27.0-arm64.xctestrun").write_bytes(plistlib.dumps(config))
                else:
                    result = Path(command[command.index("-resultBundlePath") + 1])
                    result.mkdir()
                    results.append(result)
                return 0

            with patch.object(runner, "ROOT", root), \
                 patch.object(runner.subprocess, "call", side_effect=invoke), \
                 patch.object(runner, "run_watched", side_effect=invoke), \
                 patch.object(runner, "datetime") as clock, \
                 patch.object(sys, "argv", ["runner"]), \
                 patch.dict(os.environ, {"DEVICE_UDID": "test-device"}, clear=True):
                clock.now.return_value.strftime.return_value = "device-20260923-065811-"
                self.assertEqual(runner.main(), 0)
                self.assertEqual(runner.main(), 0)
            self.assertEqual(len(set(results)), 2)
            self.assertTrue(all(result.exists() for result in results))

    def test_stops_on_build_failure(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(runner, "ROOT", Path(directory)), \
             patch.object(runner.subprocess, "call", return_value=73) as call, \
             patch.object(sys, "argv", ["runner"]), \
             patch.dict(os.environ, {"DEVICE_UDID": "test-device"}, clear=True):
            self.assertEqual(runner.main(), 73)
            self.assertEqual(call.call_count, 1)

    def test_device_runs_capture_screenshots_instead_of_screen_recordings(self):
        # Per-test screen recording hot-plugs a virtual AirPlay display that
        # crashed iPadOS 27 SpringBoard; every target captures screenshots.
        targets = [{"BlueprintName": name, "PreferredScreenCaptureFormat": "screenRecording"}
                   for name in ("SSHAppTests", "SSHAppUITests")]
        document = {"TestConfigurations": [{"TestTargets": targets}]}
        self.assertEqual(runner.configure_screen_capture(document), 2)
        self.assertEqual([t["PreferredScreenCaptureFormat"] for t in targets], ["screenshots"] * 2)
        with self.assertRaises(ValueError):
            runner.configure_screen_capture({})

    def test_runner_has_no_experiment_or_second_pass_settings(self):
        source = (ROOT / "scripts/run-device-tests.py").read_text(encoding="utf-8")
        for removed in ("SSHAPP_REPRO", "UIRequiresFullScreen", "plan_passes", "orientation_tests"):
            self.assertNotIn(removed, source)

    def fake_xcodebuild(self, script):
        return [sys.executable, "-c", script]

    def test_watchdog_passes_through_normal_exit_status(self):
        command = self.fake_xcodebuild("print(\"Test Case '-[A b]' passed (0.1 seconds).\"); raise SystemExit(65)")
        with patch.object(sys, "stdout"):
            self.assertEqual(runner.run_watched(command, cwd=ROOT, env=os.environ.copy()), 65)

    def test_watchdog_stops_on_device_unlock_wait(self):
        command = self.fake_xcodebuild("import time; print('Unlock tmini7 to Continue', flush=True); time.sleep(60)")
        started = runner.time.monotonic()
        with patch.object(sys, "stdout"), patch.object(sys, "stderr"):
            status = runner.run_watched(command, cwd=ROOT, env=os.environ.copy())
        self.assertEqual(status, runner.DEVICE_HUNG_STATUS)
        self.assertLess(runner.time.monotonic() - started, 30)

    def test_watchdog_stops_when_ui_tests_report_wedged_device(self):
        line = ("KeyboardSuppressionUITests.swift:42: error: -[SSHAppUITests.KeyboardSuppressionUITests testX] : "
                "failed - Device UI is wedged (app window exists but stayed unhittable for 10 s); capture a sysdiagnose")
        command = self.fake_xcodebuild(f"import time; print({line!r}, flush=True); time.sleep(60)")
        started = runner.time.monotonic()
        with patch.object(sys, "stdout"), patch.object(sys, "stderr"):
            self.assertEqual(runner.run_watched(command, cwd=ROOT, env=os.environ.copy()),
                             runner.DEVICE_HUNG_STATUS)
        self.assertLess(runner.time.monotonic() - started, 30)

    def test_watchdog_stops_after_repeated_dead_hit_points(self):
        line = "    t =     2.92s         Computed hit point {-1, -1} after scrolling to visible"
        command = self.fake_xcodebuild(
            f"import time\nfor _ in range(3): print({line!r}, flush=True)\ntime.sleep(60)")
        started = runner.time.monotonic()
        with patch.object(sys, "stdout"), patch.object(sys, "stderr") as stderr:
            self.assertEqual(runner.run_watched(command, cwd=ROOT, env=os.environ.copy()),
                             runner.DEVICE_HUNG_STATUS)
        self.assertLess(runner.time.monotonic() - started, 30)
        self.assertIn("hit point {-1, -1} 3 times", "".join(c.args[0] for c in stderr.write.call_args_list))

    def test_watchdog_tolerates_fewer_dead_hit_points(self):
        line = "    t =     2.92s         Computed hit point {-1, -1} after scrolling to visible"
        command = self.fake_xcodebuild(
            f"for _ in range(2): print({line!r}, flush=True)\nraise SystemExit(65)")
        with patch.object(sys, "stdout"):
            self.assertEqual(runner.run_watched(command, cwd=ROOT, env=os.environ.copy()), 65)

    def test_watchdog_stops_when_springboard_respawns(self):
        # XCTest reports an Unknown interface orientation once SpringBoard crashed
        # and restarted under the runner; healthy runs only log real orientations.
        line = "    t =     0.04s     Interface orientation changed to Unknown"
        command = self.fake_xcodebuild(f"import time; print({line!r}, flush=True); time.sleep(60)")
        started = runner.time.monotonic()
        with patch.object(sys, "stdout"), patch.object(sys, "stderr"):
            self.assertEqual(runner.run_watched(command, cwd=ROOT, env=os.environ.copy()),
                             runner.DEVICE_HUNG_STATUS)
        self.assertLess(runner.time.monotonic() - started, 30)

    def test_watchdog_ignores_real_orientation_changes(self):
        lines = ["    t =      nans Interface orientation changed to Portrait",
                 "    t =     0.05s     Interface orientation changed to Landscape Right"]
        command = self.fake_xcodebuild(f"for line in {lines!r}: print(line, flush=True)\nraise SystemExit(0)")
        with patch.object(sys, "stdout"):
            self.assertEqual(runner.run_watched(command, cwd=ROOT, env=os.environ.copy()), 0)

    def test_watchdog_stops_after_second_runner_restart(self):
        restart = runner.RUNNER_RESTART
        command = self.fake_xcodebuild(
            f"import time; print({restart!r}, flush=True); print({restart!r}, flush=True); time.sleep(60)")
        with patch.object(sys, "stdout"), patch.object(sys, "stderr"):
            self.assertEqual(runner.run_watched(command, cwd=ROOT, env=os.environ.copy()),
                             runner.DEVICE_HUNG_STATUS)

    def test_watchdog_stops_when_no_test_progresses(self):
        command = self.fake_xcodebuild("import time; print('Setting up automation session', flush=True); time.sleep(60)")
        with patch.object(sys, "stdout"), patch.object(sys, "stderr"):
            self.assertEqual(runner.run_watched(command, cwd=ROOT, env=os.environ.copy(), idle_timeout=1),
                             runner.DEVICE_HUNG_STATUS)


if __name__ == "__main__":
    unittest.main()
