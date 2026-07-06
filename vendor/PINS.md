# Third-party dependency pins

Every third-party dependency is pinned to an immutable commit. This file is the
source of truth mapping each pinned commit to the release it corresponds to;
keep it in sync when bumping a submodule or SPM package.

## Vendored C libraries (git submodules)

Submodules are always pinned by the commit the superproject records; run
`git submodule status` to see the live pins. The table below records which
release tag each pinned commit corresponds to.

| Submodule        | Pinned commit                              | Release tag       |
| ---------------- | ------------------------------------------ | ----------------- |
| `vendor/openssl` | `8cf17aaeb4599f8af87fefd810b5b5fee90fe69e` | `openssl-3.5.7` (3.5 LTS) |
| `vendor/libssh2` | `a312b43325e3383c865a87bb1d26cb52e3292641` | `libssh2-1.11.1`  |
| `vendor/ghostty` | `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` | `v1.3.1`          |

Notes:
- OpenSSL is pinned to the 3.5 LTS release line (a supported, advisory-tracked
  branch) rather than an unreleased `master`/`-dev` snapshot.
- libssh2 is pinned to the `libssh2-1.11.1` release tag rather than a
  between-release development snapshot. libssh2's in-tree `LIBSSH2_VERSION`
  macro still carries a `_DEV` suffix at the release tag (the release version
  is finalized in the tarball, not committed to git); the pinned commit is the
  official 1.11.1 release.
- The libssh2/OpenSSL xcframeworks under `Frameworks/` are rebuilt from these
  pinned commits with `./scripts/build-libssh2.sh`.

## Swift Package Manager

| Package                          | Pinned commit                              | Release |
| -------------------------------- | ------------------------------------------ | ------- |
| `Lakr233/MSDisplayLink`          | `1ba3e769b734e456317fa7e45321fa7f53eefb67` | `2.1.0` |

Pinned by `revision:` in `Packages/SSHAppGhostty/Package.swift` (not by version
range), so the resolved commit is immutable.

## Updating a pin

1. In the submodule (or via the `revision:` in `Package.swift`), check out the
   new release tag's commit.
2. For the C libraries, rebuild the xcframeworks: `./scripts/build-libssh2.sh`.
3. Update the corresponding row above with the new commit and tag.
4. Run `git submodule status` and confirm each SHA matches its documented tag.
