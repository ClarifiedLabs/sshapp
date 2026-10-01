# Third Party Notices

This file records third party code, data, and fonts that ship with SSH App.
The app also bundles the full license texts from `SSHApp/Resources/Legal/` and
shows them in Settings > Licenses.

| Dependency | Purpose | Source | Version / revision | License | Notice file |
| --- | --- | --- | --- | --- | --- |
| SSHAppGhostty wrapper | Local iOS Swift package wrapper for GhosttyTerminal and GhosttyTheme, derived from libghostty-spm. | Packages/SSHAppGhostty; derived from https://github.com/Lakr233/libghostty-spm | Derived from libghostty-spm 1.2.8, revision 839f269bcd5193d03293cb6717ed2582dde265ef | MIT License | `SSHApp/Resources/Legal/libghostty-spm-mit.txt` |
| Ghostty / libghostty-vt | VT parsing, terminal state, input encoding, and Kitty graphics decoding; rendering and UIKit hosting are app-owned. | https://github.com/ghostty-org/ghostty | Revision 33da6848d63b3bba2b4f31ab1531d618f2795192, the vendor/ghostty submodule pin recorded in vendor/libghostty-vt/native-lock.json | MIT License | `SSHApp/Resources/Legal/ghostty-mit.txt` |
| uucode | Unicode properties and grapheme segmentation used by libghostty-vt. | https://github.com/jacobsandlund/uucode | 0.2.0, revision 9d55524551411b493cca41ca06363625d90aff1e | MIT License | `SSHApp/Resources/Legal/uucode-mit.txt` |
| Unicode Character Database | Unicode property tables compiled into libghostty-vt through uucode. | https://www.unicode.org/ucd/ | Unicode 18.0.0, bundled by the pinned uucode source | Unicode License V3 | `SSHApp/Resources/Legal/unicode-v3.txt` |
| Wuffs | Kitty graphics image decoding, pixel conversion, and alpha blending in libghostty-vt. | https://github.com/google/wuffs | Revision 7411f488fe2e2c205c3d3b3d28638b7356522930 | MIT / Apache License 2.0 | `SSHApp/Resources/Legal/wuffs-mit-apache-2.0.txt` |
| simdutf | SIMD UTF-8 and Base64 operations in libghostty-vt. | https://github.com/simdutf/simdutf | 9.2.1 upstream amalgamation, pinned by vendor/libghostty-vt/patches/0008-update-simdutf.patch | MIT / Apache License 2.0; bundled BSD notices | `SSHApp/Resources/Legal/simdutf-notices.txt` |
| Highway | Portable SIMD dispatch and terminal scanning in libghostty-vt. | https://github.com/google/highway | 1.4.0, revision 2607d3b5b0113992fe84d3848859eae13b3b52c1 | Apache License 2.0 / BSD-3-Clause | `SSHApp/Resources/Legal/highway-apache-2.0-bsd.txt` |
| Zig standard library and runtimes | Standard library, compiler runtime, and safety runtime code statically linked into libghostty-vt. | https://ziglang.org/ | 0.16.0, toolchain archive pinned by vendor/libghostty-vt/native-lock.json | MIT License; accompanying math notices | `SSHApp/Resources/Legal/zig-runtime-notices.txt` |
| iTerm2-Color-Schemes | Terminal color scheme data exposed through the GhosttyTheme catalog. | https://github.com/mbadolato/iTerm2-Color-Schemes | September 28, 2026 release, revision 99d9701ba3cf4a06d24eea6ca4f25a64656b446b | MIT License | `SSHApp/Resources/Legal/iterm2-color-schemes-mit.txt` |
| libssh2 | SSH protocol implementation used by the native SSH transport layer. | https://github.com/libssh2/libssh2 | 1.11.2_DEV upstream snapshot, revision 2e1717456b8dd4c980e8e48d6dbfec524c2e62d1 | BSD-3-Clause | `SSHApp/Resources/Legal/libssh2-bsd-3-clause.txt` |
| OpenSSL | TLS and cryptographic primitives used by libssh2 through libcrypto and libssl. | https://github.com/openssl/openssl | OpenSSL 3.5.9 LTS, revision 45e844fa2a14ec92d146bd8f5778ac130b6625fb | Apache License 2.0 | `SSHApp/Resources/Legal/openssl-apache-2.0.txt` |
| JetBrains Mono | Bundled monospaced terminal font. | https://github.com/JetBrains/JetBrainsMono | Bundled TTF files | SIL Open Font License 1.1 | `SSHApp/Resources/Legal/jetbrains-mono-ofl-1.1.txt` |

## VT license provenance

The inventory covers the VT-only build specified by
`vendor/libghostty-vt/native-lock.json`, including all nine `vendor/libghostty-vt/patches/` files and statically
linked dependencies. It includes Zig runtime code and uucode's Unicode data.

When refreshing notices, use the pinned dependency sources. In particular:

- uucode's archive omits accompanying notices; retrieve `licenses/` from its
  exact revision.
- The compiled simdutf header and wrapper metadata report 9.2.1. Its upstream
  amalgamation is checksum-pinned by patch 0008; retain the embedded BSD/Fuchsia
  notices.
- Zig runtime notices include the math-source attributions referenced by
  `lib/compiler_rt/*.zig`.

## Build-Only Tools

CMake is required to rebuild libssh2/OpenSSL with `scripts/build-libssh2.sh`.
Zig 0.16.0 is downloaded and verified by `scripts/build-ghostty-vt-native.py`;
`scripts/build-ghostty-vt.sh` packages its VT-only output. CMake and the Zig
compiler executable are not distributed in the app. Zig runtime code is shipped
and is listed above.

## Maintenance

When adding or updating a shipped dependency:

1. Update `SSHApp/Resources/Legal/ThirdPartyNotices.json` and the matching fallback
   in `SSHApp/Models/ThirdPartyNotice.swift`.
2. Add or update the matching license text in `SSHApp/Resources/Legal/`.
3. Update this table and `docs/DEPENDENCIES.md`.
4. Verify Settings > Licenses shows the dependency and full notice.
