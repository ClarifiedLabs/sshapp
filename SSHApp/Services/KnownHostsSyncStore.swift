import Foundation

final class KnownHostsSyncStore: @unchecked Sendable {
    static let shared = KnownHostsSyncStore()

    private struct Snapshot: Codable {
        let content: String
        let updatedAt: Date
    }

    private static let defaultCloudKey = "dev.sshapp.sshapp.knownHosts"

    private let ubiquitous: NSUbiquitousKeyValueStore
    private let cloudKey: String
    private let fileManager: FileManager
    private var fileURL: URL?
    private var observerToken: NSObjectProtocol?

    init(
        ubiquitous: NSUbiquitousKeyValueStore = .default,
        cloudKey: String = KnownHostsSyncStore.defaultCloudKey,
        fileManager: FileManager = .default
    ) {
        self.ubiquitous = ubiquitous
        self.cloudKey = cloudKey
        self.fileManager = fileManager
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    func start(fileURL: URL = KnownHostsSyncStore.defaultKnownHostsURL()) {
        self.fileURL = fileURL
        syncFileWithCloud(fileURL: fileURL)

        guard observerToken == nil else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitous,
            queue: .main
        ) { [weak self] _ in
            guard let self, let fileURL = self.fileURL else { return }
            self.syncFileWithCloud(fileURL: fileURL)
        }
    }

    func syncFileWithCloud(fileURL: URL) {
        ubiquitous.synchronize()

        let localContent = readFile(fileURL)
        let cloudContent = readSnapshot()?.content

        switch (localContent, cloudContent) {
        case (.none, .none):
            return
        case (.some(let local), .none):
            guard !local.isEmpty else { return }
            writeSnapshot(content: local)
        case (.none, .some(let cloud)):
            writeFile(cloud, to: fileURL)
        case (.some(let local), .some(let cloud)):
            let merged = Self.mergedKnownHosts(local: local, cloud: cloud)
            if merged != local {
                writeFile(merged, to: fileURL)
            }
            if merged != cloud {
                writeSnapshot(content: merged)
            }
        }
    }

    func publishFile(fileURL: URL) {
        guard let content = readFile(fileURL), !content.isEmpty else { return }
        writeSnapshot(content: content)
    }

    static func clearSyncedValues(ubiquitous: NSUbiquitousKeyValueStore = .default) {
        ubiquitous.removeObject(forKey: defaultCloudKey)
    }

    static func defaultKnownHostsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("known_hosts")
    }

    static func mergedKnownHosts(local: String, cloud: String) -> String {
        var seen: Set<String> = []
        var merged: [String] = []

        for line in local.knownHostLines + cloud.knownHostLines {
            let key = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            merged.append(line)
        }

        guard !merged.isEmpty else { return "" }
        return merged.joined(separator: "\n") + "\n"
    }

    private func readFile(_ fileURL: URL) -> String? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private func writeFile(_ content: String, to fileURL: URL) {
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func readSnapshot() -> Snapshot? {
        guard let data = ubiquitous.data(forKey: cloudKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func writeSnapshot(content: String) {
        let snapshot = Snapshot(content: content, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        ubiquitous.set(data, forKey: cloudKey)
        ubiquitous.synchronize()
    }
}

private extension String {
    var knownHostLines: [String] {
        split(whereSeparator: \.isNewline).map(String.init)
    }
}
