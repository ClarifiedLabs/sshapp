#!/usr/bin/env python3
"""Check executable bundle metadata in the exported IPA before uploading it."""

from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import plistlib
import re
import sys
import zipfile
from xml.parsers.expat import ExpatError


NUMERIC_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}")
PACKAGE_TYPES = {".app": "APPL", ".appex": "XPC!", ".framework": "FMWK"}


def validate_bundle(archive: zipfile.ZipFile, bundle: str) -> list[str]:
    try:
        plist = plistlib.loads(archive.read(f"{bundle}/Info.plist"))
        if not isinstance(plist, dict):
            raise ValueError("expected a plist dictionary")
    except (KeyError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        return [f"{bundle}: missing or invalid Info.plist ({error})"]

    errors = []
    for key in ("CFBundleIdentifier", "CFBundleExecutable"):
        value = plist.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{bundle}: missing or empty {key}")
    executable = plist.get("CFBundleExecutable")
    if isinstance(executable, str) and executable.strip():
        if "/" in executable or executable in (".", "..") or f"{bundle}/{executable}" not in archive.namelist():
            errors.append(f"{bundle}: CFBundleExecutable does not name a bundled executable")

    expected_type = PACKAGE_TYPES[PurePosixPath(bundle).suffix]
    if plist.get("CFBundlePackageType") != expected_type:
        errors.append(f"{bundle}: CFBundlePackageType must be {expected_type}")

    # Xcode-generated frameworks can use 1.0; accept one to three numeric
    # components while rejecting empty values and upstream development tags.
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion"):
        value = plist.get(key)
        if not isinstance(value, str) or NUMERIC_VERSION.fullmatch(value) is None:
            errors.append(f"{bundle}: missing or invalid {key} ({value!r})")
        elif key == "MinimumOSVersion" and int(value.split(".")[0]) < 8:
            errors.append(f"{bundle}: MinimumOSVersion must be at least 8.0 for this arm64 app")
    return errors


def validate_ipa(path: Path, bundle_identifier: str | None = None) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        bundles = set()
        for name in archive.namelist():
            parts = PurePosixPath(name).parts
            if len(parts) < 2 or parts[0] != "Payload":
                continue
            for index, part in enumerate(parts[1:], start=1):
                if PurePosixPath(part).suffix in PACKAGE_TYPES:
                    bundles.add("/".join(parts[:index + 1]))

        apps = sorted(bundle for bundle in bundles
                      if len(PurePosixPath(bundle).parts) == 2 and bundle.endswith(".app"))
        if len(apps) != 1:
            return [f"IPA must contain exactly one Payload/*.app; found {len(apps)}"]
        errors = [error for bundle in sorted(bundles) for error in validate_bundle(archive, bundle)]
        if bundle_identifier:
            try:
                plist = plistlib.loads(archive.read(f"{apps[0]}/Info.plist"))
                if not isinstance(plist, dict) or plist.get("CFBundleIdentifier") != bundle_identifier:
                    errors.append(f"{apps[0]}: CFBundleIdentifier must be {bundle_identifier}")
            except (KeyError, ValueError, plistlib.InvalidFileException, ExpatError):
                pass  # The bundle check already reports the invalid plist.
        return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--bundle-identifier")
    args = parser.parse_args()
    try:
        errors = validate_ipa(args.ipa, args.bundle_identifier)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        errors = [f"Cannot read {args.ipa}: {error}"]
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"Validated executable bundle metadata in {args.ipa}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
