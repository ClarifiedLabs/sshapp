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

`scripts/build-libssh2.sh` builds the SSH native submodules into:

- `Frameworks/libssh2.xcframework`
- `Frameworks/libcrypto.xcframework`
- `Frameworks/libssl.xcframework`

`scripts/build-ghostty-ios.sh` builds the pinned, patched Ghostty source into:

- `Frameworks/GhosttyKit.xcframework`

The build uses arm64 iOS device and arm64 iOS Simulator slices.

## Swift Package Versions

`SSHApp.xcodeproj/project.pbxproj` references `Packages/SSHAppGhostty` as a
local Swift Package. Current Swift Package dependencies are:

- `MSDisplayLink`: 2.1.0, revision `1ba3e769b734e456317fa7e45321fa7f53eefb67`

## Native Submodule Revisions

Native source revisions are managed as git submodules, pinned to release tags
(see `vendor/PINS.md` for the commit → release mapping):

- `vendor/libssh2`: `a312b43325e3383c865a87bb1d26cb52e3292641` (`libssh2-1.11.1`)
- `vendor/openssl`: `8cf17aaeb4599f8af87fefd810b5b5fee90fe69e` (`openssl-3.5.7`)
- `vendor/ghostty`: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` (`v1.3.1`)

Run `git submodule status` after submodule updates and refresh
`THIRD_PARTY_NOTICES.md` plus the in-app manifest when shipped dependencies
change. (OpenSSL's own nested test/fuzz submodules are intentionally not
initialized — they aren't needed to build the libraries.)
