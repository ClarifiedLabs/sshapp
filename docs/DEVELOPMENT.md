# Development

Local setup, build commands, and the project map for SSH App.

## Requirements

- Xcode 27 (CI builds and tests with the iOS 27 SDK)
- iOS 18.0 deployment target
- CMake for rebuilding libssh2/OpenSSL (`brew install cmake`)
- Zig 0.15.2 for rebuilding Ghostty
- Apple silicon Mac for local simulator builds

CI uses GitHub's `xcode-27` runner image (currently in preview), selects Xcode 27
with `scripts/resolve-xcode.sh 27`, and keeps native framework and DerivedData
caches separate from the previous SDK major. The standard `macos-26` image still
ships Xcode 26; see the [runner announcement](https://github.com/actions/runner-images/issues/14404).
CI requires an iOS 27 simulator runtime rather than silently testing an older OS.
Use `IOS_SIMULATOR_RUNTIME_MAJOR=18 make test-unit` for a minimum-OS check when
that runtime is installed. The app's minimum deployment target remains iOS 18.

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
it with `XCODE_DESTINATION` when needed. The resolver only reuses an existing
device of the requested family: if none matches (for example only iPad
simulators exist), it creates a new iPhone simulator instead of picking a
foreign-family device.

## Tests

Run XCTest from the command line:

```bash
make test
```

Run release and native-build tooling regression tests:

```bash
make test-release
```

### Physical-device tests

Find the physical device UDID with `xcrun devicectl list devices`, then run:

```bash
DEVICE_UDID=<device-udid> make test-device
```

The runner builds a separately signed `dev.sshapp.devicetests.SSHApp` app with
its own Keychain and iCloud key-value store. It does not erase the device or
reset the production app. The test app remains installed. Set
`DEVICE_DEVELOPMENT_TEAM` to override the repository's signing team.

Source-structure tests explicitly skip on hardware because the Mac checkout is
unavailable there; `make test-unit` still executes them on the simulator. Bundled
resource and generated Info.plist checks run on both destinations.

Set the `SSHAPP_LIVE_SSH_*` variables described below to include real login,
command-output, and active-connection deletion tests. Credentials are injected
into a temporary test configuration with mode 0600, removed on exit, and excluded
from build/test subprocess environments. Live result bundles are deleted by
default because they can include test-environment and screen data; set
`SSHAPP_LIVE_SSH_KEEP_RESULTS=1` only when retaining diagnostic artifacts is needed.
Ordinary device results remain under `.build/ci/xcresults/`.

For a focused run, invoke `scripts/run-device-tests.py` with Xcode's
`-only-testing:<target>/<suite>/<test>` filters. Run one device test job at a time.
The live harness observes DEBUG-only prompt-kind accessibility values; it never
publishes passwords. It prepares the clipboard from the foreground test runner
and uses the terminal's normal Paste action. Command success is still checked
against rendered terminal output.

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
- `SSHAPP_LIVE_SSH_KEEP_RESULTS=1`: on failure, keep the temp dir with result
  bundles (including `.keepAlways` screenshot/OCR attachments) instead of
  deleting it; the runner prints the preserved path. Bundles can contain
  sensitive on-screen state, so inspect and delete them promptly.

Only set `SSHAPP_LIVE_SSH_ACCEPT_UNKNOWN_HOST=1` after independently verifying
the host fingerprint. Use a disposable dedicated simulator when accepting a
new host or saving credentials, and delete or erase it after the run. Result
bundles can contain simulator state and should be treated as sensitive even
though the harness does not attach or log the password.

### Saved-connection shortcuts

In Shortcuts, add SSH App's **Open Saved Connection** action and choose a saved
connection. Siri can also open a selected connection by name. The action brings
SSH App forward and waits for its app lock before using the normal connection
flow, including host verification, authentication, and any saved startup command.
Connection entities expose only their UUID and display name; the app does not
index connections or terminal output in Spotlight. Renaming a connection keeps
existing shortcuts working because they reference its UUID.

### iOS 27 device validation

Run `make test` on the dedicated iOS 27 simulator, then check a real iPhone/iPad:

- Resize iPhone Mirroring and iPad windows with direct SSH and tmux sessions;
  verify remote rows/columns, text sharpness, selection handles, and keyboard placement.
- Move the app between displays and exercise software and hardware keyboards.
- With multiple windows, deactivate one and verify its privacy cover does not
  obscure or uncover another window.
- Run a saved-connection shortcut on cold launch, while unlocked, and after the
  app-lock grace period expires. Verify it connects once, only after unlocking.
- Rename and delete a shortcut's saved connection and verify the updated label
  or missing-connection error.

## Native Frameworks

- `make setup` initializes submodules and builds native frameworks.
- `make libssh2` verifies pristine pinned libssh2/OpenSSL worktrees, applies
  the numbered `scripts/libssh2-patches/` files to a disposable source copy,
  and rebuilds all three frameworks when their embedded input provenance changes.
- `make libssh2-host-test` runs focused patched-libssh2 banner and
  keyboard-interactive bridge host tests; CI runs them before simulator tests.
- `make ghostty` builds `Frameworks/GhosttyKit.xcframework`, rebuilding when
  the Ghostty pin, build script, `scripts/ghostty-patches/`, or
  `scripts/support/` inputs change.
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
