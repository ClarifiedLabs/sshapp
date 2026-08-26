import Foundation
import SwiftData
import XCTest
@testable import SSHApp

@MainActor
final class AppPersistenceStartupTests: XCTestCase {
    func testCurrentSchemaMigratesStoreThatPredatesUpdatedAt() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let storeURL = storeDirectory.appendingPathComponent("default.store")
        let id = UUID()
        let sshKeyId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let lastConnected = Date(timeIntervalSince1970: 1_710_000_000)
        let legacyMigrationTimestamp = Date(timeIntervalSince1970: 0)

        do {
            let schema = Schema([LegacySchema.SavedConnection.self])
            let configuration = ModelConfiguration(
                "default",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let connection = LegacySchema.SavedConnection(
                host: "legacy.example.com",
                port: 2222,
                username: "legacy-user",
                createdAt: createdAt
            )
            connection.id = id
            connection.sshKeyId = sshKeyId
            connection.lastConnected = lastConnected
            connection.neverAskSaveUsername = true
            connection.neverAskSavePassword = true
            connection.tmuxBackfillOverride = true
            connection.tmuxPauseModeOverride = false
            context.insert(connection)
            try context.save()
        }

        let currentSchema = Schema([SavedConnection.self])
        let currentConfiguration = ModelConfiguration(
            "default",
            schema: currentSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )

        do {
            let container = try ModelContainer(
                for: currentSchema,
                configurations: [currentConfiguration]
            )
            let context = ModelContext(container)
            let connections = try context.fetch(FetchDescriptor<SavedConnection>())
            let connection = try XCTUnwrap(connections.first)

            XCTAssertEqual(connections.count, 1)
            XCTAssertEqual(connection.id, id)
            XCTAssertEqual(connection.host, "legacy.example.com")
            XCTAssertEqual(connection.port, 2222)
            XCTAssertEqual(connection.username, "legacy-user")
            XCTAssertEqual(connection.sshKeyId, sshKeyId)
            XCTAssertEqual(connection.lastConnected, lastConnected)
            XCTAssertEqual(connection.createdAt, createdAt)
            XCTAssertEqual(connection.updatedAt, legacyMigrationTimestamp)
            XCTAssertTrue(connection.neverAskSaveUsername)
            XCTAssertTrue(connection.neverAskSavePassword)
            XCTAssertEqual(connection.tmuxBackfillOverride, true)
            XCTAssertEqual(connection.tmuxPauseModeOverride, false)
        }

        do {
            let container = try ModelContainer(
                for: currentSchema,
                configurations: [currentConfiguration]
            )
            let context = ModelContext(container)
            let connections = try context.fetch(FetchDescriptor<SavedConnection>())

            XCTAssertEqual(connections.count, 1)
            XCTAssertEqual(connections.first?.id, id)
            XCTAssertEqual(connections.first?.updatedAt, legacyMigrationTimestamp)
        }
    }

    func testContainerCreationFailureReturnsFailureStateInsteadOfTrapping() {
        let state = AppModelContainerState.load {
            throw TestError.expectedFailure
        }

        guard case .failed(let failure) = state else {
            return XCTFail("Expected container creation to return a failure state")
        }
        XCTAssertTrue(failure.details.contains("expectedFailure"))
    }
}

private enum TestError: Error {
    case expectedFailure
}

private enum LegacySchema {
    @Model
    final class SavedConnection {
        var id: UUID
        var host: String
        var port: Int
        var username: String?
        var sshKeyId: UUID?
        var lastConnected: Date?
        var createdAt: Date
        var neverAskSaveUsername: Bool = false
        var neverAskSavePassword: Bool = false
        var tmuxBackfillOverride: Bool?
        var tmuxPauseModeOverride: Bool?

        init(host: String, port: Int, username: String?, createdAt: Date) {
            self.id = UUID()
            self.host = host
            self.port = port
            self.username = username
            self.sshKeyId = nil
            self.lastConnected = nil
            self.createdAt = createdAt
            self.tmuxBackfillOverride = nil
            self.tmuxPauseModeOverride = nil
        }
    }
}
