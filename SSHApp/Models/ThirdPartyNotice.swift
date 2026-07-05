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

    private static let fallbackNotices: [ThirdPartyNotice] = [
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
            notes: "Vendored as local source in this repository; the native Ghostty binary is built by scripts/build-ghostty-ios.sh."
        ),
        ThirdPartyNotice(
            id: "ghostty",
            name: "Ghostty / libghostty",
            purpose: "Terminal core used for VT parsing, terminal state, CoreText font handling, and Metal rendering.",
            source: "https://github.com/ghostty-org/ghostty",
            version: "Submodule revision 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28 (Ghostty v1.3.1)",
            licenseName: "MIT License",
            copyright: "Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors",
            licenseFile: "ghostty-mit.txt",
            shippedInApp: true,
            notes: "Built locally into Frameworks/GhosttyKit.xcframework with scripts/ghostty-patches applied."
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
            id: "msdisplaylink",
            name: "MSDisplayLink",
            purpose: "Display-link timing used by the local GhosttyTerminal wrapper.",
            source: "https://github.com/Lakr233/MSDisplayLink",
            version: "2.1.0, revision 1ba3e769b734e456317fa7e45321fa7f53eefb67",
            licenseName: "MIT License",
            copyright: "Copyright (c) 2024 Lakr Aream",
            licenseFile: "msdisplaylink-mit.txt",
            shippedInApp: true,
            notes: "Direct Swift Package dependency of Packages/SSHAppGhostty."
        ),
        ThirdPartyNotice(
            id: "libssh2",
            name: "libssh2",
            purpose: "SSH protocol implementation used by the native SSH transport layer.",
            source: "https://github.com/libssh2/libssh2",
            version: "Submodule revision 704299e997bf518375dc9222670c57b800ac59e6",
            licenseName: "BSD-3-Clause",
            copyright: "Copyright (C) The libssh2 project and its contributors",
            licenseFile: "libssh2-bsd-3-clause.txt",
            shippedInApp: true,
            notes: "Built into Frameworks/libssh2.xcframework."
        ),
        ThirdPartyNotice(
            id: "openssl",
            name: "OpenSSL",
            purpose: "TLS and cryptographic primitives used by libssh2 through libcrypto and libssl.",
            source: "https://github.com/openssl/openssl",
            version: "Submodule revision ce101e19abed882f8a66ec73f4f0c501435e4f1c",
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
