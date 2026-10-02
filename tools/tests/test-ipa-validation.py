#!/usr/bin/env python3
"""Exercise metadata checks against exported ZIP contents, without extracting."""

import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/validate-ipa.py"
spec = importlib.util.spec_from_file_location("ipa_validation", SCRIPT)
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


class IPAValidationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.ipa = Path(temporary.name) / "SSHApp.ipa"
        self.app = "Payload/SSHApp.app"
        self.framework = self.app + "/Frameworks/libghosttyvt.framework"
        self.entries = {}
        self.add_bundle(self.app, "APPL", "dev.sshapp.sshapp", "SSHApp")
        self.add_bundle(self.framework, "FMWK", "dev.sshapp.libghosttyvt", "libghosttyvt")

    def add_bundle(self, path, package_type, identifier, executable):
        self.entries[path + "/Info.plist"] = plistlib.dumps({
            "CFBundlePackageType": package_type,
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executable,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "60",
            "MinimumOSVersion": "18.0",
        }, fmt=plistlib.FMT_BINARY)
        self.entries[path + "/" + executable] = b"fixture executable"

    def write_ipa(self):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            for name, value in self.entries.items():
                archive.writestr(name, value)

    def change_plist(self, bundle, key, value):
        path = bundle + "/Info.plist"
        plist = plistlib.loads(self.entries[path])
        if value is None:
            del plist[key]
        else:
            plist[key] = value
        self.entries[path] = plistlib.dumps(plist)

    def errors(self):
        self.write_ipa()
        return validation.validate_ipa(self.ipa, "dev.sshapp.sshapp")

    def test_valid_frameworks_and_resource_bundles(self):
        # Resource-only bundles need neither executable nor framework versions.
        self.entries[self.app + "/Themes.bundle/Info.plist"] = plistlib.dumps({})
        self.assertEqual(self.errors(), [])

    def test_original_upload_failure_is_detected_with_framework_path(self):
        self.change_plist(self.framework, "CFBundleShortVersionString", None)
        self.change_plist(self.framework, "MinimumOSVersion", None)
        errors = self.errors()
        self.assertEqual(len(errors), 2)
        self.assertTrue(all(self.framework in error for error in errors))
        self.assertTrue(any("CFBundleShortVersionString" in error for error in errors))
        self.assertTrue(any("MinimumOSVersion" in error for error in errors))

    def test_invalid_and_missing_metadata_is_rejected(self):
        original = dict(self.entries)
        for key, values in {
            "CFBundleShortVersionString": [None, "", "1.3.2-dev", "1.2.3.4", 1],
            "CFBundleVersion": [None, "", "main", True],
            "MinimumOSVersion": [None, "", "7.0", "eighteen", 18],
            "CFBundleIdentifier": [None, "", "  "],
            "CFBundleExecutable": [None, "", "../SSHApp", "absent"],
            "CFBundlePackageType": [None, "APPL"],
        }.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    self.entries = dict(original)
                    self.change_plist(self.framework, key, value)
                    self.assertTrue(any(key in error for error in self.errors()))

    def test_missing_executable_is_rejected(self):
        del self.entries[self.framework + "/libghosttyvt"]
        self.assertTrue(any("CFBundleExecutable" in error for error in self.errors()))

    def test_missing_malformed_or_nondictionary_plist_is_rejected(self):
        for value in [None, b"not a plist", b"<?xml version='1.0'?><plist><dict>", plistlib.dumps([])]:
            with self.subTest(value=value):
                path = self.framework + "/Info.plist"
                if value is None:
                    self.entries.pop(path, None)
                else:
                    self.entries[path] = value
                self.assertTrue(any("Info.plist" in error for error in self.errors()))

    def test_nested_extension_framework_is_checked(self):
        extension = self.app + "/PlugIns/Widget.appex"
        framework = extension + "/Frameworks/Other.framework"
        self.add_bundle(extension, "XPC!", "dev.sshapp.widget", "Widget")
        self.add_bundle(framework, "FMWK", "dev.sshapp.other", "Other")
        self.assertEqual(self.errors(), [])
        self.change_plist(framework, "MinimumOSVersion", None)
        self.assertTrue(any(framework in error for error in self.errors()))

    def test_missing_or_multiple_main_apps_is_rejected(self):
        original = dict(self.entries)
        self.entries = {"Other/Info.plist": plistlib.dumps({})}
        self.assertIn("found 0", self.errors()[0])
        self.entries = original
        self.add_bundle("Payload/Other.app", "APPL", "dev.sshapp.other", "Other")
        self.assertIn("found 2", self.errors()[0])

    def test_wrong_release_bundle_identifier_is_rejected(self):
        self.change_plist(self.app, "CFBundleIdentifier", "dev.sshapp.wrong")
        self.assertTrue(any("must be dev.sshapp.sshapp" in error for error in self.errors()))

    def test_cli_checks_final_bytes_without_modifying_ipa(self):
        for valid in (True, False):
            with self.subTest(valid=valid):
                if not valid:
                    self.change_plist(self.framework, "MinimumOSVersion", None)
                self.write_ipa()
                before = self.ipa.read_bytes()
                result = subprocess.run([sys.executable, str(SCRIPT), str(self.ipa),
                                         "--bundle-identifier", "dev.sshapp.sshapp"],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if valid else 1)
                if not valid:
                    self.assertIn(self.framework, result.stderr)
                self.assertEqual(self.ipa.read_bytes(), before)

    def test_cli_reports_invalid_zip(self):
        self.ipa.write_bytes(b"not a zip")
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.ipa)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Cannot read", result.stderr)


if __name__ == "__main__":
    unittest.main()
