# Repository Guidelines

## Project Map

`SSHApp/` is the SwiftUI iOS app: `App/` startup, `Views/` UI and terminal bridges, `Models/` SwiftData state, `Services/` persistence/keychain, `SSH/` libssh2/session code, and `Theme/` shared terminal styling/runtime. Tests live in `SSHAppTests/` and `SSHAppUITests/`. Native dependencies are generated under `Frameworks/` from `vendor/` sources via `scripts/`. See `docs/DEVELOPMENT.md` for architecture detail.

## Commands

- `make setup`: initialize submodules and build libssh2/OpenSSL xcframeworks.
- `make libssh2` / `make clean-libssh2`: rebuild or remove native frameworks.
- `xcodebuild -resolvePackageDependencies -project SSHApp.xcodeproj`: resolve SPM dependencies.
- `make build`: simulator build using the default `iPhone 17 Pro` destination.
- `make test`: unit and UI tests using the default `iPhone 17 Pro` destination.
- `make test-release`: release/native build tooling regression tests.

## Code And Tests

Use Swift 6-compatible SwiftUI, four-space indentation, existing organization, `UpperCamelCase` types, and `lowerCamelCase` members. Keep C interop in `SSHApp/SSH/`. Do not add backwards compatibility or migration work unless requested. When fixing a bug, add an XCTest regression test and keep SSH concurrency/freeze invariants explicit.

Ask before adding new third party dependencies.

## Git And PRs

Use conventional commit messages. Do not create draft PRs. PRs should summarize user-visible changes, note native framework rebuilds, list simulator/device coverage, and include screenshots or recordings for UI changes. Do not commit generated build products unless intentionally updating a tracked artifact.
