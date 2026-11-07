# Third-party dependency pins

Native third-party sources are pinned to immutable commits or verified archive
hashes. This file maps each pin to its release or upstream snapshot; keep it in
sync when updating a submodule, native dependency override, or vendored catalog.

## Vendored C libraries (git submodules)

Submodules are always pinned by the commit the superproject records; run
`git submodule status` to see the live pins. The table below records which
release or upstream snapshot each pinned commit corresponds to.

| Submodule        | Pinned commit                              | Release / snapshot |
| ---------------- | ------------------------------------------ | ----------------- |
| `vendor/openssl` | `45e844fa2a14ec92d146bd8f5778ac130b6625fb` | `openssl-3.5.9` (3.5 LTS) |
| `vendor/libssh2` | `6125bfe552b3a8c7340c2fb3b82cdf65b0e16f9d` | `1.11.2_DEV` upstream snapshot (2026-11-06)  |
| `vendor/ghostty` | `0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec` | `vt-1.0.0`; libghostty-vt 1.0.0 |

Notes:
- OpenSSL is pinned to the 3.5 LTS release line (a supported, advisory-tracked
  branch) rather than an unreleased `master`/`-dev` snapshot.
- libssh2 is pinned to an immutable upstream `master` snapshot to take the full
  set of transport, cryptographic, and memory-safety fixes since 1.11.1. It
  identifies as `1.11.2_DEV`; this is not a released 1.11.2 or a moving branch
  reference. The immutable submodule is copied and built with the rebased
  numbered local patch set in `scripts/libssh2-patches/`.
- The libssh2/OpenSSL xcframeworks under `Frameworks/` are rebuilt from these
  pinned commits with `./scripts/build-libssh2.sh`, which rejects modified or
  untracked submodule inputs. Embedded provenance covers both commits, the build
  recipe, deployment target, and local patches.
- Ghostty is marked `shallow = true`. `make submodules` fetches it with
  `git submodule update --init --depth 1 -- vendor/ghostty` so a pin that is not
  a branch tip is fetched by SHA without Ghostty's full history.

## Ghostty VT source and toolchain

Eleven numbered `vendor/libghostty-vt/patches/*.patch` files extend the native VT API,
pin transitive sources, and harden terminal parsing. All eleven remain necessary
with `vt-1.0.0`; see [../docs/VT_RENDERER.md](../docs/VT_RENDERER.md#native-patches)
for the patch audit. Upstream's stable ABI does not cover these local extensions.

`vendor/libghostty-vt/native-lock.json` pins the Ghostty revision, checksum-verified
Zig 0.17.1 toolchain, targets, and `ReleaseSafe` optimization. It also pins
`libghostty_version` independently of the Ghostty app version; both build version
strings are explicit so exported sources cannot detect SSHApp's tags.
Its `ghostty_revision` must
match the submodule gitlink. Builds require a pristine checkout and apply
`vendor/libghostty-vt/patches/` to an exported source copy. The builder also applies
Ghostty's pinned `nix/patches/zig-0.17-ios-process-replace.patch` to the extracted
Zig standard library before compiling for iOS.

Upstream build files pin the transitive VT dependencies. See
[../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for their versions and notices.

Patch `0010-bound-program-status-capture.patch` enforces OSC 7501's 4 KiB
whole-sequence limit while capturing its body, rather than only at termination.
It preserves smaller caller limits and discards oversized input without changing
OSC framing or the limits for other commands. The patch includes native parser
regressions; `VTTerminalSessionTests` covers stream recovery through the app bridge.
This is a local hardening patch; no upstream submission has been made.

## VT transitive overrides

Patch `0008-update-simdutf.patch` compiles the upstream simdutf 9.3.3
amalgamation (release source revision `59589cd3df6823cbfdbd253cde3377e7c3e1fe9b`)
instead of Ghostty's vendored 9.0.0 copy. The release archive is
content-hash pinned in the patched `pkg/simdutf/build.zig.zon`:
`N-V-__8AADG6NwAANUG6gCuneSyVze1R9k8ZVJXCD7kS511t`.
The archive SHA-256 is
`33b0be36ae5ce011d0ed4ec80a74871108b67741061f3551871bbad6a1078f45`.

Patch `0009-update-highway.patch` pins Highway 1.4.0 to revision
`2607d3b5b0113992fe84d3848859eae13b3b52c1` instead of Ghostty's 1.2.0 snapshot.
The patched `pkg/highway/build.zig.zon` verifies content hash
`N-V-__8AAD_MkACxo3rELIYCI7ap_7GsxHN1WH6AsMLDYp6L`.
Ghostty supplies the local dispatch shim; its AArch64 target bits match
Highway 1.4.0.

Patch `0011-update-translate-c.patch` pins translate-c 2.0.2 to revision
`c11030012dc325d446474d17b78c242fd1d622ec`, replacing Ghostty's 2.0.0 pin.
The commit archive is verified by Zig content hash
`translate_c-2.0.2-Q_BUWvBNBwBgPKQJPblip6M7AHNK_IPNPmyv4rSIQMQc`.
Generated Wuffs bindings import its runtime helpers; translate-c and its pinned
aro parser remain build-only tools.

## Swift Package Manager

`Packages/SSHAppGhostty` is local source with no external Swift package dependency.
Wrapper attribution is libghostty-spm 1.2.8, revision
`839f269bcd5193d03293cb6717ed2582dde265ef`; its Lakr MIT and theme licenses remain.

## Theme catalog

The 890-entry iTerm2-Color-Schemes catalog uses release
`release-20261102-150615-3d8a6a1`, revision
`3d8a6a1a983d7fe721aa6cb9a5b98066cd74303a`. Generated Swift data lives in
`Packages/SSHAppGhostty/Sources/GhosttyTheme/Themes/`. The generation recipe is
`Script/generate-themes.sh` from libghostty-spm revision
`a5785e01166131f0012280f1fa05a74a7402f29b`; its Python generator was run against
the pinned release's `ghostty-themes.tgz`, without its moving-branch downloader.
The archive SHA-256 is
`b61b297e4245e0a5e46ac1e8d92ec8f7390d4394db4bafc93cfa3209f215435e`.
All 657 prior theme names remain; 233 were added and four existing themes
were refreshed (Atom One Light, Clear Light, EVH FrankenTone, and Vercel).

## Updating a pin

1. For a submodule, check out the new release tag's commit or reviewed upstream
   commit. For VT, check out the reviewed commit in `vendor/ghostty`, set the same
   `ghostty_revision` in `vendor/libghostty-vt/native-lock.json`, rebase native
   patches, and re-audit the statically linked dependency/license closure.
2. Update the expected pins and provenance in `scripts/build-libssh2.sh`, rebase
   local patches, and synchronize dependency docs and shipped notices.
3. Stage the changed submodule gitlinks before running `make`: its `submodules`
   prerequisite checks out the commits recorded in the index.
4. Rebuild the xcframeworks and run `make libssh2-host-test`, `make test-release`,
   and `make test`.
5. Run `git submodule status` and confirm each SHA matches its documented pin.
