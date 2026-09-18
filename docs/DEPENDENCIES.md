# Dependencies

Dependency purpose, build location, and current versions. Shipped license notices
live in `SSHApp/Resources/Legal/`, appear in Settings > Open Source Licenses,
and are inventoried in `THIRD_PARTY_NOTICES.md`.

## Runtime Dependencies

- `Packages/SSHAppGhostty` provides the local iOS Swift Package integration for
  Ghostty terminal rendering. The app uses its `GhosttyTerminal` and
  `GhosttyTheme` products.
- `vendor/ghostty` is the pinned upstream Ghostty source used to build the
  local `libghostty` core for VT parsing, terminal state, font handling, and
  Metal rendering.
- `iTerm2-Color-Schemes` data is vendored through `GhosttyTheme` so the
  terminal can offer a broad theme catalog.
- `MSDisplayLink` is a direct Swift Package dependency used by
  `Packages/SSHAppGhostty` for display-link timing.
- `libssh2` implements the SSH protocol used by `SSHApp/SSH/SSH2Transport.swift`.
- `OpenSSL` is built alongside `libssh2` and supplies `libcrypto`/`libssl`.
- JetBrains Mono is bundled as the default terminal font.

## Native Frameworks

`scripts/build-libssh2.sh` verifies the immutable SSH native submodule pins,
rejects modified or untracked submodule inputs, applies
`scripts/libssh2-patches/` to a disposable libssh2 source copy, and builds:

- `Frameworks/libssh2.xcframework`
- `Frameworks/libcrypto.xcframework`
- `Frameworks/libssl.xcframework`

`scripts/build-ghostty-ios.sh` builds the pinned, patched Ghostty source into:

- `Frameworks/GhosttyKit.xcframework`

The build uses arm64 iOS device and arm64 iOS Simulator slices. Embedded
provenance invalidates all three SSH/OpenSSL frameworks when a pin, patch, or
build-recipe input changes.

## Swift Package Versions

`SSHApp.xcodeproj/project.pbxproj` references `Packages/SSHAppGhostty` as a
local Swift Package. Current Swift Package dependencies are:

- `MSDisplayLink`: 2.1.0, revision `1ba3e769b734e456317fa7e45321fa7f53eefb67`

## Native Submodule Revisions

Native source revisions are managed as git submodules, pinned to release tags
or reviewed upstream snapshots (see `vendor/PINS.md` for the mapping):

- `vendor/libssh2`: `2e1717456b8dd4c980e8e48d6dbfec524c2e62d1` (`1.11.2_DEV`, upstream snapshot from 2026-09-14)
- `vendor/openssl`: `f4dc4d58b48d346a8270183f89acf826d459b0ca` (`openssl-3.5.8`, 3.5 LTS)
- `vendor/ghostty`: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` (`v1.3.1`)

Run `git submodule status` after submodule updates and refresh
`THIRD_PARTY_NOTICES.md` plus the in-app manifest when shipped dependencies
change. (OpenSSL's own nested test/fuzz submodules are intentionally not
initialized — they aren't needed to build the libraries.)
