# Dependencies

Shipped license notices live in `SSHApp/Resources/Legal/`, appear in Settings >
Licenses, and are inventoried in `THIRD_PARTY_NOTICES.md`.

## Runtime Dependencies

- `Packages/SSHAppGhostty` is the local Swift package. It exposes one product,
  `GhosttyTheme` (including vendored iTerm2-Color-Schemes data), whose closure
  includes the internal `GhosttyTerminal` target (UIKit input/lifecycle and
  app-owned Metal rendering). A single product keeps the app and hosted tests
  from loading duplicate ObjC classes.
- `GhosttyVT` wraps **libghostty-vt**, which owns terminal parsing, state,
  scrollback, and protocol encoding. It does not include Ghostty's full renderer,
  font stack, app/surface runtime, or platform embedding API.
- `libssh2` implements SSH; OpenSSL supplies `libcrypto`/`libssl`.
- JetBrains Mono is bundled as the default terminal font.

There are no remote Swift Package dependencies.

## Native Frameworks

- `make libssh2` builds `libssh2`, `libcrypto`, and `libssl` xcframeworks.
- `make ghostty-vt` builds `GhosttyVT.xcframework` and stages its C headers.

All frameworks contain arm64 iOS device and simulator slices. Builds require
pristine pinned submodules, apply local patches to disposable source copies,
and invalidate cached artifacts when build inputs or Xcode/SDK identity change.
Xcode validates VT artifacts without rebuilding; run `make setup` when they
are missing or stale.

See [../vendor/PINS.md](../vendor/PINS.md) for revisions, toolchain inputs, and
pin-update instructions. The VT lock is `vendor/libghostty-vt/native-lock.json`;
its `ghostty_revision` must match the `vendor/ghostty` gitlink.
