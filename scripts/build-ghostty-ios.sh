#!/usr/bin/env bash
#
# build-ghostty-ios.sh - Build a pinned, patched Ghostty static XCFramework
# for SSHApp's iOS device and Apple-silicon simulator targets.
#
# Prerequisites: Xcode command-line tools, Zig.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build-ghostty"
FRAMEWORKS_DIR="$PROJECT_DIR/Frameworks"
GHOSTTY_SRC="$PROJECT_DIR/vendor/ghostty"
PATCH_DIR="$PROJECT_DIR/scripts/ghostty-patches"
SOURCE_COPY="$BUILD_DIR/ghostty-src"
ARTIFACTS_DIR="$BUILD_DIR/artifacts"
XCFRAMEWORK_PATH="$FRAMEWORKS_DIR/GhosttyKit.xcframework"
PROVENANCE_PATH="$BUILD_DIR/GhosttyKit.provenance.json"

IOS_MIN_VERSION="18.0"
EXPECTED_GHOSTTY_COMMIT="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"
GHOSTTY_VERSION="1.3.1"
REQUIRED_ZIG_VERSION="0.15.2"
ZIG_BIN="${ZIG:-zig}"

echo "=== Ghostty build configuration ==="
echo "Ghostty source: $GHOSTTY_SRC"
echo "Build dir:      $BUILD_DIR"
echo "Output:         $XCFRAMEWORK_PATH"
echo ""

if [ ! -e "$GHOSTTY_SRC/.git" ]; then
    echo "error: Ghostty source not found. Run: git submodule update --init --recursive"
    exit 1
fi

if [ ! -f "$GHOSTTY_SRC/include/ghostty.h" ]; then
    echo "error: Ghostty header not found at vendor/ghostty/include/ghostty.h"
    exit 1
fi

if ! command -v "$ZIG_BIN" >/dev/null 2>&1; then
    echo "error: zig not found. Install Zig before building Ghostty."
    exit 1
fi

zig_version="$("$ZIG_BIN" version)"
if [ "$zig_version" != "$REQUIRED_ZIG_VERSION" ]; then
    echo "error: Ghostty v1.3.1 requires Zig $REQUIRED_ZIG_VERSION, but '$ZIG_BIN' is $zig_version."
    echo "       Re-run with ZIG=/path/to/zig-$REQUIRED_ZIG_VERSION if needed."
    exit 1
fi

actual_commit="$(git -C "$GHOSTTY_SRC" rev-parse HEAD)"
if [ "$actual_commit" != "$EXPECTED_GHOSTTY_COMMIT" ]; then
    echo "error: vendor/ghostty is at $actual_commit"
    echo "       expected $EXPECTED_GHOSTTY_COMMIT (Ghostty v1.3.1)"
    exit 1
fi

rm -rf "$BUILD_DIR" "$XCFRAMEWORK_PATH"
mkdir -p "$BUILD_DIR" "$ARTIFACTS_DIR" "$FRAMEWORKS_DIR"

echo "--- Preparing patched Ghostty source ---"
rsync -a --delete --exclude='.git' "$GHOSTTY_SRC/" "$SOURCE_COPY/"

