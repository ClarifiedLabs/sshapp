# Development

Local setup, build commands, and the project map for SSH App.

## Requirements

- Xcode 26 or later
- iOS 18.0 deployment target
- CMake for rebuilding libssh2/OpenSSL (`brew install cmake`)
- Zig 0.15.2 for rebuilding Ghostty
- Apple silicon Mac for local simulator builds

The terminal core is built locally from the pinned `vendor/ghostty` submodule
with SSHApp's patch set in `scripts/ghostty-patches/`. Swift code for the
iOS-only wrapper lives in `Packages/SSHAppGhostty`.

## Local Setup

Clone, build native frameworks, then open Xcode (`make setup` initializes the
submodules for you):

```bash
git clone https://github.com/ClarifiedLabs/sshapp.git
cd sshapp
make setup
open SSHApp.xcodeproj
```

Xcode resolves Swift packages automatically. If it does not, use
`File > Packages > Resolve Package Versions`.

## Command Line Build

```bash
make build
```

The default simulator destination is
resolved from the available local iOS Simulator runtimes and devices. Override
it with `XCODE_DESTINATION` when needed.

## Tests

Run XCTest from the command line:

```bash
make test
```

Run release and native-build tooling regression tests:

```bash
make test-release
```

## Native Frameworks

- `make setup` initializes submodules and builds native frameworks.
- `make libssh2` builds libssh2/OpenSSL only when
  `Frameworks/libssh2.xcframework` is missing.
- `make ghostty` builds `Frameworks/GhosttyKit.xcframework` only when missing.
- `make clean-libssh2` removes generated libssh2/OpenSSL frameworks.
- `make clean-ghostty` removes generated Ghostty output.
- `make clean` removes generated native frameworks and native build output.
- The build emits `arm64` iOS device and `arm64` iOS Simulator slices only.
- The xcframeworks are link inputs. `SSHApp/SSH/CSSH2/module.modulemap` exposes
  libssh2 headers from `vendor/libssh2/include`; `Packages/SSHAppGhostty`
  imports libghostty through `Frameworks/GhosttyKit.xcframework`.

Generated framework artifacts live under `Frameworks/` and are ignored by git.

## Architecture

- Terminal rendering uses the local `SSHAppGhostty` package's
  `GhosttyTerminal` and `GhosttyTheme` products.
- `GhosttyTerminalView` and `TmuxPaneTerminal` use `InMemoryTerminalSession` so
  SSH and tmux streams can feed terminal surfaces without a local PTY.
- `TerminalRuntime` owns shared terminal font, cursor, and theme state.
- libssh2 handles SSH transport, authentication, channels, writes, and resize
  messages.
- SwiftData stores saved connections; Keychain stores credentials and keys.

## Project Structure

```text
SSHApp/App/          App entry point, commands, and runtime startup
SSHApp/Views/        SwiftUI shell, settings, terminal bridges, tmux pane UI
SSHApp/Models/       SwiftData models, tab state, tmux value/observable models
SSHApp/Services/     Connection persistence, Keychain, key metadata
SSHApp/SSH/          libssh2 transport, sessions, channels, tmux protocol code
SSHApp/Theme/        Shared terminal runtime, fonts, palette
SSHApp/Resources/    Legal notices and bundled app resources
SSHApp/Fonts/        Bundled terminal fonts
SSHAppTests/         Unit tests
SSHAppUITests/       UI tests
scripts/            Native framework and build metadata scripts
tools/              Release helper and regression checks
Frameworks/         Generated xcframeworks
```

## Dependencies

- `vendor/ghostty` plus `Packages/SSHAppGhostty` for terminal emulation,
  rendering, themes, and display-link timing
- [libssh2](https://github.com/libssh2/libssh2) as an xcframework for the SSH
  protocol implementation
- OpenSSL, built alongside libssh2, for native crypto/TLS libraries
- SwiftData for saved connections
- CryptoKit for key-related operations

See `docs/DEPENDENCIES.md` and `THIRD_PARTY_NOTICES.md` for current dependency
versions and shipped license notices.
