#!/usr/bin/env bash
#
# build-ghostty-vt.sh - Package the pinned libghostty-vt static slices as an
# SSHApp iOS xcframework.
#
# Compilation stays in scripts/build-ghostty-vt-native.py (pristine vendor/ghostty
# submodule at the ghostty_revision in vendor/libghostty-vt/native-lock.json plus
# vendor/libghostty-vt/patches/, Zig toolchain pinned there). This script only
# stages headers and assembles Frameworks/GhosttyVT.xcframework, rebuilding when
# its inputs change.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_PATH="$PROJECT_DIR/vendor/libghostty-vt/native-lock.json"
PATCH_DIR="$PROJECT_DIR/vendor/libghostty-vt/patches"
VT_NATIVE_DIR="$PROJECT_DIR/.build/ghostty-vt/native"
BUILD_DIR="$PROJECT_DIR/build-ghostty-vt"
ARTIFACTS_DIR="$BUILD_DIR/artifacts"
FRAMEWORKS_DIR="$PROJECT_DIR/Frameworks"
XCFRAMEWORK_PATH="$FRAMEWORKS_DIR/GhosttyVT.xcframework"
PROVENANCE_PATH="$BUILD_DIR/GhosttyVT.provenance.json"
C_TARGET_INCLUDE="$PROJECT_DIR/Packages/SSHAppGhostty/Sources/CGhosttyVT/include/ghostty"
CHECK_ONLY=0
case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    "") ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

# The lock's ghostty_revision is the input-hashed pin; the superproject gitlink
# must name the same commit so `git submodule update` checks out what was built.
# This needs no submodule checkout, so --check stays cheap; the native recipe
# additionally requires a pristine checkout at that commit before compiling.
verify_ghostty_gitlink() {
    local expected actual
    expected="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["ghostty_revision"])' "$LOCK_PATH" 2>/dev/null || true)"
    actual="$(git -C "$PROJECT_DIR" ls-files --stage -- vendor/ghostty 2>/dev/null | awk '$1 == "160000" { print $2 }')"
    if [[ ! "$expected" =~ ^[0-9a-f]{40}$ ]] || [ "$actual" != "$expected" ]; then
        echo "error: vendor/ghostty gitlink is ${actual:-missing}; native-lock.json pins ${expected:-nothing}. Keep them identical." >&2
        exit 1
    fi
}

file_hash() {
    shasum -a 256 "$1" | awk '{print $1}'
}

compute_input_hash() {
    {
        printf 'lock=%s\n' "$(file_hash "$LOCK_PATH")"
        printf 'build-script=%s\n' "$(file_hash "$SCRIPT_DIR/build-ghostty-vt.sh")"
        printf 'native-recipe=%s\n' "$(file_hash "$SCRIPT_DIR/build-ghostty-vt-native.py")"
        # A toolchain or SDK update must rebuild; the native recipe checks
        # these too, but is only reached when this hash misses.
        printf 'xcode=%s\n' "$(xcodebuild -version | tr '\n' ' ')"
        local sdk sdk_path
        for sdk in iphoneos iphonesimulator; do
            sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
            printf 'sdk:%s=%s %s\n' "$sdk" "$(xcrun --sdk "$sdk" --show-sdk-version)" \
                "$(file_hash "$sdk_path/SDKSettings.json")"
        done
        while IFS= read -r patch; do
            printf 'patch:%s=%s\n' "$(basename "$patch")" "$(file_hash "$patch")"
        done < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)
    } | shasum -a 256 | awk '{print $1}'
}

# Both cache hits and fresh builds use the headers stored with the binary.
# Never restore from .build/ghostty-vt: it may belong to another VT revision.
# --check is read-only for Xcode's app phase, which runs too late to generate
# headers for SwiftPM dependencies. `make setup` repairs them before resolution.
validate_and_stage_headers() {
    python3 - "$XCFRAMEWORK_PATH" "$C_TARGET_INCLUDE" "$CHECK_ONLY" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys

framework, destination = map(Path, sys.argv[1:3])
check_only = sys.argv[3] == "1"
metadata = {"SSHAppGhostty.provenance.json", "SSHAppGhostty.input-sha256"}

def hashes(root):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(root.rglob("*")) if path.is_file()}

