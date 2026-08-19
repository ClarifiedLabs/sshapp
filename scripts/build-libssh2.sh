#!/usr/bin/env bash
#
# build-libssh2.sh — Cross-compile pinned, locally patched OpenSSL + libssh2
# for arm64 iOS device and simulator slices.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build-libssh2"
FRAMEWORKS_DIR="$PROJECT_DIR/Frameworks"
OPENSSL_SRC="$PROJECT_DIR/vendor/openssl"
LIBSSH2_VENDOR_SRC="$PROJECT_DIR/vendor/libssh2"
LIBSSH2_PATCH_DIR="$SCRIPT_DIR/libssh2-patches"
LIBSSH2_SRC="$BUILD_DIR/libssh2-src"
PROVENANCE_NAME="SSHAppNative.provenance.json"
INPUT_HASH_NAME="SSHAppNative.input-sha256"

EXPECTED_OPENSSL_COMMIT="8cf17aaeb4599f8af87fefd810b5b5fee90fe69e"
EXPECTED_LIBSSH2_COMMIT="a312b43325e3383c865a87bb1d26cb52e3292641"
IOS_MIN_VERSION="18.0"

numbered_patches() {
    find "$LIBSSH2_PATCH_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.patch' -print | LC_ALL=C sort
}

verify_pin() {
    local source_dir="$1"
    local expected_commit="$2"
    local label="$3"
    local actual_commit
    actual_commit="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
    if [ "$actual_commit" != "$expected_commit" ]; then
        echo "error: $label is at ${actual_commit:-unknown}; expected $expected_commit from vendor/PINS.md" >&2
        exit 1
    fi

    local worktree_status
    worktree_status="$(git -C "$source_dir" status --porcelain --untracked-files=all --ignored 2>/dev/null || true)"
    if [ -n "$worktree_status" ]; then
        echo "error: $label contains modified or untracked files; native builds require pristine pinned sources" >&2
        printf '%s\n' "$worktree_status" >&2
        exit 1
    fi
}

file_hash() {
    shasum -a 256 "$1" | awk '{print $1}'
}

compute_input_hash() {
    {
        printf 'openssl=%s\n' "$EXPECTED_OPENSSL_COMMIT"
        printf 'libssh2=%s\n' "$EXPECTED_LIBSSH2_COMMIT"
        printf 'ios-min=%s\n' "$IOS_MIN_VERSION"
        printf 'build-script=%s\n' "$(file_hash "$SCRIPT_DIR/build-libssh2.sh")"
        while IFS= read -r patch; do
            printf 'patch:%s=%s\n' "$(basename "$patch")" "$(file_hash "$patch")"
        done < <(numbered_patches)
    } | shasum -a 256 | awk '{print $1}'
}

prepare_libssh2_source() {
    rm -rf "$LIBSSH2_SRC"
    mkdir -p "$BUILD_DIR"
    rsync -a --delete --exclude='.git' "$LIBSSH2_VENDOR_SRC/" "$LIBSSH2_SRC/"

    local patch_count=0
    while IFS= read -r patch; do
        patch_count=$((patch_count + 1))
        echo "--- Applying $(basename "$patch") ---"
        patch -d "$LIBSSH2_SRC" -p1 -F 0 --batch < "$patch"
    done < <(numbered_patches)

    if [ "$patch_count" -eq 0 ]; then
        echo "error: no numbered libssh2 patches found in $LIBSSH2_PATCH_DIR" >&2
        exit 1
    fi
}

if [ ! -f "$OPENSSL_SRC/Configure" ]; then
    echo "error: OpenSSL source not found. Run: git submodule update --init" >&2
    exit 1
fi
if [ ! -f "$LIBSSH2_VENDOR_SRC/CMakeLists.txt" ]; then
    echo "error: libssh2 source not found. Run: git submodule update --init" >&2
    exit 1
fi
if ! command -v cmake &>/dev/null; then
    echo "error: cmake not found. Install: brew install cmake" >&2
    exit 1
fi

verify_pin "$OPENSSL_SRC" "$EXPECTED_OPENSSL_COMMIT" "vendor/openssl"
verify_pin "$LIBSSH2_VENDOR_SRC" "$EXPECTED_LIBSSH2_COMMIT" "vendor/libssh2"

if [ "${1:-}" = "--prepare-source-only" ]; then
    prepare_libssh2_source
    echo "Prepared patched libssh2 source at $LIBSSH2_SRC"
    exit 0
fi
if [ "$#" -ne 0 ]; then
    echo "usage: $0 [--prepare-source-only]" >&2
    exit 2
fi

INPUT_HASH="$(compute_input_hash)"

framework_hash_matches() {
    local framework_name="$1"
    local hash_path="$FRAMEWORKS_DIR/$framework_name/$INPUT_HASH_NAME"
    [ -d "$FRAMEWORKS_DIR/$framework_name" ] &&
        [ -f "$hash_path" ] &&
        [ "$(tr -d '\r\n' < "$hash_path")" = "$INPUT_HASH" ]
}

if framework_hash_matches "libssh2.xcframework" &&
   framework_hash_matches "libcrypto.xcframework" &&
   framework_hash_matches "libssl.xcframework"; then
    echo "libssh2/OpenSSL xcframeworks match input $INPUT_HASH; skipping build"
    exit 0
fi

printf '%s\n' "=== Build configuration ===" \
    "OpenSSL source: $OPENSSL_SRC" \
    "libssh2 vendor: $LIBSSH2_VENDOR_SRC" \
    "libssh2 copy:   $LIBSSH2_SRC" \
    "Patch dir:      $LIBSSH2_PATCH_DIR" \
    "Input hash:     $INPUT_HASH" \
    "Build dir:      $BUILD_DIR" \
    "Output:         $FRAMEWORKS_DIR" ""

