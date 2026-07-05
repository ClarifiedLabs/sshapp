# Third Party Notices

This file records third party code, data, and fonts that ship with SSH App.
The app also bundles the full license texts from `SSHApp/Resources/Legal/` and
shows them in Settings > Open Source Licenses.

| Dependency | Purpose | Source | Version / revision | License | Notice file |
| --- | --- | --- | --- | --- | --- |
| SSHAppGhostty wrapper | Local iOS Swift package wrapper for terminal emulation and rendering products, derived from libghostty-spm | `Packages/SSHAppGhostty`; derived from https://github.com/Lakr233/libghostty-spm | Derived from 1.2.8, revision `839f269bcd5193d03293cb6717ed2582dde265ef` | MIT | `SSHApp/Resources/Legal/libghostty-spm-mit.txt` |
| Ghostty / libghostty | Terminal core built locally into `Frameworks/GhosttyKit.xcframework` | https://github.com/ghostty-org/ghostty | Submodule revision `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` (Ghostty v1.3.1) | MIT | `SSHApp/Resources/Legal/ghostty-mit.txt` |
| iTerm2-Color-Schemes | Terminal color scheme data exposed by GhosttyTheme | https://github.com/mbadolato/iTerm2-Color-Schemes | Vendored through `Packages/SSHAppGhostty`, derived from libghostty-spm 1.2.8 | MIT | `SSHApp/Resources/Legal/iterm2-color-schemes-mit.txt` |
| MSDisplayLink | Display-link timing dependency used by GhosttyTerminal | https://github.com/Lakr233/MSDisplayLink | 2.1.0, revision `1ba3e769b734e456317fa7e45321fa7f53eefb67` | MIT | `SSHApp/Resources/Legal/msdisplaylink-mit.txt` |
| libssh2 | SSH protocol implementation used by the native transport layer | https://github.com/libssh2/libssh2 | Submodule revision `704299e997bf518375dc9222670c57b800ac59e6` | BSD-3-Clause | `SSHApp/Resources/Legal/libssh2-bsd-3-clause.txt` |
| OpenSSL | Cryptographic and TLS libraries used by libssh2 | https://github.com/openssl/openssl | Submodule revision `ce101e19abed882f8a66ec73f4f0c501435e4f1c` | Apache License 2.0 | `SSHApp/Resources/Legal/openssl-apache-2.0.txt` |
| JetBrains Mono | Bundled monospaced terminal font | https://github.com/JetBrains/JetBrainsMono | Bundled TTF files | SIL Open Font License 1.1 | `SSHApp/Resources/Legal/jetbrains-mono-ofl-1.1.txt` |

## Build-Only Tools

CMake is required to rebuild libssh2/OpenSSL with `scripts/build-libssh2.sh`.
Zig 0.15.2 is required to rebuild Ghostty with `scripts/build-ghostty-ios.sh`.
Neither tool is distributed in the app.

## Maintenance

When adding or updating a shipped dependency:

1. Update `SSHApp/Resources/Legal/ThirdPartyNotices.json`.
2. Add or update the matching license text in `SSHApp/Resources/Legal/`.
3. Update this table and `docs/DEPENDENCIES.md`.
4. Verify Settings > Open Source Licenses shows the dependency and full notice.
