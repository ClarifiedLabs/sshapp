import Foundation

struct AppBuildMetadata: Equatable {
    static let sourceRepositoryURLKey = "SSHAppSourceRepositoryURL"
    static let sourceCommitKey = "SSHAppSourceCommit"
    static let sourceVersionKey = "SSHAppSourceVersion"
    static let defaultRepositoryURL = URL(string: "https://github.com/ClarifiedLabs/sshapp")!
    static let appStoreReviewURL = URL(string: "https://apps.apple.com/app/id6785688380?action=write-review")!
    static let licenseName = "MIT License"
    static let licenseFileName = "sshapp-mit.txt"

    let repositoryURL: URL
    let sourceCommit: String
    let sourceVersion: String

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        let repository = infoDictionary?[Self.sourceRepositoryURLKey] as? String
        repositoryURL = URL(string: repository ?? "") ?? Self.defaultRepositoryURL

        let commit = infoDictionary?[Self.sourceCommitKey] as? String
        sourceCommit = commit?.isEmpty == false ? commit! : "unknown"

        let version = infoDictionary?[Self.sourceVersionKey] as? String
        sourceVersion = version?.isEmpty == false ? version! : "dev"
    }

    var repositoryDisplayName: String {
        guard let host = repositoryURL.host else {
            return repositoryURL.absoluteString
        }

        let path = repositoryURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    var shortSourceCommit: String {
        guard sourceCommit != "unknown" else { return sourceCommit }
        return String(sourceCommit.prefix(12))
    }

    var sourceCommitURL: URL? {
        guard sourceCommit != "unknown" else { return nil }
        return repositoryURL
            .appendingPathComponent("commit")
            .appendingPathComponent(sourceCommit)
    }

    static func licenseText(bundle: Bundle = .main) -> String {
        let file = licenseFileName as NSString
        let resourceName = file.deletingPathExtension
        let fileExtension = file.pathExtension.isEmpty ? "txt" : file.pathExtension

        guard let url = legalResourceURL(
            named: resourceName,
            fileExtension: fileExtension,
            bundle: bundle
        ),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "License text unavailable. See LICENSE in the source repository."
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
}