try:
    manifest = json.loads((framework / "SSHAppGhostty.provenance.json").read_text())
    actual = {name: digest for name, digest in hashes(framework).items() if name not in metadata}
    if not actual or actual != manifest["packaged_files"]:
        raise ValueError("packaged artifacts or headers changed")
    bundles = sorted(framework.glob("*/libghosttyvt.framework"))
    if len(bundles) != 2 or any(
        not (bundle / required).is_file()
        for bundle in bundles
        for required in ("libghosttyvt", "Headers/ghostty/vt.h", "Modules/module.modulemap")
    ):
        raise ValueError("missing VT framework slice or public headers")
    source = bundles[0] / "Headers/ghostty"
    expected = hashes(source)
    if expected != hashes(bundles[1] / "Headers/ghostty"):
        raise ValueError("VT slices have different public headers")
    if hashes(destination) != expected:
        if check_only:
            raise ValueError("generated CGhosttyVT headers are missing or stale")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source, destination)
        print("Restored CGhosttyVT headers from verified GhosttyVT.xcframework")
except (OSError, ValueError, KeyError, TypeError) as error:
    print(f"GhosttyVT cache invalid: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

verify_ghostty_gitlink
INPUT_HASH="$(compute_input_hash)"
INPUT_HASH_NAME="SSHAppGhostty.input-sha256"

if [ -d "$XCFRAMEWORK_PATH" ] &&
   [ -f "$XCFRAMEWORK_PATH/$INPUT_HASH_NAME" ] &&
   [ "$(tr -d '\r\n' < "$XCFRAMEWORK_PATH/$INPUT_HASH_NAME")" = "$INPUT_HASH" ] &&
   validate_and_stage_headers; then
    echo "GhosttyVT.xcframework matches input $INPUT_HASH; skipping build"
    exit 0
fi

if [ "$CHECK_ONLY" = 1 ]; then
    echo "error: GhosttyVT inputs or generated headers are stale. Run make setup before building/resolving packages in Xcode." >&2
    exit 1
fi

echo "=== GhosttyVT build configuration ==="
echo "Lock:     $LOCK_PATH"
echo "Native:   $VT_NATIVE_DIR"
echo "Output:   $XCFRAMEWORK_PATH"
echo ""

python3 "$SCRIPT_DIR/build-ghostty-vt-native.py"

for slice in iphoneos iphonesimulator; do
    if [ ! -f "$VT_NATIVE_DIR/$slice/libghostty-vt.a" ]; then
        echo "error: missing $VT_NATIVE_DIR/$slice/libghostty-vt.a"
        exit 1
    fi
done
if [ ! -f "$VT_NATIVE_DIR/include/ghostty/vt.h" ]; then
    echo "error: missing $VT_NATIVE_DIR/include/ghostty/vt.h"
    exit 1
fi

rm -rf "$BUILD_DIR" "$XCFRAMEWORK_PATH"
mkdir -p "$ARTIFACTS_DIR/iphoneos-arm64" "$ARTIFACTS_DIR/iphonesimulator-arm64" "$FRAMEWORKS_DIR"

# Static *framework* bundles, not bare .a + Headers: a second flat static-library
# xcframework would stage its top-level module.modulemap to the same products
# include dir as another static xcframework's, failing the build with duplicate outputs. The
# framework bundle namespaces headers and the module map per framework.
for slice in iphoneos iphonesimulator; do
    case "$slice" in
        iphoneos) label="iphoneos-arm64" ;;
        iphonesimulator) label="iphonesimulator-arm64" ;;
    esac
    fw="$ARTIFACTS_DIR/$label/libghosttyvt.framework"
    mkdir -p "$fw/Headers" "$fw/Modules"
    cp "$VT_NATIVE_DIR/$slice/libghostty-vt.a" "$fw/libghosttyvt"
    cp -R "$VT_NATIVE_DIR/include/ghostty" "$fw/Headers/ghostty"
    find "$fw/Headers" -name '*.orig' -delete
    # Rewrite upstream <ghostty/...> sibling includes to file-relative quoted
    # includes. Framework consumers have no Headers dir on the include path
    # (framework xcframework Info.plist sets no HeadersPath), so angle
    # includes of sibling headers cannot resolve. System includes are untouched.
    python3 - "$fw/Headers/ghostty" <<'PYEOF'
