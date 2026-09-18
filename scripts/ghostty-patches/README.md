# Ghostty Patches

This directory is the single place for local upstream Ghostty patches used by
SSHApp's local Ghostty build pipeline.

## Rules

- Keep patches numbered so they apply in a stable order.
- Prefer standard unified diff files (`.patch`) when the upstream context is
  stable. Do not use Git binary patches; generated binary data should be built
  locally or checked in as an explicitly reviewed source artifact.
- Use executable patch scripts (`.sh`) only when upstream context is too
  unstable for a reliable diff.
- Executable patch scripts in this directory must be safe to re-run.
- Patches here are applied automatically by `scripts/build-ghostty-ios.sh`.

## iOS build artifacts

`0001-darwin-libghostty-install.sh` installs the static embedded library used by
SSHApp and excludes the standalone `libghostty-vt` dylib from the default iOS
build (device and simulator). SSHApp does not consume that dylib; linking it
unnecessarily builds Zig 0.15.2's bundled libc++, which fails with the iOS 27
SDK. The explicit upstream VT build step remains available.

## Current goal

This patch workflow exists so we can carry host-managed IO work required for
sandboxed iOS integration without hiding upstream modifications inside ad-hoc
build script edits.
