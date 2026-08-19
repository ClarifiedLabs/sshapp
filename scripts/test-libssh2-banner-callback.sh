#!/usr/bin/env bash
# Build and run the focused patched-libssh2 host test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_DIR/build-libssh2/libssh2-src"
BUILD_DIR="$PROJECT_DIR/build-libssh2/libssh2-host-test"

"$SCRIPT_DIR/build-libssh2.sh" --prepare-source-only

openssl_root="${OPENSSL_ROOT_DIR:-}"
if [ -z "$openssl_root" ] && command -v brew &>/dev/null; then
    openssl_root="$(brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null || true)"
fi

rm -rf "$BUILD_DIR"
cmake_args=(
    -S "$SOURCE_DIR"
    -B "$BUILD_DIR"
    -DCRYPTO_BACKEND=OpenSSL
    -DBUILD_SHARED_LIBS=OFF
    -DBUILD_STATIC_LIBS=ON
    -DBUILD_EXAMPLES=OFF
    -DBUILD_TESTING=ON
    -DENABLE_ZLIB_COMPRESSION=OFF
)
if [ -n "$openssl_root" ]; then
    cmake_args+=("-DOPENSSL_ROOT_DIR=$openssl_root")
fi

cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" --target test_userauth_banner_callback \
    -j"$(sysctl -n hw.logicalcpu)"
ctest --test-dir "$BUILD_DIR" --output-on-failure \
    -R '^test_userauth_banner_callback$'

bridge_test="$BUILD_DIR/tests/test_keyboard_interactive_bridge"
crypto_link=( -lcrypto )
if [ -n "$openssl_root" ]; then
    crypto_link=( "$openssl_root/lib/libcrypto.dylib" )
fi

"${CC:-cc}" \
    -std=gnu11 \
    -Wall -Wextra -Werror \
    -I"$PROJECT_DIR/SSHApp/SSH" \
    -I"$SOURCE_DIR/include" \
    "$PROJECT_DIR/scripts/test-keyboard-interactive-bridge.c" \
    "$PROJECT_DIR/SSHApp/SSH/CLibSSH2Shim.c" \
    "$BUILD_DIR/src/libssh2.a" \
    "${crypto_link[@]}" \
    -lz \
    -o "$bridge_test"
"$bridge_test"
