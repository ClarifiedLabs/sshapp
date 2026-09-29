# Third-party dependency pins

Every third-party dependency is pinned to an immutable commit. This file is the
source of truth mapping each pinned commit to its release or upstream snapshot;
keep it in sync when bumping a submodule or SPM package.

## Vendored C libraries (git submodules)

Submodules are always pinned by the commit the superproject records; run
`git submodule status` to see the live pins. The table below records which
release or upstream snapshot each pinned commit corresponds to.

| Submodule        | Pinned commit                              | Release / snapshot |
| ---------------- | ------------------------------------------ | ----------------- |
| `vendor/openssl` | `f4dc4d58b48d346a8270183f89acf826d459b0ca` | `openssl-3.5.8` (3.5 LTS) |
| `vendor/libssh2` | `2e1717456b8dd4c980e8e48d6dbfec524c2e62d1` | `1.11.2_DEV` upstream snapshot (2026-09-14)  |
| `vendor/ghostty` | `5de703a1b6ca0b91fcebe932b44be1df2de0a683` | Ghostty upstream snapshot; libghostty-vt source |

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

`vendor/libghostty-vt/native-lock.json` pins the Ghostty revision, checksum-verified
Zig toolchain, targets, and optimization settings. Its `ghostty_revision` must
match the submodule gitlink. Builds require a pristine checkout and apply
`vendor/libghostty-vt/patches/` to an exported source copy.

Upstream build files pin the transitive VT dependencies. See
[../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for their versions and notices.

## Swift Package Manager

`Packages/SSHAppGhostty` is local source with no external Swift package dependency.
Wrapper attribution is libghostty-spm 1.2.8, revision
`839f269bcd5193d03293cb6717ed2582dde265ef`; its Lakr MIT and theme licenses remain.

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
