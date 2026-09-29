import Foundation

struct ThirdPartyNotice: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let purpose: String
    let source: String
    let version: String
    let licenseName: String
    let copyright: String
    let licenseFile: String
    let shippedInApp: Bool
    let notes: String?

    var sourceURL: URL? {
        URL(string: source)
    }
}

enum ThirdPartyNoticeCatalog {
    static func notices(bundle: Bundle = .main) -> [ThirdPartyNotice] {
        guard let url = legalResourceURL(
            named: "ThirdPartyNotices",
            fileExtension: "json",
            bundle: bundle
        ),
              let data = try? Data(contentsOf: url),
              let notices = try? JSONDecoder().decode([ThirdPartyNotice].self, from: data)
        else {
            return fallbackNotices
        }

        return notices
    }

    static func licenseText(for notice: ThirdPartyNotice, bundle: Bundle = .main) -> String {
        let file = notice.licenseFile as NSString
        let resourceName = file.deletingPathExtension
        let fileExtension = file.pathExtension.isEmpty ? "txt" : file.pathExtension

        guard let url = legalResourceURL(
            named: resourceName,
            fileExtension: fileExtension,
            bundle: bundle
        ),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "License text unavailable. See THIRD_PARTY_NOTICES.md in the source repository."
        }

        return text
    }

    private static func legalResourceURL(named name: String, fileExtension: String, bundle: Bundle) -> URL? {
        for subdirectory in ["Legal", "Resources/Legal", "SSHApp/Resources/Legal"] {
            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }
        }

        return bundle.url(forResource: name, withExtension: fileExtension)
    }

    // Keep every field synchronized with Resources/Legal/ThirdPartyNotices.json.
    static let fallbackNotices: [ThirdPartyNotice] = [
        ThirdPartyNotice(
            id: "sshapp-ghostty-wrapper",
            name: "SSHAppGhostty wrapper",
            purpose: "Local iOS Swift package wrapper for GhosttyTerminal and GhosttyTheme, derived from libghostty-spm.",
            source: "Packages/SSHAppGhostty; derived from https://github.com/Lakr233/libghostty-spm",
            version: "Derived from libghostty-spm 1.2.8, revision 839f269bcd5193d03293cb6717ed2582dde265ef",
            licenseName: "MIT License",
            copyright: "Copyright (c) 2026 @Lakr233",
            licenseFile: "libghostty-spm-mit.txt",
            shippedInApp: true,
            notes: "Vendored local Swift source; retained wrapper attribution. The native VT engine is packaged by scripts/build-ghostty-vt.sh."
        ),
        ThirdPartyNotice(
            id: "ghostty",
            name: "Ghostty / libghostty-vt",
            purpose: "VT parsing, terminal state, input encoding, and Kitty graphics decoding; rendering and UIKit hosting are app-owned.",
            source: "https://github.com/ghostty-org/ghostty",
            version: "Revision 5de703a1b6ca0b91fcebe932b44be1df2de0a683, pinned by vendor/libghostty-vt/native-lock.json",
            licenseName: "MIT License",
            copyright: "Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors",
            licenseFile: "ghostty-mit.txt",
            shippedInApp: true,
            notes: "Statically linked through Frameworks/GhosttyVT.xcframework; Zig 0.16.0, iOS 18.0, ReleaseSafe, with seven vendor/libghostty-vt/patches. No full Ghostty renderer."
        ),
        ThirdPartyNotice(
            id: "uucode",
            name: "uucode",
            purpose: "Unicode properties and grapheme segmentation used by libghostty-vt.",
            source: "https://github.com/jacobsandlund/uucode",
            version: "0.2.0, revision 2826a37a4562284fdacd8fa029d49509cc9bffcd",
            licenseName: "MIT License",
            copyright: "Copyright (c) 2026 Jacob Sandlund; Copyright (c) 2008-2009 Bjoern Hoehrmann",
            licenseFile: "uucode-mit.txt",
            shippedInApp: true,
            notes: "Pinned by Ghostty build.zig.zon. Includes the upstream accompanying UTF-8 decoder notice; Unicode data is listed separately."
        ),
        ThirdPartyNotice(
            id: "unicode",
            name: "Unicode Character Database",
            purpose: "Unicode property tables compiled into libghostty-vt through uucode.",
            source: "https://www.unicode.org/ucd/",
            version: "Unicode 17.0.0, bundled by the pinned uucode source",
            licenseName: "Unicode License V3",
            copyright: "Copyright © 1991-2025 Unicode, Inc.",
            licenseFile: "unicode-v3.txt",
            shippedInApp: true,
            notes: "Notice from the pinned uucode licenses/LICENSE_unicode."
        ),
        ThirdPartyNotice(
            id: "wuffs",
            name: "Wuffs",
            purpose: "Kitty graphics image decoding, pixel conversion, and alpha blending in libghostty-vt.",
            source: "https://github.com/google/wuffs",
            version: "Revision 7411f488fe2e2c205c3d3b3d28638b7356522930",
            licenseName: "MIT / Apache License 2.0",
            copyright: "Copyright 2023 The Wuffs Authors",
            licenseFile: "wuffs-mit-apache-2.0.txt",
            shippedInApp: true,
            notes: "Pinned by Ghostty pkg/wuffs/build.zig.zon; release/c/wuffs-v0.4.c is compiled into the static VT archive."
        ),
        ThirdPartyNotice(
            id: "simdutf",
            name: "simdutf",
            purpose: "SIMD UTF-8 and Base64 operations in libghostty-vt.",
            source: "https://github.com/simdutf/simdutf",
            version: "9.0.0 amalgamation in Ghostty revision 5de703a1b6ca0b91fcebe932b44be1df2de0a683",
            licenseName: "MIT / Apache License 2.0; bundled BSD notices",
            copyright: "Copyright 2021 The simdutf authors; additional copyright holders in bundled notice",
            licenseFile: "simdutf-notices.txt",
            shippedInApp: true,
            notes: "Version comes from SIMDUTF_VERSION in the compiled header, not the stale package wrapper version. Includes inherited header attribution."
        ),
        ThirdPartyNotice(
            id: "highway",
            name: "Highway",
            purpose: "Portable SIMD dispatch and terminal scanning in libghostty-vt.",
            source: "https://github.com/google/highway",
            version: "Revision 66486a10623fa0d72fe91260f96c892e41aceb06",
            licenseName: "Apache License 2.0 / BSD-3-Clause",
            copyright: "Copyright (c) The Highway Project Authors",
            licenseFile: "highway-apache-2.0-bsd.txt",
            shippedInApp: true,
            notes: "Pinned by Ghostty pkg/highway/build.zig.zon and combined into the static VT archive."
        ),
        ThirdPartyNotice(
            id: "zig-runtime",
            name: "Zig standard library and runtimes",
            purpose: "Standard library, compiler runtime, and safety runtime code statically linked into libghostty-vt.",
            source: "https://ziglang.org/",
            version: "0.16.0, toolchain archive pinned by vendor/libghostty-vt/native-lock.json",
            licenseName: "MIT License; accompanying math notices",
            copyright: "Copyright (c) Zig contributors; additional copyright holders in bundled notice",
            licenseFile: "zig-runtime-notices.txt",
            shippedInApp: true,
            notes: "The compiler executable is build-only; emitted standard-library/compiler-rt/UBSan code ships. Includes musl and Go math attribution."
        ),
        ThirdPartyNotice(
            id: "iterm2-color-schemes",
            name: "iTerm2-Color-Schemes",
            purpose: "Terminal color scheme data exposed through the GhosttyTheme catalog.",
            source: "https://github.com/mbadolato/iTerm2-Color-Schemes",
            version: "Vendored through Packages/SSHAppGhostty, derived from libghostty-spm 1.2.8",
            licenseName: "MIT License",
            copyright: "Copyright (c) 2011-present Mark Badolato",
            licenseFile: "iterm2-color-schemes-mit.txt",
            shippedInApp: true,
            notes: "License text is bundled with the GhosttyTheme source."
        ),
        ThirdPartyNotice(
            id: "libssh2",
            name: "libssh2",
            purpose: "SSH protocol implementation used by the native SSH transport layer.",
            source: "https://github.com/libssh2/libssh2",
            version: "1.11.2_DEV upstream snapshot, revision 2e1717456b8dd4c980e8e48d6dbfec524c2e62d1",
            licenseName: "BSD-3-Clause",
            copyright: "Copyright (C) The libssh2 project and its contributors",
            licenseFile: "libssh2-bsd-3-clause.txt",
            shippedInApp: true,
            notes: "Built into Frameworks/libssh2.xcframework with the local authentication banner callback patch."
        ),
        ThirdPartyNotice(
            id: "openssl",
            name: "OpenSSL",
            purpose: "TLS and cryptographic primitives used by libssh2 through libcrypto and libssl.",
            source: "https://github.com/openssl/openssl",
            version: "OpenSSL 3.5.8 LTS, revision f4dc4d58b48d346a8270183f89acf826d459b0ca",
            licenseName: "Apache License 2.0",
            copyright: "Copyright (c) The OpenSSL Project Authors",
            licenseFile: "openssl-apache-2.0.txt",
            shippedInApp: true,
            notes: "Built into Frameworks/libcrypto.xcframework and Frameworks/libssl.xcframework."
        ),
        ThirdPartyNotice(
            id: "jetbrains-mono",
            name: "JetBrains Mono",
            purpose: "Bundled monospaced terminal font.",
            source: "https://github.com/JetBrains/JetBrainsMono",
            version: "Bundled TTF files",
            licenseName: "SIL Open Font License 1.1",
            copyright: "Copyright 2020 The JetBrains Mono Project Authors",
            licenseFile: "jetbrains-mono-ofl-1.1.txt",
            shippedInApp: true,
            notes: "Bundled in SSHApp/Fonts."
        ),
    ]
}
