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
| `vendor/ghostty` | `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` | `v1.3.1`          |

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

## Swift Package Manager

| Package                          | Pinned commit                              | Release |
| -------------------------------- | ------------------------------------------ | ------- |
| `Lakr233/MSDisplayLink`          | `1ba3e769b734e456317fa7e45321fa7f53eefb67` | `2.1.0` |

Pinned by `revision:` in `Packages/SSHAppGhostty/Package.swift` (not by version
range), so the resolved commit is immutable.

## Updating a pin

1. In the submodule (or via the `revision:` in `Package.swift`), check out the
   new release tag's commit or reviewed upstream commit.
2. Update the expected pins and provenance in `scripts/build-libssh2.sh`, rebase
   local patches, and synchronize dependency docs and shipped notices.
3. Stage the changed submodule gitlinks before running `make`: its `submodules`
   prerequisite checks out the commits recorded in the index.
4. Rebuild the xcframeworks and run `make libssh2-host-test`, `make test-release`,
   and `make test`.
5. Run `git submodule status` and confirm each SHA matches its documented pin.