rm -rf "$BUILD_DIR" \
       "$FRAMEWORKS_DIR/libcrypto.xcframework" \
       "$FRAMEWORKS_DIR/libssl.xcframework" \
       "$FRAMEWORKS_DIR/libssh2.xcframework"
mkdir -p "$BUILD_DIR" "$FRAMEWORKS_DIR"
prepare_libssh2_source

build_openssl() {
    local openssl_target="$1"
    local label="$2"
    local min_version_flag="$3"
    local extra_config="${4:-}"
    local out="$BUILD_DIR/openssl-${label}"
    local source_copy="$BUILD_DIR/openssl-src-${label}"

    echo "--- Building OpenSSL ($label) [target: $openssl_target] ${extra_config:+($extra_config)} ---"
    mkdir -p "$out"
    rsync -a --exclude='.git' "$OPENSSL_SRC/" "$source_copy/"

    pushd "$source_copy" >/dev/null
    ./Configure "$openssl_target" \
        no-shared no-tests no-ui-console no-engine $extra_config \
        "$min_version_flag" \
        --prefix="$out"
    make -j"$(sysctl -n hw.logicalcpu)" >/dev/null 2>&1
    make install_sw >/dev/null 2>&1
    popd >/dev/null
    rm -rf "$source_copy"
    echo "    → $out"
}

# ARMv8 assembly remains enabled for the constant-time hardware crypto paths.
build_openssl ios64-xcrun iphoneos-arm64 \
    "-mios-version-min=$IOS_MIN_VERSION"
build_openssl iossimulator-arm64-xcrun iphonesimulator-arm64 \
    "-mios-simulator-version-min=$IOS_MIN_VERSION"

build_libssh2() {
    local arch="$1"
    local label="$2"
    local sdk="$3"
    local out="$BUILD_DIR/libssh2-${label}"
    local openssl_prefix="$BUILD_DIR/openssl-${label}"
    local cmake_build="$BUILD_DIR/libssh2-cmake-${label}"
    local sdk_path

    echo "--- Building libssh2 ($label) ---"
    mkdir -p "$out" "$cmake_build"
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

    cmake -S "$LIBSSH2_SRC" -B "$cmake_build" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_SYSROOT="$sdk_path" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$out" \
        -DCRYPTO_BACKEND=OpenSSL \
        -DOPENSSL_ROOT_DIR="$openssl_prefix" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl_prefix/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$openssl_prefix/lib/libssl.a" \
        -DOPENSSL_INCLUDE_DIR="$openssl_prefix/include" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DENABLE_ZLIB_COMPRESSION=OFF \
        >/dev/null 2>&1

    cmake --build "$cmake_build" --config Release \
        -j"$(sysctl -n hw.logicalcpu)" >/dev/null 2>&1
    cmake --install "$cmake_build" >/dev/null 2>&1
    echo "    → $out"
}

build_libssh2 arm64 iphoneos-arm64 iphoneos
build_libssh2 arm64 iphonesimulator-arm64 iphonesimulator

echo "--- Creating xcframeworks ---"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/openssl-iphoneos-arm64/lib/libcrypto.a" \
    -library "$BUILD_DIR/openssl-iphonesimulator-arm64/lib/libcrypto.a" \
    -output "$FRAMEWORKS_DIR/libcrypto.xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/openssl-iphoneos-arm64/lib/libssl.a" \
    -library "$BUILD_DIR/openssl-iphonesimulator-arm64/lib/libssl.a" \
    -output "$FRAMEWORKS_DIR/libssl.xcframework"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/libssh2-iphoneos-arm64/lib/libssh2.a" \
    -library "$BUILD_DIR/libssh2-iphonesimulator-arm64/lib/libssh2.a" \
    -output "$FRAMEWORKS_DIR/libssh2.xcframework"

echo "--- Writing native provenance ---"
python3 - "$PROJECT_DIR" "$INPUT_HASH" "$PROVENANCE_NAME" "$INPUT_HASH_NAME" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

project = pathlib.Path(sys.argv[1])
input_hash = sys.argv[2]
provenance_name = sys.argv[3]
input_hash_name = sys.argv[4]
patch_dir = project / "scripts/libssh2-patches"
frameworks = project / "Frameworks"

def run(args):
    return subprocess.check_output(args, text=True).strip()

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

patches = {
    path.name: sha256(path)
    for path in sorted(patch_dir.glob("[0-9][0-9][0-9][0-9]-*.patch"))
}
data = {
    "input_sha256": input_hash,
    "ios_minimum_version": "18.0",
    "libssh2": {
        "commit": run(["git", "-C", str(project / "vendor/libssh2"), "rev-parse", "HEAD"]),
        "release": "libssh2-1.11.1",
    },
    "openssl": {
        "commit": run(["git", "-C", str(project / "vendor/openssl"), "rev-parse", "HEAD"]),
        "release": "openssl-3.5.7",
    },
    "build_script_sha256": sha256(project / "scripts/build-libssh2.sh"),
    "patches": patches,
}
serialized = json.dumps(data, indent=2, sort_keys=True) + "\n"
for name in ("libssh2", "libcrypto", "libssl"):
    framework = frameworks / f"{name}.xcframework"
    (framework / provenance_name).write_text(serialized)
    (framework / input_hash_name).write_text(input_hash + "\n")
PY

printf '\n=== Build complete ===\nFrameworks:\n'
ls -d "$FRAMEWORKS_DIR"/{libssh2,libcrypto,libssl}.xcframework
printf 'Provenance input: %s\n' "$INPUT_HASH"
