# Development

Local setup, build commands, and the project map for SSH App.

## Requirements

- Xcode 27 (CI builds and tests with the iOS 27 SDK)
- iOS 18.0 deployment target
- CMake for rebuilding libssh2/OpenSSL (`brew install cmake`)
- Python 3 for the VT builder, which downloads checksum-pinned Zig 0.17.1
- Apple silicon Mac for local simulator builds

CI requires an iOS 27 simulator runtime. For a minimum-OS check with an installed
runtime, use `IOS_SIMULATOR_RUNTIME_MAJOR=18 make test-unit`.

See [VT_RENDERER.md](VT_RENDERER.md) for terminal architecture and benchmarks.

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

The simulator resolver chooses an available runtime and device of the requested
family. Override the destination with `XCODE_DESTINATION` when needed.

## Tests

Run XCTest from the command line:

```bash
make test
```

The runner erases and boots a dedicated simulator and disables its hardware
keyboard for software-keyboard tests. An explicit `XCODE_DESTINATION` bypasses
this preparation; configure that simulator yourself.

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

Device tests use screenshots to avoid an iPadOS 27 SpringBoard issue with
XCTest screen recording. The runner stops stalled tests; override the default
1200-second idle timeout with `DEVICE_TEST_IDLE_TIMEOUT`.

Keep logic-only tests in `SSHAppTests`, with shared helpers in
`SSHAppSharedTestSupport/`.

### Opt-in live SSH smoke test

`LiveSSHSmokeUITests` exercises the real connection sheet, host-key prompt,
password authentication, terminal input, and rendered command output against a
live host. It skips during normal test runs unless
`SSHAPP_LIVE_SSH_DESTINATION` is present.
Shared live-test helpers are in `SSHAppUITests/Support/LiveSSHUITestHarness.swift`.

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

### iPhone Duo layout tests

The general simulator resolver deliberately excludes iPhone Duo because its
safe-area and rotation behavior do not fit the existing fixed-size benchmarks.
Use a separately prepared Duo simulator and opt in explicitly:

```bash
xcrun simctl list devices available
xcrun simctl boot <duo-udid>
make test-ui-duo XCODE_DESTINATION="platform=iOS Simulator,id=<duo-udid>"
```

`test-ui-duo` requires `XCODE_DESTINATION`; it validates that the UDID belongs
to an available iPhone Duo and never invokes the general resolver or silently
creates a device. As with other explicit destinations, the runner does not erase
or configure that simulator. Prepare its hardware-keyboard state
manually. `SSHAppDuoLayoutTests.xctestplan` runs only `DuoLayoutUITests`; those
tests skip in ordinary UI-test plans and use network-free direct/tmux fixtures.
The Duo launch helper does not request the unsupported portrait/landscape pair.

On iOS 27.1 and later, `AdaptiveSessionToolbar` uses `toolbarVerticalEdge` and
`ToolbarItemAxisBehavior` to choose either the horizontal `UnifiedTopBar` or
standard vertical system items. Earlier releases retain the horizontal toolbar.
The switcher presentation and new-tab action are shared by both presentations.
The `TerminalTab` `ZStack` stays outside the adaptive chrome, and
`TerminalKeyboardBar` remains a bottom safe-area accessory.

A regular-width `NavigationSplitView` sidebar was evaluated and is intentionally
not shipped: the existing one-action switcher preserves all session navigation,
while a permanent or collapsible split would reduce terminal width and add
presentation state without measured benefit. This decision can be revisited with
user evidence; any future sidebar must remain hideable and retain the switcher.

#### Duo Device Hub matrix

Record outer/inner and horizontal/vertical screenshots for each applicable row.
Verify direct SSH and tmux selection, terminal identity/scrollback, remote
rows/columns, keyboard focus, selection handles, and absence of reconnects.
Include long connection names, larger Dynamic Type, app lock, and keyboard
shown/hidden/suppressed variations.

| Area | Required checks |
| --- | --- |
| Closed / outer display | System vertical controls; home, editor, settings, direct and tmux terminals |
| Open / inner portrait | Horizontal chrome where supplied by the system; retained terminal state |
| Open / inner landscape | Vertical chrome; terminal and keyboard accessory geometry |
| Partially folded | Find, progress, connection status, tmux banners/dividers, and fold clearance |
| Split View | Left and right placements, compact and regular widths, switcher reachability |
| Input | Keyboard show/hide/suppress/restore, hardware keyboard, focus preservation |

The initial automated baseline captured the closed pose: the outer display used
the old horizontal gear before the change and system vertical controls after it;
the inner display was inactive. That evidence does **not** confirm an open or
partial-fold occlusion, so no speculative `ReservedRegion` production inset was
added. Complete the open/partial-fold and Split View rows interactively in
**Device Hub** before claiming fold coverage. If system containers leave an
important control occluded, add a focused geometry regression test and adjust
only the affected terminal viewport/overlays; never synthesize remote tmux
splits or reconnect from pose changes.

## Native Frameworks

- `make setup` initializes pinned submodules and builds all native frameworks.
- `make libssh2` builds libssh2/OpenSSL; `make ghostty-vt` builds libghostty-vt.
- `make libssh2-host-test` runs the patched SSH authentication bridge tests.
- `make clean-libssh2` / `make clean-ghostty-vt` remove the respective artifacts.
- `make clean` removes all native frameworks but retains the Zig download/build
  cache under `.build/ghostty-vt/`.

Builds require pristine pinned submodules and apply local patches to disposable
source copies. Frameworks contain arm64 device and simulator slices, live under
`Frameworks/`, and are ignored by git. Run `make setup` if Xcode reports missing
or stale artifacts.

The VT source is pinned to libghostty-vt 1.0.0, tag `vt-1.0.0`
(`0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec`), and built with Zig 0.17.1
in `ReleaseSafe` mode. The library version is independent of Ghostty's app version.
All ten prior local patches remain; patch 0011 updates translate-c to 2.0.2; see [VT_RENDERER.md](VT_RENDERER.md#native-patches).

See [DEPENDENCIES.md](DEPENDENCIES.md) for build inputs and
[../vendor/PINS.md](../vendor/PINS.md) for pin updates.

## Architecture

- Terminal rendering uses the local `SSHAppGhostty` package's `GhosttyTheme`
  product, which links the internal `GhosttyTerminal` and `GhosttyVT` targets.
- `GhosttyTerminalView` and `TmuxPaneTerminal` feed ordered SSH/tmux streams into
  the actor-owned VT backend without a local PTY. The app-owned Metal renderer
  consumes owned snapshots; UIKit owns input, selection, and lifecycle hosting.
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
SSHAppSharedTestSupport/  Pure test helpers compiled into both test targets
scripts/            Native framework and build metadata scripts
tools/              Release helper and regression checks
Frameworks/         Generated xcframeworks
```

## Dependencies

- Submodule-pinned libghostty-vt plus `Packages/SSHAppGhostty` for terminal state,
  app-owned rendering/hosting, and themes
- [libssh2](https://github.com/libssh2/libssh2) as an xcframework for the SSH
  protocol implementation
- OpenSSL, built alongside libssh2, for native crypto/TLS libraries
- SwiftData for saved connections
- CryptoKit for key-related operations

See `docs/DEPENDENCIES.md` and `THIRD_PARTY_NOTICES.md` for current dependency
versions and shipped license notices.
