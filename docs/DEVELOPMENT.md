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

### Opt-in live SSH smoke test

`LiveSSHSmokeUITests` exercises the real connection sheet, host-key prompt,
password authentication, terminal input, and rendered command output against a
live host. It skips during normal test runs unless
`SSHAPP_LIVE_SSH_DESTINATION` is present.

The reusable driver is in
`SSHAppUITests/Support/LiveSSHUITestHarness.swift`. New live tests can use its
environment configuration, prompt handling, secure paste input, OCR
assertions, screenshot attachments, tmux window discovery, pane targeting, and
scrollback helpers.

Configure the test process without putting credentials in source:

```bash
export SSHAPP_LIVE_SSH_DESTINATION='user@example.test'
read -rs SSHAPP_LIVE_SSH_PASSWORD
export SSHAPP_LIVE_SSH_PASSWORD
export SSHAPP_LIVE_SSH_ACCEPT_UNKNOWN_HOST=1
make test-live-ssh
```

`make test-live-ssh` runs only the smoke test. By default it creates and erases
a dedicated 13-inch iPad simulator, removes that simulator after the run, and
deletes the temporary test configuration and result bundles that can contain
sensitive state. Set `XCODE_DESTINATION` to an explicit simulator destination
to use and preserve an existing simulator instead.

A hard kill (for example `SIGKILL`) can leave the temp dir
(`${TMPDIR:-/tmp}/sshapp-live-ssh.*`) and the named simulator behind. The next
`make test-live-ssh` run reuses and erases the simulator, so leftovers are
mostly harmless; remove them manually with `rm -rf
${TMPDIR:-/tmp}/sshapp-live-ssh.*` and `xcrun simctl delete "SSHApp Live SSH
Smoke"` if you want them gone.

Optional variables:

- `SSHAPP_LIVE_SSH_TIMEOUT`: connection/assertion timeout in seconds
  (default: `45`).
- `SSHAPP_LIVE_SSH_SAVE_PASSWORD=1`: save the password in the simulator
  keychain for reconnect scenarios; the smoke test declines by default.
- `SSHAPP_LIVE_SSH_ENABLE_DEFAULT_TMUX=1`: enable the app's default tmux
  startup command.

Only set `SSHAPP_LIVE_SSH_ACCEPT_UNKNOWN_HOST=1` after independently verifying
the host fingerprint. Use a disposable dedicated simulator when accepting a
new host or saving credentials, and delete or erase it after the run. Result
bundles can contain simulator state and should be treated as sensitive even
though the harness does not attach or log the password.

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