for patch_file in "$PATCH_DIR"/*; do
    case "$patch_file" in
        *.patch)
            echo "    applying $(basename "$patch_file")"
            (cd "$SOURCE_COPY" && patch -p1 -i "$patch_file")
            ;;
        *.sh)
            echo "    running $(basename "$patch_file")"
            "$patch_file" "$SOURCE_COPY"
            ;;
        *)
            ;;
    esac
done

if ! grep -Fq "GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED" "$SOURCE_COPY/include/ghostty.h"; then
    echo "error: host-managed Ghostty header patch did not apply"
    exit 1
fi
if ! grep -Fq "ghostty_surface_write_buffer" "$SOURCE_COPY/src/apprt/embedded.zig"; then
    echo "error: host-managed Ghostty C API patch did not apply"
    exit 1
fi

build_ghostty_slice() {
    local zig_target="$1"
    local label="$2"
    local mach_o_platform="$3"
    local zig_cpu="${4:-}"
    local out="$ARTIFACTS_DIR/$label"
    local local_cache="$BUILD_DIR/cache/$label/zig-local"
    local global_cache="$BUILD_DIR/cache/zig-global"
    local module_cache="$BUILD_DIR/cache/$label/clang-module-cache"
    local platform_check_dir="$BUILD_DIR/cache/$label/platform-check"
    local archives=()
    local objects=()
    local seen_archive_names=" "
    local cpu_args=()

    echo "--- Building Ghostty ($label) [target: $zig_target] ---"
    rm -rf "$out" "$local_cache" "$module_cache"
    mkdir -p "$out/lib" "$out/include" "$global_cache" "$local_cache" "$module_cache"
    rm -rf "$SOURCE_COPY/zig-out"

    if [ -n "$zig_cpu" ]; then
        cpu_args=(-Dcpu="$zig_cpu")
    fi

    (
        cd "$SOURCE_COPY"
        env \
            CLANG_MODULE_CACHE_PATH="$module_cache" \
            ZIG_GLOBAL_CACHE_DIR="$global_cache" \
            ZIG_LOCAL_CACHE_DIR="$local_cache" \
            MACOSX_DEPLOYMENT_TARGET=13.0 \
            IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
            "$ZIG_BIN" build \
                -Doptimize="${ZIG_OPTIMIZE:-ReleaseFast}" \
                -Dapp-runtime=none \
                -Demit-exe=false \
                -Demit-xcframework=false \
                -Demit-macos-app=false \
                -Demit-docs=false \
                -Dsentry=false \
                -Dcustom-shaders=false \
                -Dinspector=false \
                -Dversion-string="$GHOSTTY_VERSION" \
                -Dtarget="$zig_target" \
                "${cpu_args[@]}"
    )

    while IFS= read -r archive; do
        local archive_name
        local archive_platforms
        archive_name="$(basename "$archive")"
        if [ "$archive_name" = "libghostty-fat.a" ]; then
            continue
        fi
        rm -rf "$platform_check_dir"
        mkdir -p "$platform_check_dir"
        (cd "$platform_check_dir" && ar -x "$archive")
        chmod -R u+rw "$platform_check_dir"
        archive_platforms="$(
            find "$platform_check_dir" -type f -name "*.o" -print0 \
                | xargs -0 otool -l 2>/dev/null \
                | awk '/platform / { print $2 }' \
                | sort -u \
                | paste -sd ' ' -
        )"
        if [ "$archive_platforms" != "$mach_o_platform" ]; then
            continue
        fi
        case "$seen_archive_names" in
            *" $archive_name "*) continue ;;
        esac
        archives+=("$archive")
        seen_archive_names="${seen_archive_names}${archive_name} "
    done < <(find "$local_cache/o" -type f -name "*.a" -print 2>/dev/null | sort)
    rm -rf "$platform_check_dir"

    if [ "${#archives[@]}" -eq 0 ]; then
        echo "error: failed to locate built static archives for $label"
        find "$local_cache" -maxdepth 3 -type f | sort | tail -n 50
        exit 1
    fi
    if ! printf '%s\n' "${archives[@]}" | grep -Fq "/libghostty.a"; then
        echo "error: failed to locate built libghostty archive for $label"
        printf '%s\n' "${archives[@]}"
        exit 1
    fi

    local compat_source="$PROJECT_DIR/scripts/support/libcxx-verbose-abort-compat.c"
    local compat_object="$local_cache/libcxx-verbose-abort-compat.o"
    local object_staging="$local_cache/archive-objects"
    "$ZIG_BIN" cc -target "$zig_target" -Os -fno-sanitize=undefined -c "$compat_source" -o "$compat_object"
    rm -rf "$object_staging"
    mkdir -p "$object_staging"

    for archive in "${archives[@]}"; do
        local archive_label
        local extract_dir
        local object_index=0
        archive_label="$(basename "$archive" .a)"
        extract_dir="$object_staging/$archive_label"
        mkdir -p "$extract_dir"
        (cd "$extract_dir" && ar -x "$archive")

        while IFS= read -r object; do
            local staged_object="$object_staging/${archive_label}_${object_index}_$(basename "$object")"
            mv "$object" "$staged_object"
            chmod u+rw "$staged_object"
            objects+=("$staged_object")
            object_index=$((object_index + 1))
        done < <(find "$extract_dir" -type f -name "*.o" -print | sort)
    done

    if [ "${#objects[@]}" -eq 0 ]; then
        echo "error: failed to extract object files for $label"
        exit 1
    fi

    xcrun libtool -static -no_warning_for_no_symbols -o "$out/lib/libghostty.a" "${objects[@]}" "$compat_object"

    cp "$SOURCE_COPY/include/ghostty.h" "$out/include/ghostty.h"
    cat >"$out/include/module.modulemap" <<'EOF'
module libghostty {
    umbrella header "ghostty.h"
    export *
}
EOF

    echo "    -> $out"
}

build_ghostty_slice "aarch64-ios" "iphoneos-arm64" "2"
build_ghostty_slice "aarch64-ios-simulator" "iphonesimulator-arm64" "7" "apple_m1"

echo "--- Creating GhosttyKit.xcframework ---"
xcodebuild -create-xcframework \
    -library "$ARTIFACTS_DIR/iphoneos-arm64/lib/libghostty.a" \
    -headers "$ARTIFACTS_DIR/iphoneos-arm64/include" \
    -library "$ARTIFACTS_DIR/iphonesimulator-arm64/lib/libghostty.a" \
    -headers "$ARTIFACTS_DIR/iphonesimulator-arm64/include" \
    -output "$XCFRAMEWORK_PATH"

echo "--- Writing provenance ---"
python3 - "$PROJECT_DIR" "$GHOSTTY_SRC" "$PATCH_DIR" "$XCFRAMEWORK_PATH" "$PROVENANCE_PATH" "$ZIG_BIN" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

project = pathlib.Path(sys.argv[1])
ghostty = pathlib.Path(sys.argv[2])
patch_dir = pathlib.Path(sys.argv[3])
xcframework = pathlib.Path(sys.argv[4])
provenance_path = pathlib.Path(sys.argv[5])
zig_bin = sys.argv[6]

def run(args):
    return subprocess.check_output(args, text=True).strip()

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

patches = {
    path.name: sha256(path)
    for path in sorted(patch_dir.iterdir())
    if path.is_file() and path.name != "README.md"
}

slices = {
    str(path.relative_to(project)): sha256(path)
    for path in sorted(xcframework.glob("*/libghostty.a"))
}

data = {
    "ghostty": {
        "repository": "https://github.com/ghostty-org/ghostty.git",
        "commit": run(["git", "-C", str(ghostty), "rev-parse", "HEAD"]),
        "describe": run(["git", "-C", str(ghostty), "describe", "--tags", "--always"]),
    },
    "patches": patches,
    "tools": {
        "zig": run([zig_bin, "version"]),
        "zig_path": zig_bin,
        "xcodebuild": run(["xcodebuild", "-version"]),
    },
    "artifacts": slices,
}

provenance_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
(xcframework / "SSHAppGhostty.provenance.json").write_text(
    json.dumps(data, indent=2, sort_keys=True) + "\n"
)
PY

echo ""
echo "=== Ghostty build complete ==="
echo "Framework:  $XCFRAMEWORK_PATH"
echo "Provenance: $PROVENANCE_PATH"
