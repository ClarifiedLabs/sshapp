#!/usr/bin/env bash
#
# build-libssh2.sh — Cross-compile OpenSSL + libssh2 for iOS → xcframeworks
#
# Prerequisites: Xcode command-line tools, CMake (brew install cmake)
# Usage: ./scripts/build-libssh2.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build-libssh2"
FRAMEWORKS_DIR="$PROJECT_DIR/Frameworks"

OPENSSL_SRC="$PROJECT_DIR/vendor/openssl"
LIBSSH2_SRC="$PROJECT_DIR/vendor/libssh2"

IOS_MIN_VERSION="18.0"

echo "=== Build configuration ==="
echo "OpenSSL source: $OPENSSL_SRC"
echo "libssh2 source: $LIBSSH2_SRC"
echo "Build dir:      $BUILD_DIR"
echo "Output:         $FRAMEWORKS_DIR"
echo ""

# Check prerequisites
if [ ! -d "$OPENSSL_SRC/Configure" ] && [ ! -f "$OPENSSL_SRC/Configure" ]; then
    echo "error: OpenSSL source not found. Run: git submodule update --init"
    exit 1
fi
if [ ! -d "$LIBSSH2_SRC/CMakeLists.txt" ] && [ ! -f "$LIBSSH2_SRC/CMakeLists.txt" ]; then
    echo "error: libssh2 source not found. Run: git submodule update --init"
    exit 1
fi
if ! command -v cmake &>/dev/null; then
    echo "error: cmake not found. Install: brew install cmake"
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Build OpenSSL
# ─────────────────────────────────────────────────────────────────────────────

build_openssl() {
    local OPENSSL_TARGET="$1"
    local LABEL="$2"
    local MIN_VERSION_FLAG="$3"
    local OUT="$BUILD_DIR/openssl-${LABEL}"

    echo "--- Building OpenSSL ($LABEL) [target: $OPENSSL_TARGET] ---"
    mkdir -p "$OUT"

    # OpenSSL needs a clean source tree per build, so we copy
    local SRC_COPY="$BUILD_DIR/openssl-src-${LABEL}"
    rsync -a --exclude='.git' "$OPENSSL_SRC/" "$SRC_COPY/"

    pushd "$SRC_COPY" > /dev/null

    ./Configure "$OPENSSL_TARGET" \
        no-shared no-tests no-ui-console no-asm no-engine \
        "$MIN_VERSION_FLAG" \
        --prefix="$OUT"

    make -j"$(sysctl -n hw.logicalcpu)" > /dev/null 2>&1
    make install_sw > /dev/null 2>&1

    popd > /dev/null
    rm -rf "$SRC_COPY"

    echo "    → $OUT"
}

# OpenSSL needs an explicit minimum OS flag per platform slice. Simulator builds
# are arm64-only because local development and CI both run on Apple silicon.
build_openssl ios64-xcrun                iphoneos-arm64        "-mios-version-min=$IOS_MIN_VERSION"
build_openssl iossimulator-arm64-xcrun   iphonesimulator-arm64 "-mios-simulator-version-min=$IOS_MIN_VERSION"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Build libssh2
# ─────────────────────────────────────────────────────────────────────────────

build_libssh2() {
    local ARCH="$1"
    local LABEL="$2"  # e.g. "iphoneos-arm64"
    local SDK="$3"    # "iphoneos" or "iphonesimulator"
    local OUT="$BUILD_DIR/libssh2-${LABEL}"
    local OPENSSL_PREFIX="$BUILD_DIR/openssl-${LABEL}"
    local CMAKE_BUILD="$BUILD_DIR/libssh2-cmake-${LABEL}"

    echo "--- Building libssh2 ($LABEL) ---"
    mkdir -p "$OUT" "$CMAKE_BUILD"

    local SDK_PATH
    SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"

    cmake -S "$LIBSSH2_SRC" -B "$CMAKE_BUILD" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN_VERSION" \
        -DCMAKE_INSTALL_PREFIX="$OUT" \
        -DCRYPTO_BACKEND=OpenSSL \
        -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DENABLE_ZLIB_COMPRESSION=OFF \
        > /dev/null 2>&1

    cmake --build "$CMAKE_BUILD" --config Release -j"$(sysctl -n hw.logicalcpu)" > /dev/null 2>&1
    cmake --install "$CMAKE_BUILD" > /dev/null 2>&1

    echo "    → $OUT"
}

build_libssh2 arm64  iphoneos-arm64           iphoneos
build_libssh2 arm64  iphonesimulator-arm64    iphonesimulator

# ─────────────────────────────────────────────────────────────────────────────
# 3. Create xcframeworks
# ─────────────────────────────────────────────────────────────────────────────

echo "--- Creating xcframeworks ---"
rm -rf "$FRAMEWORKS_DIR/libcrypto.xcframework" \
       "$FRAMEWORKS_DIR/libssl.xcframework" \
       "$FRAMEWORKS_DIR/libssh2.xcframework"
mkdir -p "$FRAMEWORKS_DIR"

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

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Build complete ==="
echo "Frameworks:"
ls -d "$FRAMEWORKS_DIR"/*.xcframework 2>/dev/null || echo "  (none)"
echo ""
echo "You can now open the Xcode project and build."