import os
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
pattern = re.compile(r'#include\s*<ghostty/([^>]+)>')
for path in sorted(root.rglob('*.h')):
    text = path.read_text()
    def replace(match):
        relative = os.path.relpath(root / match.group(1), path.parent)
        return '#include "%s"' % relative
    rewritten, count = pattern.subn(replace, text)
    if count:
        path.write_text(rewritten)
PYEOF
    cat >"$fw/Modules/module.modulemap" <<'EOF'
framework module libghosttyvt {
    umbrella header "ghostty/vt.h"
    export *
}
EOF
    cat >"$fw/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>libghosttyvt</string>
	<key>CFBundleIdentifier</key>
	<string>dev.sshapp.libghosttyvt</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
EOF
done

echo "--- Creating GhosttyVT.xcframework ---"
xcodebuild -create-xcframework \
    -framework "$ARTIFACTS_DIR/iphoneos-arm64/libghosttyvt.framework" \
    -framework "$ARTIFACTS_DIR/iphonesimulator-arm64/libghosttyvt.framework" \
    -output "$XCFRAMEWORK_PATH"

echo "--- Writing provenance ---"
python3 - "$PROJECT_DIR" "$LOCK_PATH" "$PATCH_DIR" "$XCFRAMEWORK_PATH" "$PROVENANCE_PATH" <<'PY'
import hashlib
import json
import pathlib
import sys

project = pathlib.Path(sys.argv[1])
lock_path = pathlib.Path(sys.argv[2])
patch_dir = pathlib.Path(sys.argv[3])
xcframework = pathlib.Path(sys.argv[4])
provenance_path = pathlib.Path(sys.argv[5])

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

patches = {
    path.name: sha256(path)
    for path in sorted(patch_dir.iterdir())
    if path.is_file() and path.suffix == ".patch"
}

slices = {
    str(path.relative_to(project)): sha256(path)
    for path in sorted(xcframework.glob("*/libghosttyvt.framework/libghosttyvt"))
}
maps = {
    str(path.relative_to(project)): sha256(path)
    for path in sorted(xcframework.glob("*/libghosttyvt.framework/Modules/module.modulemap"))
}

data = {
    "vt_lock": json.loads(lock_path.read_text()),
    "patches": patches,
    "artifacts": slices,
    "module_maps": maps,
    # Relative to the bundle, so a restored cache works in another checkout.
    # Bind all headers, binaries, module maps and plists to this cache entry.
    "packaged_files": {
        str(path.relative_to(xcframework)): sha256(path)
        for path in sorted(xcframework.rglob("*")) if path.is_file()
    },
}

provenance_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
(xcframework / "SSHAppGhostty.provenance.json").write_text(
    json.dumps(data, indent=2, sort_keys=True) + "\n"
)
PY

# SPM C targets need their own generated include tree. File-relative includes
# in the packaged headers work for both framework and C-target consumers.
validate_and_stage_headers

echo "--- Writing GhosttyVT input hash ---"
printf '%s\n' "$INPUT_HASH" >"$XCFRAMEWORK_PATH/$INPUT_HASH_NAME"

echo ""
echo "=== GhosttyVT build complete ==="
echo "Framework:  $XCFRAMEWORK_PATH"
echo "Provenance: $PROVENANCE_PATH"
